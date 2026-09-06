// The store, its lock discipline and its sweep carry no Containerization
// dependency, so this file builds — and is tested — on Linux as well as macOS.
import AgentIsolation
import Foundation

/// The per-session directories `ContainerManager` is given, one per container.
///
/// Each holds that session's writable rootfs, which is measured in gigabytes, so a
/// directory that outlives the process that created it is a real disk leak — and
/// an ordinary run cannot tell a crashed session's leftovers from a live one by
/// looking at the files alone.
///
/// Every session therefore takes an exclusive `flock` on `owner.lock` inside its
/// directory and holds it until teardown. The kernel drops that lock when the
/// process dies, however it dies, which makes "nobody holds this lock" the
/// definition of an abandoned session. Apple's VMs run inside the `agentc`
/// process, so a directory whose owner is gone cannot still have a container
/// behind it.
struct SessionDirectoryStore: Sendable {
  /// Name of the lock file each session holds for its lifetime.
  ///
  /// It lives inside the session directory rather than beside it: the directory is
  /// removed as a whole, and unlinking a lock file while its holder still has the
  /// descriptor open is harmless.
  static let lockName = "owner.lock"

  /// How long a session directory is left alone regardless of its lock.
  ///
  /// A session that has just created its directory has not taken its lock yet.
  /// Ignoring anything younger than this closes that window without needing the
  /// two steps to be atomic.
  static let defaultGrace: TimeInterval = 60

  /// Where session directories live, e.g. `<imagestore>/containers`.
  let root: URL
  let grace: TimeInterval

  init(root: URL, grace: TimeInterval = SessionDirectoryStore.defaultGrace) {
    self.root = root
    self.grace = grace
  }

  func directory(for id: String) -> URL {
    root.appendingPathComponent(id)
  }

  func lockFile(in directory: URL) -> URL {
    directory.appendingPathComponent(Self.lockName)
  }

  // MARK: - Claiming

  /// Create a session's directory and mark it live.
  ///
  /// Returns the lock the caller must hold for as long as the session owns the
  /// directory. A `nil` lock means the directory could not be marked — the session
  /// still runs, it just will not be swept later, which errs towards leaving files
  /// behind rather than deleting a directory that is in use.
  func claim(id: String) throws -> (directory: URL, lock: FileLock?) {
    let directory = directory(for: id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, claimLock(in: directory))
  }

  private func claimLock(in directory: URL) -> FileLock? {
    let file = lockFile(in: directory)
    guard let lock = try? FileLock.tryAcquire(at: file, mode: .exclusive) else {
      // Either the file could not be opened — in which case nothing was created —
      // or it exists but could not be locked. Take the marker back out rather than
      // leave an unheld lock file that a later sweep would read as abandoned.
      try? FileManager.default.removeItem(at: file)
      return nil
    }
    return lock
  }

  // MARK: - Inspection

  /// Session IDs that still have a live owner.
  ///
  /// `nil` means the answer is unknown — the directory is there but could not be
  /// read — which callers must treat as "cannot tell", never as "none". A missing
  /// directory is a definite empty answer.
  func liveIDs() -> Set<String>? {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])
    else {
      return FileManager.default.fileExists(atPath: root.path) ? nil : []
    }
    return Set(
      entries
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        .filter { !isAbandoned($0) }
        .map(\.lastPathComponent))
  }

  /// Whether a session directory's owner is provably gone.
  ///
  /// Conservative on every uncertainty: a directory with no lock file at all was
  /// made by an `agentc` that predates this marker and could still be running, and
  /// one younger than ``grace`` may be mid-creation. Neither is reported abandoned.
  func isAbandoned(_ directory: URL) -> Bool {
    let file = lockFile(in: directory)
    guard FileManager.default.fileExists(atPath: file.path) else { return false }
    guard age(of: directory).map({ $0 >= grace }) ?? false else { return false }
    guard let lock = try? FileLock.tryAcquire(at: file, mode: .exclusive) else { return false }
    lock.release()
    return true
  }

  /// Time since the directory was created, or `nil` when that cannot be read.
  ///
  /// Creation time is what matters: a live session writes its boot log and rootfs
  /// inside the directory, so modification time says nothing about its age.
  private func age(of directory: URL) -> TimeInterval? {
    let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
    guard let values = try? directory.resourceValues(forKeys: keys) else { return nil }
    guard let created = values.creationDate ?? values.contentModificationDate else { return nil }
    // Clamped: a filesystem timestamp and `Date()` come from different clocks and
    // can disagree by a hair, so a directory made moments ago can read as created
    // in the future. That must not come out as a negative age, which would be
    // younger than any grace period at all.
    return max(0, Date().timeIntervalSince(created))
  }

  // MARK: - Maintenance

  /// Remove every session directory whose owner is gone, returning how many went.
  ///
  /// Best-effort throughout: a directory that cannot be read or removed is left
  /// for the next run rather than failing a startup over it.
  @discardableResult
  func sweep() -> Int {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    var removed = 0
    for entry in entries {
      guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
        continue
      }
      guard isAbandoned(entry) else { continue }
      guard (try? FileManager.default.removeItem(at: entry)) != nil else { continue }
      removed += 1
    }
    return removed
  }
}
