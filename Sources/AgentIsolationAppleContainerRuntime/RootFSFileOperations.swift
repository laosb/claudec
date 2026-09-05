import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// How a session rootfs was produced from a cached template.
public enum RootFSMaterializationMethod: String, Sendable {
  /// A copy-on-write clone. Subsequent writes to either file are independent.
  case clone
  /// A real, byte-for-byte independent copy.
  case copy
}

/// Produces an independent writable rootfs file from a cached template.
///
/// Abstracted so tests can force the copy path on a filesystem that would
/// otherwise clone, and can assert that neither path ever produces a link.
public protocol RootFSFileOperations: Sendable {
  /// Materialize `destination` from `source`.
  ///
  /// The result must be a genuinely independent file: writes to it must never be
  /// visible through `source`, and vice versa. A hard link or symlink is never an
  /// acceptable substitute — the session would be writing into the shared cache.
  ///
  /// `destination` must not already exist.
  func materialize(from source: URL, to destination: URL) throws
    -> RootFSMaterializationMethod
}

/// Errors raised while materializing a session rootfs.
public enum RootFSFileOperationError: Error, CustomStringConvertible {
  case cloneFailed(errno: Int32)
  case copyFailed(underlying: any Error)
  case destinationExists(URL)

  public var description: String {
    switch self {
    case .cloneFailed(let code):
      return "clone failed: \(String(cString: strerror(code))) (errno \(code))"
    case .copyFailed(let underlying):
      return "copy failed: \(underlying)"
    case .destinationExists(let url):
      return "refusing to overwrite existing file at \(url.path)"
    }
  }
}

#if canImport(Darwin)
  // `clonefile(2)` has shipped in libSystem since macOS 10.12 and this package
  // requires macOS 15, so the symbol is always present. It is declared here rather
  // than imported so the build does not depend on whether the Darwin module map
  // happens to re-export <sys/clonefile.h>.
  @_silgen_name("clonefile")
  private func systemClonefile(
    _ source: UnsafePointer<CChar>,
    _ destination: UnsafePointer<CChar>,
    _ flags: UInt32
  ) -> Int32
#endif

/// The default implementation: copy-on-write clone where the filesystem offers
/// one, a real copy everywhere else.
public struct SystemRootFSFileOperations: RootFSFileOperations {
  public init() {}

  public func materialize(from source: URL, to destination: URL) throws
    -> RootFSMaterializationMethod
  {
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw RootFSFileOperationError.destinationExists(destination)
    }

    if let method = try cloneIfSupported(from: source, to: destination) {
      return method
    }

    // A real copy. `copyItem` never links, so the session still gets a file it
    // can write to without touching the cached template.
    do {
      try FileManager.default.copyItem(at: source, to: destination)
    } catch {
      throw RootFSFileOperationError.copyFailed(underlying: error)
    }
    return .copy
  }

  /// Attempt a copy-on-write clone.
  ///
  /// Returns `nil` when the filesystem simply cannot clone — the caller should
  /// then make a real copy. Every other failure (permissions, I/O, no space) is
  /// thrown, because silently degrading those to a full copy would hide a real
  /// problem and could fill the disk.
  private func cloneIfSupported(from source: URL, to destination: URL) throws
    -> RootFSMaterializationMethod?
  {
    #if canImport(Darwin)
      let result = source.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
        guard let sourcePath else { return -1 }
        return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
          guard let destinationPath else { return -1 }
          return systemClonefile(sourcePath, destinationPath, 0)
        }
      }
      if result == 0 { return .clone }
      let code = errno
      guard Self.isCloneUnsupported(code) else {
        throw RootFSFileOperationError.cloneFailed(errno: code)
      }
      return nil
    #elseif canImport(Glibc)
      // Reflink support (btrfs, xfs with reflink=1, bcachefs). ext4 and tmpfs
      // reject it, which is the ordinary case on a Linux test machine.
      // _IOW(0x94, 9, int), stable across the architectures we target.
      let ficlone: CUnsignedLong = 0x4004_9409
      let sourceFD = open(source.path, O_RDONLY | O_CLOEXEC)
      guard sourceFD >= 0 else { throw RootFSFileOperationError.cloneFailed(errno: errno) }
      defer { close(sourceFD) }

      var sourceInfo = stat()
      guard fstat(sourceFD, &sourceInfo) == 0 else {
        throw RootFSFileOperationError.cloneFailed(errno: errno)
      }

      let destinationFD = open(
        destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, sourceInfo.st_mode & 0o7777)
      guard destinationFD >= 0 else {
        throw RootFSFileOperationError.cloneFailed(errno: errno)
      }
      var cloned = false
      defer {
        close(destinationFD)
        // A failed FICLONE leaves an empty file behind; the copy path needs the
        // destination not to exist.
        if !cloned { try? FileManager.default.removeItem(at: destination) }
      }
      if ioctl(destinationFD, ficlone, sourceFD) == 0 {
        cloned = true
        return .clone
      }
      let code = errno
      guard Self.isCloneUnsupported(code) else {
        throw RootFSFileOperationError.cloneFailed(errno: code)
      }
      return nil
    #else
      return nil
    #endif
  }

  /// Whether an errno means "this filesystem pair cannot clone", as opposed to a
  /// genuine failure that must be surfaced.
  static func isCloneUnsupported(_ code: Int32) -> Bool {
    // EOPNOTSUPP and ENOTSUP share a value on Linux but differ on Darwin, so both
    // are listed. EXDEV is a cross-volume clone; EINVAL is what several
    // filesystems return for an unsupported reflink.
    code == ENOTSUP || code == EOPNOTSUPP || code == EXDEV || code == EINVAL
  }
}
