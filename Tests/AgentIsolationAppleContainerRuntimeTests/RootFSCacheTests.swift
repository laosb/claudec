// The cache, its lock, and the clone/copy helper carry no Containerization
// dependency, so these run on Linux as well as macOS — but only when the Apple
// runtime target is actually linked in.
#if ContainerRuntimeAppleContainer
  import AgentIsolation
  import Foundation
  import Synchronization
  import Testing

  @testable import AgentIsolationAppleContainerRuntime

  // MARK: - Fixtures

  /// A throwaway directory that stands in for the image store.
  ///
  /// A class so it can be handed to `async` helpers; the directory is removed when
  /// the last reference goes away.
  private final class TempStore: Sendable {
    let url: URL

    init() throws {
      url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rootfs-cache-tests-\(UUID().uuidString.lowercased())")
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func makeIdentity(
    digest: String = "sha256:aaaa",
    os: String = "linux",
    architecture: String = "arm64",
    variant: String? = nil,
    capacity: UInt64 = 8 * 1024 * 1024 * 1024,
    formatting: String = "journal=none",
    compatibility: Int = RootFSCache.unpackerCompatibilityVersion
  ) -> RootFSCacheIdentity {
    RootFSCacheIdentity(
      unpackerCompatibilityVersion: compatibility,
      platformManifestDigest: digest,
      os: os,
      architecture: architecture,
      variant: variant,
      rootfsCapacityBytes: capacity,
      ext4FormattingOptions: formatting)
  }

  /// Write a file that passes the cache's bounded ext4 header probe.
  ///
  /// The superblock sits at byte 1024 and its magic is a little-endian `0xEF53` at
  /// offset 0x38 within it.
  private func writeFakeRootfs(at url: URL, payload: String = "template") throws {
    var bytes = [UInt8](repeating: 0, count: 4096)
    bytes[1024 + 0x38] = 0x53
    bytes[1024 + 0x39] = 0xEF
    for (index, byte) in Array(payload.utf8).enumerated() { bytes[index] = byte }
    try Data(bytes).write(to: url)
  }

  private func payload(of url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    let prefix = data.prefix(64).prefix { $0 != 0 }
    return String(decoding: prefix, as: UTF8.self)
  }

  /// Counts unpacks so a test can prove the image was only unpacked once.
  private final class UnpackCounter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func unpack(to destination: URL, payload: String = "template") throws {
      count.withLock { $0 += 1 }
      try writeFakeRootfs(at: destination, payload: payload)
    }
  }

  /// Forces the copy path, standing in for a filesystem that cannot clone.
  private struct CopyOnlyFileOperations: RootFSFileOperations {
    func materialize(from source: URL, to destination: URL) throws
      -> RootFSMaterializationMethod
    {
      try FileManager.default.copyItem(at: source, to: destination)
      return .copy
    }
  }

  /// Reports `clone` while still producing a genuinely independent file, so the
  /// clone branch can be exercised on a filesystem without reflink support.
  private struct PretendCloneFileOperations: RootFSFileOperations {
    func materialize(from source: URL, to destination: URL) throws
      -> RootFSMaterializationMethod
    {
      try FileManager.default.copyItem(at: source, to: destination)
      return .clone
    }
  }

  private struct FailingFileOperations: RootFSFileOperations {
    struct Failure: Error {}

    func materialize(from source: URL, to destination: URL) throws
      -> RootFSMaterializationMethod
    {
      throw Failure()
    }
  }

  // MARK: - Cache identity

  @Suite("Rootfs cache identity")
  struct RootFSCacheIdentityTests {

    @Test("The same identity always produces the same key")
    func keyIsStable() {
      #expect(makeIdentity().key == makeIdentity().key)
    }

    @Test("The key is a hex SHA-256")
    func keyShape() {
      let key = makeIdentity().key
      #expect(key.count == 64)
      #expect(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("A different platform manifest digest invalidates the key")
    func digestChangesKey() {
      #expect(makeIdentity(digest: "sha256:aaaa").key != makeIdentity(digest: "sha256:bbbb").key)
    }

    @Test("Platform changes invalidate the key")
    func platformChangesKey() {
      let base = makeIdentity()
      #expect(base.key != makeIdentity(os: "darwin").key)
      #expect(base.key != makeIdentity(architecture: "amd64").key)
      #expect(base.key != makeIdentity(variant: "v8").key)
    }

    @Test("Capacity and formatting changes invalidate the key")
    func capacityChangesKey() {
      let base = makeIdentity()
      #expect(base.key != makeIdentity(capacity: 16 * 1024 * 1024 * 1024).key)
      #expect(base.key != makeIdentity(formatting: "journal=default").key)
    }

    @Test("A compatibility-version bump invalidates the key")
    func compatibilityChangesKey() {
      #expect(makeIdentity().key != makeIdentity(compatibility: 99).key)
    }

    @Test("Field boundaries cannot be forged by shifting values between fields")
    func fieldsAreDelimited() {
      let a = makeIdentity(os: "linux", architecture: "arm64")
      let b = makeIdentity(os: "linu", architecture: "xarm64")
      #expect(a.key != b.key)
    }
  }

  // MARK: - Materialization

  @Suite("Rootfs cache materialization")
  struct RootFSCacheMaterializationTests {

    private func makeCache(
      _ store: TempStore,
      fileOperations: any RootFSFileOperations = PretendCloneFileOperations(),
      maxEntries: Int = RootFSCache.defaultMaxEntries
    ) -> RootFSCache {
      RootFSCache(
        imageStorePath: store.url, fileOperations: fileOperations, maxEntries: maxEntries)
    }

    private func sessionRootfs(_ store: TempStore, _ id: String) -> URL {
      store.url
        .appendingPathComponent("containers")
        .appendingPathComponent(id)
        .appendingPathComponent("rootfs.ext4")
    }

    @Test("Two sequential launches unpack once but get distinct session files")
    func reusesUnpackedImage() async throws {
      let store = try TempStore()
      let cache = makeCache(store)
      let counter = UnpackCounter()
      let identity = makeIdentity()

      let first = sessionRootfs(store, "session-1")
      let second = sessionRootfs(store, "session-2")

      let firstResult = try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: first, unpack: { try counter.unpack(to: $0) })
      let secondResult = try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: second, unpack: { try counter.unpack(to: $0) })

      #expect(firstResult.source == .cacheMiss)
      #expect(secondResult.source == .cacheHit)
      #expect(counter.value == 1)
      #expect(first.path != second.path)
      #expect(FileManager.default.fileExists(atPath: first.path))
      #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("Session disks are independent of each other and of the template")
    func sessionDisksAreIndependent() async throws {
      let store = try TempStore()
      let cache = makeCache(store, fileOperations: CopyOnlyFileOperations())
      let identity = makeIdentity()
      let counter = UnpackCounter()

      let first = sessionRootfs(store, "session-1")
      let second = sessionRootfs(store, "session-2")
      _ = try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: first, unpack: { try counter.unpack(to: $0) })
      let secondResult = try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: second, unpack: { try counter.unpack(to: $0) })
      #expect(secondResult.method == .copy)

      // Write through the first session's disk, as a workload installing packages would.
      try writeFakeRootfs(at: first, payload: "mutated")

      #expect(try payload(of: second) == "template")
      let template = cache.entryDirectory(for: identity.key).appendingPathComponent("rootfs.ext4")
      #expect(try payload(of: template) == "template")
    }

    @Test("A workload's rootfs changes are gone on the next launch")
    func rootfsChangesDoNotPersist() async throws {
      let store = try TempStore()
      let cache = makeCache(store)
      let identity = makeIdentity()
      let counter = UnpackCounter()

      let first = sessionRootfs(store, "session-1")
      _ = try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: first, unpack: { try counter.unpack(to: $0) })
      try writeFakeRootfs(at: first, payload: "installed-a-package")
      // The session is torn down, taking its disk with it.
      try FileManager.default.removeItem(at: first.deletingLastPathComponent())

      let second = sessionRootfs(store, "session-2")
      _ = try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: second, unpack: { try counter.unpack(to: $0) })
      #expect(try payload(of: second) == "template")
      #expect(counter.value == 1)
    }

    @Test("The session copy is owner read/write and the template stays host read-only")
    func permissions() async throws {
      let store = try TempStore()
      let cache = makeCache(store, fileOperations: CopyOnlyFileOperations())
      let identity = makeIdentity()
      let counter = UnpackCounter()

      let session = sessionRootfs(store, "session-1")
      _ = try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: session, unpack: { try counter.unpack(to: $0) })

      let template = cache.entryDirectory(for: identity.key).appendingPathComponent("rootfs.ext4")
      let templateMode =
        try FileManager.default.attributesOfItem(atPath: template.path)[.posixPermissions]
        as? NSNumber
      let sessionMode =
        try FileManager.default.attributesOfItem(atPath: session.path)[.posixPermissions]
        as? NSNumber
      #expect(templateMode?.intValue == 0o444)
      #expect(sessionMode?.intValue == 0o600)
    }

    @Test("A changed identity does not reuse the previous entry")
    func identityChangeMisses() async throws {
      let store = try TempStore()
      let cache = makeCache(store)
      let counter = UnpackCounter()

      _ = try await cache.materialize(
        identity: makeIdentity(digest: "sha256:aaaa"), imageReference: "example:1",
        imageDigest: "sha256:image-a", sessionRootfs: sessionRootfs(store, "s1"),
        unpack: { try counter.unpack(to: $0) })
      let second = try await cache.materialize(
        identity: makeIdentity(digest: "sha256:bbbb"), imageReference: "example:1",
        imageDigest: "sha256:image-b", sessionRootfs: sessionRootfs(store, "s2"),
        unpack: { try counter.unpack(to: $0) })

      #expect(second.source == .cacheMiss)
      #expect(counter.value == 2)
    }

    @Test("A failed unpack publishes nothing and the next launch retries")
    func failedUnpackPublishesNothing() async throws {
      struct Boom: Error {}
      let store = try TempStore()
      let cache = makeCache(store)
      let identity = makeIdentity()

      await #expect(throws: Boom.self) {
        _ = try await cache.materialize(
          identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
          sessionRootfs: sessionRootfs(store, "s1"),
          unpack: { _ in throw Boom() })
      }
      #expect(!cache.validateEntry(key: identity.key, identity: identity))
      #expect(
        !FileManager.default.fileExists(
          atPath: cache.entryDirectory(for: identity.key).path))

      // Nothing was left behind that a retry could mistake for a hit.
      let counter = UnpackCounter()
      let retry = try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: sessionRootfs(store, "s2"), unpack: { try counter.unpack(to: $0) })
      #expect(retry.source == .cacheMiss)
      #expect(counter.value == 1)
    }

    @Test("An interrupted publication leaves only staging, which the next run clears")
    func interruptedPublicationIsRecoverable() async throws {
      let store = try TempStore()
      let cache = makeCache(store)
      let identity = makeIdentity()

      // Simulate a process killed mid-unpack: a staging directory with a partial file.
      try FileManager.default.createDirectory(
        at: cache.stagingDirectory, withIntermediateDirectories: true)
      let abandoned = cache.stagingDirectory.appendingPathComponent("\(identity.key)-abandoned")
      try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
      try Data("partial".utf8).write(to: abandoned.appendingPathComponent("rootfs.ext4"))

      let counter = UnpackCounter()
      let result = try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: sessionRootfs(store, "s1"), unpack: { try counter.unpack(to: $0) })

      #expect(result.source == .cacheMiss)
      #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test("Materialization refuses to overwrite an existing session rootfs")
    func refusesExistingSessionRootfs() async throws {
      let store = try TempStore()
      let cache = makeCache(store)
      let session = sessionRootfs(store, "s1")
      try FileManager.default.createDirectory(
        at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("already here".utf8).write(to: session)

      await #expect(throws: RootFSCacheError.self) {
        _ = try await cache.materialize(
          identity: makeIdentity(), imageReference: "example:latest", imageDigest: "sha256:image",
          sessionRootfs: session, unpack: { try writeFakeRootfs(at: $0) })
      }
    }

    @Test("A clone failure leaves no partial session file behind")
    func cloneFailureCleansUp() async throws {
      let store = try TempStore()
      let cache = makeCache(store, fileOperations: FailingFileOperations())
      let session = sessionRootfs(store, "s1")

      await #expect(throws: FailingFileOperations.Failure.self) {
        _ = try await cache.materialize(
          identity: makeIdentity(), imageReference: "example:latest", imageDigest: "sha256:image",
          sessionRootfs: session, unpack: { try writeFakeRootfs(at: $0) })
      }
      #expect(!FileManager.default.fileExists(atPath: session.path))
    }

    @Test("Concurrent materializations publish one entry and unpack once")
    func concurrentMaterializations() async throws {
      let store = try TempStore()
      let cache = makeCache(store)
      let identity = makeIdentity()
      let counter = UnpackCounter()

      // `flock` is held per open file description, so two `FileLock`s in one process
      // exclude each other exactly as two `agentc` processes would.
      async let first = cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: sessionRootfs(store, "s1"), unpack: { try counter.unpack(to: $0) })
      async let second = cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: sessionRootfs(store, "s2"), unpack: { try counter.unpack(to: $0) })

      let results = try await [first, second]
      #expect(counter.value == 1)
      #expect(results.filter { $0.source == .cacheMiss }.count == 1)
      #expect(results.filter { $0.source == .cacheHit }.count == 1)
      #expect(cache.validateEntry(key: identity.key, identity: identity))

      let staging =
        (try? FileManager.default.contentsOfDirectory(
          at: cache.stagingDirectory, includingPropertiesForKeys: nil)) ?? []
      #expect(staging.isEmpty)
    }
  }

  // MARK: - Validation

  @Suite("Rootfs cache entry validation")
  struct RootFSCacheValidationTests {

    private func publish(
      _ cache: RootFSCache, _ identity: RootFSCacheIdentity, store: TempStore
    ) async throws {
      _ = try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: store.url.appendingPathComponent("containers/s0/rootfs.ext4"),
        unpack: { try writeFakeRootfs(at: $0) })
    }

    @Test("A published entry validates")
    func publishedEntryValidates() async throws {
      let store = try TempStore()
      let cache = RootFSCache(imageStorePath: store.url, fileOperations: CopyOnlyFileOperations())
      let identity = makeIdentity()
      try await publish(cache, identity, store: store)
      #expect(cache.validateEntry(key: identity.key, identity: identity))
    }

    @Test("A missing manifest fails validation")
    func missingManifest() async throws {
      let store = try TempStore()
      let cache = RootFSCache(imageStorePath: store.url, fileOperations: CopyOnlyFileOperations())
      let identity = makeIdentity()
      try await publish(cache, identity, store: store)
      try FileManager.default.removeItem(
        at: cache.entryDirectory(for: identity.key).appendingPathComponent("manifest.json"))
      #expect(!cache.validateEntry(key: identity.key, identity: identity))
    }

    @Test("A truncated rootfs fails the recorded-size check")
    func truncatedRootfs() async throws {
      let store = try TempStore()
      let cache = RootFSCache(imageStorePath: store.url, fileOperations: CopyOnlyFileOperations())
      let identity = makeIdentity()
      try await publish(cache, identity, store: store)

      let rootfs = cache.entryDirectory(for: identity.key).appendingPathComponent("rootfs.ext4")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: rootfs.path)
      try Data(repeating: 0, count: 16).write(to: rootfs)
      #expect(!cache.validateEntry(key: identity.key, identity: identity))
    }

    @Test("A rootfs without an ext4 superblock fails validation")
    func notAFilesystem() async throws {
      let store = try TempStore()
      let cache = RootFSCache(imageStorePath: store.url, fileOperations: CopyOnlyFileOperations())
      let identity = makeIdentity()
      try await publish(cache, identity, store: store)

      let rootfs = cache.entryDirectory(for: identity.key).appendingPathComponent("rootfs.ext4")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: rootfs.path)
      // Same length, no magic.
      try Data(repeating: 0x41, count: 4096).write(to: rootfs)
      #expect(!cache.validateEntry(key: identity.key, identity: identity))
    }

    @Test("A symlinked rootfs is rejected rather than followed")
    func rejectsSymlink() async throws {
      let store = try TempStore()
      let cache = RootFSCache(imageStorePath: store.url, fileOperations: CopyOnlyFileOperations())
      let identity = makeIdentity()
      try await publish(cache, identity, store: store)

      let rootfs = cache.entryDirectory(for: identity.key).appendingPathComponent("rootfs.ext4")
      let elsewhere = store.url.appendingPathComponent("elsewhere.ext4")
      try FileManager.default.moveItem(at: rootfs, to: elsewhere)
      try FileManager.default.createSymbolicLink(at: rootfs, withDestinationURL: elsewhere)
      #expect(!cache.validateEntry(key: identity.key, identity: identity))
    }

    @Test("A manifest recorded for a different identity fails validation")
    func identityMismatch() async throws {
      let store = try TempStore()
      let cache = RootFSCache(imageStorePath: store.url, fileOperations: CopyOnlyFileOperations())
      let identity = makeIdentity()
      try await publish(cache, identity, store: store)
      // Same key on disk, different identity asked for — refuse the entry.
      #expect(!cache.validateEntry(key: identity.key, identity: makeIdentity(digest: "sha256:zzz")))
    }

    @Test("An entry directory with no files at all fails validation")
    func emptyEntry() throws {
      let store = try TempStore()
      let cache = RootFSCache(imageStorePath: store.url)
      let identity = makeIdentity()
      try FileManager.default.createDirectory(
        at: cache.entryDirectory(for: identity.key), withIntermediateDirectories: true)
      #expect(!cache.validateEntry(key: identity.key, identity: identity))
    }
  }

  // MARK: - Maintenance

  @Suite("Rootfs cache maintenance")
  struct RootFSCacheMaintenanceTests {

    private func publish(
      _ cache: RootFSCache, _ identity: RootFSCacheIdentity, store: TempStore,
      imageDigest: String = "sha256:image", session: String
    ) async throws -> RootFSMaterialization {
      try await cache.materialize(
        identity: identity, imageReference: "example:latest", imageDigest: imageDigest,
        sessionRootfs: store.url.appendingPathComponent("containers/\(session)/rootfs.ext4"),
        unpack: { try writeFakeRootfs(at: $0) })
    }

    @Test("Pruning keeps the most recently used entries and drops the rest")
    func prunesLeastRecentlyUsed() async throws {
      let store = try TempStore()
      let cache = RootFSCache(
        imageStorePath: store.url, fileOperations: CopyOnlyFileOperations(), maxEntries: 2)

      var identities: [RootFSCacheIdentity] = []
      for index in 0..<4 {
        let identity = makeIdentity(digest: "sha256:image-\(index)")
        identities.append(identity)
        _ = try await publish(cache, identity, store: store, session: "s\(index)")
        // Space the entries out so modification times order deterministically.
        try FileManager.default.setAttributes(
          [.modificationDate: Date(timeIntervalSince1970: 1000 + Double(index))],
          ofItemAtPath: cache.entryDirectory(for: identity.key).path)
      }

      cache.prune()

      #expect(
        !FileManager.default.fileExists(atPath: cache.entryDirectory(for: identities[0].key).path))
      #expect(
        !FileManager.default.fileExists(atPath: cache.entryDirectory(for: identities[1].key).path))
      #expect(
        FileManager.default.fileExists(atPath: cache.entryDirectory(for: identities[2].key).path))
      #expect(
        FileManager.default.fileExists(atPath: cache.entryDirectory(for: identities[3].key).path))
    }

    @Test("Pruning is a no-op below the limit")
    func prunesNothingBelowLimit() async throws {
      let store = try TempStore()
      let cache = RootFSCache(
        imageStorePath: store.url, fileOperations: CopyOnlyFileOperations(), maxEntries: 4)
      let identity = makeIdentity()
      _ = try await publish(cache, identity, store: store, session: "s0")
      cache.prune()
      #expect(cache.validateEntry(key: identity.key, identity: identity))
    }

    @Test("Pruning skips an entry whose lock is held")
    func pruningSkipsLockedEntries() async throws {
      let store = try TempStore()
      let cache = RootFSCache(
        imageStorePath: store.url, fileOperations: CopyOnlyFileOperations(), maxEntries: 1)

      let keep = makeIdentity(digest: "sha256:keep")
      let busy = makeIdentity(digest: "sha256:busy")
      _ = try await publish(cache, busy, store: store, session: "s0")
      _ = try await publish(cache, keep, store: store, session: "s1")
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)],
        ofItemAtPath: cache.entryDirectory(for: busy.key).path)

      // Somebody else is working on `busy`; pruning must leave it alone rather than
      // wait for them.
      let held = try FileLock.acquire(at: cache.lockFile(for: busy.key), mode: .exclusive)
      cache.prune()
      held.release()

      #expect(FileManager.default.fileExists(atPath: cache.entryDirectory(for: busy.key).path))
    }

    @Test("Pruning does not disturb a session that already has its disk")
    func pruningDoesNotAffectActiveSession() async throws {
      let store = try TempStore()
      let cache = RootFSCache(
        imageStorePath: store.url, fileOperations: CopyOnlyFileOperations(), maxEntries: 1)

      let old = makeIdentity(digest: "sha256:old")
      let session = store.url.appendingPathComponent("containers/live/rootfs.ext4")
      _ = try await cache.materialize(
        identity: old, imageReference: "example:latest", imageDigest: "sha256:image",
        sessionRootfs: session, unpack: { try writeFakeRootfs(at: $0, payload: "live") })
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)],
        ofItemAtPath: cache.entryDirectory(for: old.key).path)

      _ = try await publish(cache, makeIdentity(digest: "sha256:new"), store: store, session: "s2")
      cache.prune()

      // The entry the live session came from is gone, and the session is unharmed.
      #expect(!FileManager.default.fileExists(atPath: cache.entryDirectory(for: old.key).path))
      #expect(try payload(of: session) == "live")
    }

    @Test("Removing an image invalidates only entries unpacked from it")
    func invalidateByImageDigest() async throws {
      let store = try TempStore()
      let cache = RootFSCache(imageStorePath: store.url, fileOperations: CopyOnlyFileOperations())

      let doomed = makeIdentity(digest: "sha256:a")
      let survivor = makeIdentity(digest: "sha256:b")
      _ = try await publish(
        cache, doomed, store: store, imageDigest: "sha256:image-a", session: "s0")
      _ = try await publish(
        cache, survivor, store: store, imageDigest: "sha256:image-b", session: "s1")

      cache.invalidate(imageDigest: "sha256:image-a")

      #expect(!cache.validateEntry(key: doomed.key, identity: doomed))
      #expect(cache.validateEntry(key: survivor.key, identity: survivor))
    }
  }

  // MARK: - Clone / copy helper

  @Suite("Rootfs file operations")
  struct RootFSFileOperationsTests {

    @Test("The system implementation produces an independent file, never a link")
    func producesIndependentFile() throws {
      let store = try TempStore()
      let source = store.url.appendingPathComponent("source.ext4")
      let destination = store.url.appendingPathComponent("destination.ext4")
      try writeFakeRootfs(at: source, payload: "original")

      let method = try SystemRootFSFileOperations().materialize(from: source, to: destination)
      #expect(method == .clone || method == .copy)

      // Not a link: the two files must not share an inode, and writing through one
      // must leave the other alone.
      let sourceInode =
        try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber]
        as? NSNumber
      let destinationInode =
        try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber]
        as? NSNumber
      #expect(sourceInode != destinationInode)

      try writeFakeRootfs(at: destination, payload: "changed")
      #expect(try payload(of: source) == "original")
    }

    @Test("Materializing onto an existing path is refused")
    func refusesExistingDestination() throws {
      let store = try TempStore()
      let source = store.url.appendingPathComponent("source.ext4")
      let destination = store.url.appendingPathComponent("destination.ext4")
      try writeFakeRootfs(at: source)
      try Data("occupied".utf8).write(to: destination)

      #expect(throws: RootFSFileOperationError.self) {
        _ = try SystemRootFSFileOperations().materialize(from: source, to: destination)
      }
      #expect(try payload(of: destination) == "occupied")
    }

    @Test("Only capability errors count as clone-unsupported")
    func classifiesCloneErrors() {
      #expect(SystemRootFSFileOperations.isCloneUnsupported(ENOTSUP))
      #expect(SystemRootFSFileOperations.isCloneUnsupported(EXDEV))
      #expect(SystemRootFSFileOperations.isCloneUnsupported(EOPNOTSUPP))
      // Permission, I/O and out-of-space failures must surface, not silently degrade.
      #expect(!SystemRootFSFileOperations.isCloneUnsupported(EACCES))
      #expect(!SystemRootFSFileOperations.isCloneUnsupported(EPERM))
      #expect(!SystemRootFSFileOperations.isCloneUnsupported(EIO))
      #expect(!SystemRootFSFileOperations.isCloneUnsupported(ENOSPC))
    }
  }

  // MARK: - Locking

  @Suite("Cache file locks")
  struct FileLockTests {

    @Test("An exclusive lock excludes another holder in the same process")
    func exclusiveLockExcludes() throws {
      let store = try TempStore()
      let file = store.url.appendingPathComponent("key.lock")

      let first = try FileLock.acquire(at: file, mode: .exclusive)
      #expect(try FileLock.tryAcquire(at: file, mode: .exclusive) == nil)
      first.release()
      let second = try FileLock.tryAcquire(at: file, mode: .exclusive)
      #expect(second != nil)
      second?.release()
    }

    @Test("Releasing twice is harmless")
    func doubleReleaseIsSafe() throws {
      let store = try TempStore()
      let file = store.url.appendingPathComponent("key.lock")
      let lock = try FileLock.acquire(at: file, mode: .exclusive)
      lock.release()
      lock.release()
      let again = try FileLock.tryAcquire(at: file, mode: .exclusive)
      #expect(again != nil)
      again?.release()
    }

    @Test("Shared locks do not exclude each other")
    func sharedLocksCoexist() throws {
      let store = try TempStore()
      let file = store.url.appendingPathComponent("key.lock")
      let first = try FileLock.acquire(at: file, mode: .shared)
      let second = try FileLock.tryAcquire(at: file, mode: .shared)
      #expect(second != nil)
      #expect(try FileLock.tryAcquire(at: file, mode: .exclusive) == nil)
      first.release()
      second?.release()
    }

    @Test("A lock file in a missing directory reports a clear error")
    func missingDirectory() throws {
      let store = try TempStore()
      let file = store.url.appendingPathComponent("nope/key.lock")
      #expect(throws: FileLock.Error.self) {
        _ = try FileLock.acquire(at: file, mode: .exclusive)
      }
    }
  }
#endif
