#if canImport(Containerization)
  import AgentIsolation
  import Containerization
  import ContainerizationArchive
  import ContainerizationOCI
  import ContainerizationOS
  import Foundation
  import Logging
  import System

  // MARK: - AppleContainerRuntime

  /// Container runtime that runs containers directly using Apple's Virtualization.framework
  /// via the `containerization` package — no XPC daemon required.
  public final class AppleContainerRuntime: ContainerRuntime, ManagedImageRuntime,
    @unchecked Sendable
  {
    public typealias Image = AppleContainerImage
    public typealias Container = AppleContainerContainer

    /// Capacity requested for every session rootfs. Part of the cache key, so
    /// changing it invalidates existing entries rather than reusing a smaller disk.
    static let rootfsCapacityBytes: UInt64 = UInt64(8).gib()

    /// Describes the ext4 the unpacker is asked to produce. Part of the cache key.
    static let ext4FormattingOptions = "journal=none"

    private let storagePath: URL
    private let diagnostics: StartupDiagnostics?
    private let rootfsCacheEnabled: Bool
    private var manager: ContainerManager?
    private var imageStore: ImageStore?

    private static var containerAppDataRoot: URL {
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("com.apple.container")
    }

    public required init(config: ContainerRuntimeConfiguration) {
      self.storagePath = URL(fileURLWithPath: config.storagePath)
      self.diagnostics = config.diagnostics
      self.rootfsCacheEnabled = config.rootfsCacheEnabled
    }

    /// Where the image store — and with it the rootfs cache and session
    /// directories — lives.
    private var imageStorePath: URL {
      storagePath.appendingPathComponent("imagestore")
    }

    private var rootFSCache: RootFSCache {
      RootFSCache(imageStorePath: imageStorePath, diagnostics: diagnostics)
    }

    /// How host file ownership presents through Apple's virtiofs share.
    ///
    /// `isCharacterized` stays `false` until that has been measured on real
    /// hardware — specifically, whether a guest `chown` on a shared file takes
    /// effect, and whether it is still in effect for the next session. Until then
    /// the bootstrap keeps repairing profile ownership on every start rather than
    /// trusting a record written against an unverified mapping.
    public var profileOwnershipMapping: ProfileOwnershipMapping? {
      ProfileOwnershipMapping(
        identity: "apple-container/virtiofs", isCharacterized: false)
    }

    /// Containers this runtime still has state for.
    ///
    /// `ContainerManager` keeps one directory per container and removes it on
    /// `delete`, so a directory that is still there means the session was never
    /// torn down — which is exactly the crashed-agentc case an ownership repair
    /// must not run underneath.
    public func liveContainerIDs() async -> Set<String>? {
      let root = imageStorePath.appendingPathComponent("containers")
      guard
        let entries = try? FileManager.default.contentsOfDirectory(
          at: root, includingPropertiesForKeys: [.isDirectoryKey])
      else {
        // A missing directory means no containers, not "cannot tell".
        return FileManager.default.fileExists(atPath: root.path) ? nil : []
      }
      return Set(
        entries.filter {
          (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.map(\.lastPathComponent))
    }

    // MARK: - ContainerRuntime

    public func prepare() async throws {
      try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)

      let kernel = try await getOrDownloadKernel()

      let store = try managedImageStore()

      let network: Network?
      if #available(macOS 26.0, *) {
        network = try VmnetNetwork()
      } else {
        network = nil
      }

      self.manager = try await ContainerManager(
        kernel: kernel,
        initfsReference: "ghcr.io/apple/containerization/vminit:0.41.0",
        imageStore: store,
        network: network
      )
    }

    public func pullImage(ref: String) async throws -> AppleContainerImage? {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      let resolvedRef = Self.normalizedDockerHubRef(ref)
      do {
        let image = try await store.pull(reference: resolvedRef, platform: .current)
        return AppleContainerImage(ref: ref, digest: image.digest)
      } catch {
        // Pull failure — image may not exist or network error
        return nil
      }
    }

    public func inspectImage(ref: String) async throws -> AppleContainerImage? {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      // Try the ref as given first (image may have been pulled with the full name)
      if let image = try? await store.get(reference: ref) {
        return AppleContainerImage(ref: ref, digest: image.digest)
      }
      // Fall back to the normalized Docker Hub reference for bare names
      let resolvedRef = Self.normalizedDockerHubRef(ref)
      if resolvedRef != ref, let image = try? await store.get(reference: resolvedRef) {
        return AppleContainerImage(ref: ref, digest: image.digest)
      }
      return nil
    }

    public func removeImage(ref: String) async throws {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      let resolvedRef = Self.normalizedDockerHubRef(ref)
      // Resolve the digest before deleting, so cached rootfs entries unpacked from
      // this image can be dropped too. Sessions that already cloned one keep
      // running: their disks are independent files.
      let digest = try? await store.get(reference: resolvedRef).digest
      try await store.delete(reference: resolvedRef, performCleanup: true)
      if let digest { rootFSCache.invalidate(imageDigest: digest) }
    }

    public func removeImage(digest: String) async throws {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      try await store.delete(reference: digest, performCleanup: true)
      rootFSCache.invalidate(imageDigest: digest)
    }

    // MARK: - ManagedImageRuntime

    public func listImages() async throws -> [ManagedImage] {
      let store = try managedImageStore()
      var result: [ManagedImage] = []
      for image in try await store.list() {
        result.append(try await managedImage(from: image))
      }
      return result.sorted { $0.reference < $1.reference }
    }

    public func inspectManagedImage(ref: String) async throws -> ManagedImage? {
      let store = try managedImageStore()
      let candidates = [ref, Self.normalizedDockerHubRef(ref)]
      var visited: Set<String> = []
      for candidate in candidates where visited.insert(candidate).inserted {
        if let image = try? await store.get(reference: candidate) {
          return try await managedImage(from: image)
        }
      }
      return nil
    }

    public func removeManagedImage(ref: String) async throws {
      let store = try managedImageStore()
      let candidate: String
      if (try? await store.get(reference: ref)) != nil {
        candidate = ref
      } else {
        candidate = Self.normalizedDockerHubRef(ref)
      }
      let digest = try? await store.get(reference: candidate).digest
      try await store.delete(reference: candidate, performCleanup: true)
      if let digest { rootFSCache.invalidate(imageDigest: digest) }
    }

    private func managedImageStore() throws -> ImageStore {
      if let imageStore { return imageStore }
      try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)
      let store = try ImageStore(path: imageStorePath)
      imageStore = store
      return store
    }

    private func managedImage(from image: Containerization.Image) async throws -> ManagedImage {
      let index = try await image.index()
      var sizesByDigest: [String: Int64] = [image.descriptor.digest: image.descriptor.size]
      for descriptor in index.manifests {
        sizesByDigest[descriptor.digest] = descriptor.size
        if let manifest = try? await image.manifest(for: descriptor.platform ?? .current) {
          for child in manifest.layers + [manifest.config] {
            sizesByDigest[child.digest] = child.size
          }
        }
      }
      let (name, tag) = Self.splitImageReference(image.reference)
      let usage = sizesByDigest.values.reduce(UInt64(0)) { total, size in
        total + UInt64(max(0, size))
      }
      let platforms = index.manifests.compactMap(\.platform).map(\.description)
      return ManagedImage(
        name: name,
        tag: tag,
        storageUsage: usage,
        digest: image.digest,
        mediaType: image.mediaType,
        platforms: platforms.isEmpty ? nil : platforms
      )
    }

    static func splitImageReference(_ reference: String) -> (name: String, tag: String) {
      if let digest = reference.lastIndex(of: "@") {
        return (String(reference[..<digest]), String(reference[reference.index(after: digest)...]))
      }
      let lastSlash = reference.lastIndex(of: "/")
      if let colon = reference.lastIndex(of: ":"), lastSlash == nil || colon > lastSlash! {
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
      }
      return (reference, "latest")
    }

    public func runContainer(
      imageRef: String,
      configuration: ContainerConfiguration
    ) async throws -> AppleContainerContainer {
      guard var manager else {
        throw AppleContainerRuntimeError.notPrepared
      }

      // Set up terminal before creating the container
      var terminal: Terminal? = nil
      switch configuration.io {
      case .currentTerminal:
        terminal = try? Terminal.current
        try terminal?.setraw()
      default:
        break
      }

      let containerID = UUID().uuidString.lowercased()

      let resolvedRef = Self.normalizedDockerHubRef(imageRef)

      // Resolve the image exactly once and use that object for both the rootfs and
      // the container configuration, so a tag update racing this launch can never
      // pair one image's filesystem with another image's config.
      let store = manager.imageStore
      let resolvedImage = try await diagnostics.span("image.resolve") { context in
        let image = try await store.get(reference: resolvedRef, pull: true)
        context?.set("digest", image.digest)
        return image
      }

      let sessionDirectory =
        imageStorePath
        .appendingPathComponent("containers")
        .appendingPathComponent(containerID)
      let sessionRootfs = sessionDirectory.appendingPathComponent("rootfs.ext4")

      // The existing-rootfs `create` overload does not create this directory, but
      // it still writes the boot log into it and `delete` still removes it.
      try FileManager.default.createDirectory(
        at: sessionDirectory, withIntermediateDirectories: true)

      let rootfsMount: Mount
      do {
        rootfsMount = try await materializeRootFS(
          image: resolvedImage, reference: resolvedRef, at: sessionRootfs)
      } catch {
        terminal?.tryReset()
        try? FileManager.default.removeItem(at: sessionDirectory)
        throw error
      }

      let container: LinuxContainer
      do {
        container = try await manager.create(
          containerID,
          image: resolvedImage,
          rootfs: rootfsMount
        ) { containerConfig in
          containerConfig.cpus = configuration.cpuCount
          containerConfig.memoryInBytes = UInt64(configuration.memoryLimitMiB).mib()

          containerConfig.hosts = .default
          containerConfig.useInit = true

          // Entrypoint
          if !configuration.entrypoint.isEmpty {
            containerConfig.process.arguments = configuration.entrypoint
          }

          // Working directory
          if let workDir = configuration.workingDirectory {
            containerConfig.process.workingDirectory = workDir
          }

          // Environment: image defaults, with our values overriding matching names.
          containerConfig.process.environmentVariables = AppleContainerEnvironment.merged(
            imageDefaults: containerConfig.process.environmentVariables,
            overrides: configuration.environment
          )

          // Mounts
          for mount in configuration.mounts {
            containerConfig.mounts.append(
              .share(
                source: mount.hostPath,
                destination: mount.containerPath
              ))
          }

          // I/O
          switch configuration.io {
          case .currentTerminal:
            if let t = terminal {
              containerConfig.process.setTerminalIO(terminal: t)
            }
          case .standardIO:
            containerConfig.process.stdin = FileDescriptorReader(.standardInput)
            containerConfig.process.stdout = FileDescriptorWriter(.standardOutput)
            containerConfig.process.stderr = FileDescriptorWriter(.standardError)
          case .custom(let stdin, let stdout, let stderr, let isTerminal):
            containerConfig.process.terminal = isTerminal
            containerConfig.process.stdin = ContainerizationReaderStream(stdin)
            containerConfig.process.stdout = ContainerizationWriter(stdout)
            containerConfig.process.stderr = ContainerizationWriter(stderr)
          }
        }
      } catch {
        // Nothing was created, so there is no VM to stop — just take the session's
        // files back out and restore the terminal.
        terminal?.tryReset()
        try? manager.releaseNetwork(containerID)
        try? FileManager.default.removeItem(at: sessionDirectory)
        throw error
      }

      do {
        try await diagnostics.span("container.create") { _ in try await container.create() }
        try await diagnostics.span("container.start") { _ in try await container.start() }
      } catch {
        // A VM may already exist by now. Stop it before deleting its disk: pulling
        // the rootfs out from under a live VM is far worse than a leaked file.
        try? await container.stop()
        terminal?.tryReset()
        try? manager.delete(containerID)
        throw error
      }

      if let t = terminal {
        try? await container.resize(to: try t.size)
      }

      return AppleContainerContainer(
        id: containerID,
        container: container,
        manager: manager,
        terminal: terminal
      )
    }

    // MARK: - Root filesystem

    /// Produce this session's writable rootfs.
    ///
    /// With the cache enabled the image is unpacked at most once per identity and
    /// each session gets an independent clone or copy of it. With the cache
    /// disabled the image is unpacked straight into the session. Either way the
    /// session's disk is its own file and is destroyed on exit — no rootfs is ever
    /// carried over to the next launch.
    private func materializeRootFS(
      image: Containerization.Image,
      reference: String,
      at sessionRootfs: URL
    ) async throws -> Mount {
      let capacity = Self.rootfsCapacityBytes

      let unpack: (URL) async throws -> Void = { destination in
        let unpacker = EXT4Unpacker(blockSizeInBytes: capacity)
        _ = try await unpacker.unpack(image, for: .current, at: destination, progress: nil)
      }

      guard rootfsCacheEnabled else {
        try await diagnostics.span("rootfs.materialize") { context in
          context?.set("cache", "disabled")
          context?.set("source", RootFSMaterialization.Source.uncached.rawValue)
          try await unpack(sessionRootfs)
          try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: sessionRootfs.path)
        }
        return Self.blockMount(at: sessionRootfs)
      }

      let platform = Platform.current
      let descriptor = try await image.descriptor(for: platform)
      let identity = RootFSCacheIdentity(
        platformManifestDigest: descriptor.digest,
        os: platform.os,
        architecture: platform.architecture,
        variant: platform.variant,
        rootfsCapacityBytes: capacity,
        ext4FormattingOptions: Self.ext4FormattingOptions
      )

      let cache = rootFSCache
      let result = try await diagnostics.span("rootfs.materialize") { context in
        let result = try await cache.materialize(
          identity: identity,
          imageReference: reference,
          imageDigest: image.digest,
          sessionRootfs: sessionRootfs,
          unpack: unpack)
        context?.set("source", result.source.rawValue)
        if let method = result.method { context?.set("method", method.rawValue) }
        if let reason = result.bypassReason { context?.set("bypass", String(reason.prefix(200))) }
        return result
      }

      // Eviction runs after the session already has its disk, so it can never
      // delay a launch, and it only ever touches entries nothing holds a lock on.
      if result.source == .cacheMiss {
        cache.prune()
      }

      return Self.blockMount(at: sessionRootfs)
    }

    private static func blockMount(at path: URL) -> Mount {
      .block(format: "ext4", source: path.path, destination: "/", options: [])
    }

    public func shutdown() async throws {
      manager = nil
      imageStore = nil
    }

    public func removeContainer(_ container: AppleContainerContainer) async throws {
      container.terminal?.tryReset()
      try await container.underlyingContainer.stop()
      try container.manager.delete(container.id)
    }

    // MARK: - Image Reference Normalization

    /// Normalizes a bare image reference to a fully qualified Docker Hub reference.
    /// e.g., "swift:6.3" → "docker.io/library/swift:6.3",
    ///       "user/repo:tag" → "docker.io/user/repo:tag".
    /// Already-qualified references (containing a registry domain) are returned as-is.
    static func normalizedDockerHubRef(_ ref: String) -> String {
      // Strip tag (@sha256:...) or tag (:tag) to isolate the name portion
      let name: String
      if let atIndex = ref.firstIndex(of: "@") {
        name = String(ref[..<atIndex])
      } else {
        name = ref
      }

      guard let slashIndex = name.firstIndex(of: "/") else {
        // No slash → bare name like "swift:6.3"
        return "docker.io/library/\(ref)"
      }

      let firstComponent = name[..<slashIndex]
      // A registry domain contains a dot, a colon (port), or is "localhost"
      if firstComponent.contains(".") || firstComponent.contains(":")
        || firstComponent == "localhost"
      {
        return ref
      }

      // Has a slash but no registry (e.g., "user/repo:tag")
      return "docker.io/\(ref)"
    }

    // MARK: - Kernel

    private func getOrDownloadKernel() async throws -> Kernel {
      // 1. Reuse Apple Container's installed kernel when it is at least as new as
      // Apple's current default. Older kernels are skipped and upgraded in our cache.
      let appKernelLink =
        Self.containerAppDataRoot
        .appendingPathComponent("kernels")
        .appendingPathComponent("default.kernel-arm64")
      let appKernelResolved = appKernelLink.resolvingSymlinksInPath()
      let appKernelExists = FileManager.default.fileExists(atPath: appKernelResolved.path)
      if appKernelExists,
        AppleContainerDefaultKernel.isCurrentOrNewer(
          filename: appKernelResolved.lastPathComponent)
      {
        return Kernel(path: appKernelResolved, platform: .linuxArm)
      }

      // 2. Try our own current cached kernel. Using Apple's versioned filename makes
      // an agentc update automatically bypass any older cached kernel.
      let ourKernelDir = storagePath.appendingPathComponent("kernels")
      let ourKernelLink = ourKernelDir.appendingPathComponent("default.kernel-arm64")
      let kernelBinary = ourKernelDir.appendingPathComponent(AppleContainerDefaultKernel.filename)
      if FileManager.default.fileExists(atPath: kernelBinary.path) {
        try? FileManager.default.removeItem(at: ourKernelLink)
        try FileManager.default.createSymbolicLink(
          at: ourKernelLink, withDestinationURL: kernelBinary)
        return Kernel(path: kernelBinary, platform: .linuxArm)
      }

      // 3. Download and verify Apple's current default kernel.
      let existingCachedKernel = ourKernelLink.resolvingSymlinksInPath()
      let isUpgrade =
        appKernelExists
        || FileManager.default.fileExists(atPath: existingCachedKernel.path)
      let action = isUpgrade ? "upgrading to" : "installing"
      fputs(
        "agentc: \(action) Apple Containers default kernel "
          + "(Kata \(AppleContainerDefaultKernel.kataVersion))...\n",
        stderr)
      let tarURL = URL(string: AppleContainerDefaultKernel.archiveURL)!

      let (tempFile, response) = try await URLSession.shared.download(from: tarURL)
      defer { try? FileManager.default.removeItem(at: tempFile) }
      guard let response = response as? HTTPURLResponse,
        (200..<300).contains(response.statusCode)
      else {
        throw AppleContainerRuntimeError.kernelDownloadFailed(
          statusCode: (response as? HTTPURLResponse)?.statusCode)
      }

      let actualDigest = try AppleContainerDefaultKernel.sha256Digest(of: tempFile)
      guard actualDigest == AppleContainerDefaultKernel.archiveDigest else {
        throw AppleContainerRuntimeError.unexpectedKernelArchiveDigest(
          expected: AppleContainerDefaultKernel.archiveDigest,
          actual: actualDigest)
      }

      let archiveReader = try ArchiveReader(file: tempFile)
      let (_, kernelData) =
        try archiveReader.extractFile(path: AppleContainerDefaultKernel.binaryPath)

      try FileManager.default.createDirectory(at: ourKernelDir, withIntermediateDirectories: true)
      try kernelData.write(to: kernelBinary, options: .atomic)

      try? FileManager.default.removeItem(at: ourKernelLink)
      try FileManager.default.createSymbolicLink(
        at: ourKernelLink, withDestinationURL: kernelBinary)

      return Kernel(path: kernelBinary, platform: .linuxArm)
    }
  }

  // MARK: - Associated Types

  public struct AppleContainerImage: ContainerRuntimeImage {
    public var ref: String
    public var digest: String

    public init(ref: String, digest: String) {
      self.ref = ref
      self.digest = digest
    }
  }

  public final class AppleContainerContainer: ContainerRuntimeContainer, @unchecked Sendable {
    public let id: String
    let underlyingContainer: LinuxContainer
    var manager: ContainerManager
    var terminal: Terminal?

    init(
      id: String,
      container: LinuxContainer,
      manager: ContainerManager,
      terminal: Terminal?
    ) {
      self.id = id
      self.underlyingContainer = container
      self.manager = manager
      self.terminal = terminal
    }

    public func wait(timeoutInSeconds: Int64?) async throws -> Int32 {
      let exitStatus: ExitStatus
      if let t = terminal {
        let sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])
        exitStatus = try await withThrowingTaskGroup(of: ExitStatus?.self) { group in
          group.addTask {
            for await _ in sigwinchStream.signals {
              try await self.underlyingContainer.resize(to: try t.size)
            }
            return nil
          }
          group.addTask { try await self.underlyingContainer.wait() }
          var result: ExitStatus? = nil
          for try await value in group {
            if let value {
              result = value
              group.cancelAll()
              break
            }
          }
          return result ?? ExitStatus(exitCode: 0)
        }
      } else {
        exitStatus = try await underlyingContainer.wait()
      }
      return exitStatus.exitCode
    }

    public func stop() async throws {
      terminal?.tryReset()
      try await underlyingContainer.stop()
    }

    public func resize(cols: Int, rows: Int) async throws {
      try await underlyingContainer.resize(
        to: ContainerizationOS.Terminal.Size(
          width: UInt16(cols), height: UInt16(rows)))
    }
  }

  // MARK: - Errors

  public enum AppleContainerRuntimeError: LocalizedError {
    case notPrepared
    case kernelDownloadFailed(statusCode: Int?)
    case unexpectedKernelArchiveDigest(expected: String, actual: String)

    public var errorDescription: String? {
      switch self {
      case .notPrepared:
        return "Container runtime has not been prepared. Call prepare() first."
      case .kernelDownloadFailed(let statusCode):
        if let statusCode {
          return "Failed to download the Apple Containers kernel (HTTP \(statusCode))."
        }
        return "Failed to download the Apple Containers kernel: invalid HTTP response."
      case .unexpectedKernelArchiveDigest(let expected, let actual):
        return
          "Apple Containers kernel archive digest mismatch: expected \(expected), got \(actual)."
      }
    }
  }
#endif
