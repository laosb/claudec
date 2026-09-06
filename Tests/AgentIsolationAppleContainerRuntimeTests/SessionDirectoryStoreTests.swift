// The store and its lock discipline carry no Containerization dependency, so
// these run on Linux as well as macOS — but only when the Apple runtime target
// is actually linked in.
#if ContainerRuntimeAppleContainer
  import AgentIsolation
  import Foundation
  import Testing

  @testable import AgentIsolationAppleContainerRuntime

  // MARK: - Fixtures

  /// A throwaway directory that stands in for `<imagestore>/containers`.
  private final class TempRoot: Sendable {
    let url: URL

    init() throws {
      url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("session-store-tests-\(UUID().uuidString.lowercased())")
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Write a stand-in for a session's rootfs, so a sweep has something to reclaim.
  private func writeRootfs(in directory: URL) throws {
    try Data(repeating: 0, count: 1024).write(
      to: directory.appendingPathComponent("rootfs.ext4"))
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  // MARK: - Tests

  @Suite("Session directory store")
  struct SessionDirectoryStoreTests {

    @Test("Claiming creates the directory and marks it live")
    func claimCreatesAndMarks() throws {
      let root = try TempRoot()
      // Grace 0: only the lock decides, so the test is not about timing.
      let store = SessionDirectoryStore(root: root.url, grace: 0)

      let (directory, lock) = try store.claim(id: "session-a")
      defer { lock?.release() }

      #expect(directory.path == root.url.appendingPathComponent("session-a").path)
      #expect(exists(directory))
      #expect(lock != nil)
      #expect(exists(store.lockFile(in: directory)))
    }

    @Test("A held session is live and is never swept")
    func heldSessionSurvives() throws {
      let root = try TempRoot()
      let store = SessionDirectoryStore(root: root.url, grace: 0)

      let (directory, lock) = try store.claim(id: "session-a")
      defer { lock?.release() }
      try writeRootfs(in: directory)

      #expect(store.isAbandoned(directory) == false)
      #expect(store.liveIDs() == ["session-a"])
      #expect(store.sweep() == 0)
      #expect(exists(directory))
    }

    @Test("A session whose owner is gone is abandoned and swept")
    func releasedSessionIsReclaimed() throws {
      let root = try TempRoot()
      let store = SessionDirectoryStore(root: root.url, grace: 0)

      let (directory, lock) = try store.claim(id: "session-a")
      try writeRootfs(in: directory)
      // Releasing stands in for the owning process dying: the kernel drops the
      // lock either way.
      lock?.release()

      #expect(store.isAbandoned(directory))
      #expect(store.liveIDs() == [])
      #expect(store.sweep() == 1)
      #expect(exists(directory) == false)
    }

    @Test("A sweep reclaims only the sessions nobody holds")
    func sweepIsSelective() throws {
      let root = try TempRoot()
      let store = SessionDirectoryStore(root: root.url, grace: 0)

      let (live, liveLock) = try store.claim(id: "live")
      defer { liveLock?.release() }
      let (dead, deadLock) = try store.claim(id: "dead")
      deadLock?.release()

      #expect(store.sweep() == 1)
      #expect(exists(live))
      #expect(exists(dead) == false)
    }

    @Test("A directory with no owner lock is left alone")
    func unmarkedDirectorySurvives() throws {
      let root = try TempRoot()
      let store = SessionDirectoryStore(root: root.url, grace: 0)

      // What an agentc from before this marker leaves behind. It cannot be told
      // apart from a running session, so it is never removed automatically.
      let legacy = root.url.appendingPathComponent("legacy")
      try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
      try writeRootfs(in: legacy)

      #expect(store.isAbandoned(legacy) == false)
      #expect(store.liveIDs() == ["legacy"])
      #expect(store.sweep() == 0)
      #expect(exists(legacy))
    }

    @Test("A young directory is left alone whatever its lock says")
    func graceProtectsYoungDirectories() throws {
      let root = try TempRoot()
      // The default grace: a session that has just created its directory has not
      // taken its lock yet, and must not be swept out from under itself.
      let store = SessionDirectoryStore(root: root.url)

      let (directory, lock) = try store.claim(id: "starting")
      lock?.release()

      #expect(store.isAbandoned(directory) == false)
      #expect(store.liveIDs() == ["starting"])
      #expect(store.sweep() == 0)
      #expect(exists(directory))
    }

    @Test("Files beside session directories are ignored")
    func filesAreIgnored() throws {
      let root = try TempRoot()
      let store = SessionDirectoryStore(root: root.url, grace: 0)

      let stray = root.url.appendingPathComponent("stray.txt")
      try Data("not a session".utf8).write(to: stray)

      #expect(store.liveIDs() == [])
      #expect(store.sweep() == 0)
      #expect(exists(stray))
    }

    @Test("A missing root means no sessions, not an unknown answer")
    func missingRootIsEmpty() throws {
      let root = try TempRoot()
      let store = SessionDirectoryStore(
        root: root.url.appendingPathComponent("containers"), grace: 0)

      #expect(store.liveIDs() == [])
      #expect(store.sweep() == 0)
    }
  }
#endif
