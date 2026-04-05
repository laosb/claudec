import Foundation

/// Orchestrates running an isolated agent container session using a ``ContainerRuntime``.
///
/// `AgentSession` is responsible for:
/// - Preparing the runtime
/// - Computing workspace paths and directory layout
/// - Building container mounts (profile home, workspace, exclude overlays, bootstrap script)
/// - Configuring and running the container
/// - Performing necessary cleanups (temp dirs)
public struct AgentSession<Runtime: ContainerRuntime>: Sendable {
  public let config: IsolationConfig
  public let runtime: Runtime

  public init(config: IsolationConfig, runtime: Runtime) {
    self.config = config
    self.runtime = runtime
  }

  /// Run the agent session and return the container process exit code.
  public func run() async throws -> Int32 {
    try await runtime.prepare()

    let canonicalWorkspace = resolveSymlinksWithPrivate(config.workspace)
    let wsContainerPath = workspaceContainerPath(for: config.workspace)

    try FileManager.default.createDirectory(
      at: config.profileHomeDir,
      withIntermediateDirectories: true
    )

    // Build mounts list
    var mounts: [ContainerConfiguration.Mount] = []

    // Profile home → /home/claude
    mounts.append(
      .init(
        hostPath: config.profileHomeDir.path,
        containerPath: "/home/claude"
      ))

    // Workspace
    mounts.append(
      .init(
        hostPath: canonicalWorkspace.path,
        containerPath: wsContainerPath
      ))

    // Excluded folders: each gets an empty temp dir mounted as a read-only overlay
    var tempDirs: [URL] = []
    defer {
      for dir in tempDirs {
        try? FileManager.default.removeItem(at: dir)
      }
    }

    for rawFolder in config.excludeFolders {
      let folder = rawFolder.trimmingCharacters(in: .init(charactersIn: "/"))
      guard !folder.isEmpty else { continue }
      let tempDir = try makeTempDir()
      tempDirs.append(tempDir)
      mounts.append(
        .init(
          hostPath: resolveSymlinksWithPrivate(tempDir).path,
          containerPath: "\(wsContainerPath)/\(folder)",
          isReadOnly: true
        ))
    }

    // Bootstrap script: copy to temp dir so it can be shared as a virtiofs volume
    var entrypoint = config.arguments
    if let bootstrapScript = config.bootstrapScript {
      let tempDir = try makeTempDir()
      tempDirs.append(tempDir)
      let dest = tempDir.appendingPathComponent("entrypoint.sh")
      try FileManager.default.copyItem(at: bootstrapScript, to: dest)

      let srcPerms =
        (try? FileManager.default.attributesOfItem(
          atPath: bootstrapScript.path
        )[.posixPermissions] as? Int) ?? 0o644
      try FileManager.default.setAttributes(
        [.posixPermissions: srcPerms | 0o111],
        ofItemAtPath: dest.path
      )

      mounts.append(
        .init(
          hostPath: resolveSymlinksWithPrivate(tempDir).path,
          containerPath: "/entrypoint-bootstrap"
        ))
      entrypoint = ["/entrypoint-bootstrap/entrypoint.sh"] + config.arguments
    }

    let io: ContainerConfiguration.IO =
      config.allocateTTY ? .currentTerminal : .standardIO

    let containerConfig = ContainerConfiguration(
      entrypoint: entrypoint,
      overridesImageEntrypoint: config.bootstrapScript != nil,
      workingDirectory: wsContainerPath,
      mounts: mounts,
      io: io
    )

    let container = try await runtime.runContainer(
      imageRef: config.image,
      configuration: containerConfig
    )
    defer { _runBlocking { try await runtime.removeContainer(container) } }

    let exitCode = try await container.wait(timeoutInSeconds: nil)
    try await container.stop()
    return exitCode
  }

  // MARK: - Helpers

  private func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/claudec-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

}

/// Fire-and-forget helper for calling async cleanup in a defer block.
private func _runBlocking(_ body: @escaping @Sendable () async throws -> Void) {
  // Best-effort cleanup — runs on a detached task since defer can't be async.
  Task { try? await body() }
}
