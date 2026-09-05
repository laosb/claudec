import Synchronization

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// How a measured startup phase ended.
public enum StartupSpanOutcome: String, Sendable {
  case success
  case failure
  case cancelled
}

/// A single `key=value` pair attached to a ``StartupTiming`` record.
public struct StartupTimingAttribute: Sendable, Equatable {
  public var name: String
  public var value: String

  public init(_ name: String, _ value: String) {
    self.name = name
    self.value = value
  }
}

/// One measured startup phase.
///
/// Durations come from a monotonic clock, so they are unaffected by wall-clock
/// adjustments. Spans from the host and the guest are recorded independently and
/// are **not** comparable as timestamps: never subtract one from the other, and
/// never add overlapping spans together as if they ran back to back.
public struct StartupTiming: Sendable {
  public var phase: String
  public var durationMilliseconds: Double
  public var outcome: StartupSpanOutcome
  public var attributes: [StartupTimingAttribute]

  public init(
    phase: String,
    durationMilliseconds: Double,
    outcome: StartupSpanOutcome,
    attributes: [StartupTimingAttribute] = []
  ) {
    self.phase = phase
    self.durationMilliseconds = durationMilliseconds
    self.outcome = outcome
    self.attributes = attributes
  }
}

/// Collects attributes discovered while a span is running.
///
/// A span often only learns what it did part-way through — whether a cache was
/// hit, which materialization method worked — so the body receives a context it
/// can annotate instead of having to pre-declare everything.
public final class StartupSpanContext: Sendable {
  private let storage: Mutex<[StartupTimingAttribute]>

  init(attributes: [StartupTimingAttribute]) {
    self.storage = Mutex(attributes)
  }

  /// Set an attribute, replacing any existing value for `name`.
  public func set(_ name: String, _ value: String) {
    storage.withLock { storage in
      if let index = storage.firstIndex(where: { $0.name == name }) {
        storage[index].value = value
      } else {
        storage.append(StartupTimingAttribute(name, value))
      }
    }
  }

  /// Set an integer attribute.
  public func set(_ name: String, _ value: Int) {
    set(name, String(value))
  }

  /// Set a boolean attribute.
  public func set(_ name: String, _ value: Bool) {
    set(name, value ? "true" : "false")
  }

  var attributes: [StartupTimingAttribute] {
    storage.withLock { $0 }
  }
}

/// An optional sink for startup phase measurements.
///
/// Diagnostics are strictly a side channel: records are handed to `emit`, which
/// callers are expected to route to stderr so they can never contaminate the
/// workload's stdout. When no diagnostics are configured, ``span(_:attributes:_:)``
/// still runs the body — measurement is skipped, not the work.
public struct StartupDiagnostics: Sendable {
  private let emit: @Sendable (StartupTiming) -> Void

  public init(emit: @escaping @Sendable (StartupTiming) -> Void) {
    self.emit = emit
  }

  /// Record an already-measured phase.
  public func record(_ timing: StartupTiming) {
    emit(timing)
  }

  /// Record a phase measured elsewhere.
  public func record(
    phase: String,
    durationMilliseconds: Double,
    outcome: StartupSpanOutcome = .success,
    attributes: [StartupTimingAttribute] = []
  ) {
    emit(
      StartupTiming(
        phase: phase,
        durationMilliseconds: durationMilliseconds,
        outcome: outcome,
        attributes: attributes))
  }

  /// Measure an asynchronous phase.
  ///
  /// The outcome distinguishes cancellation from other failures; the error is
  /// always rethrown, so instrumentation never swallows a startup failure.
  public func span<T>(
    _ phase: String,
    attributes: [StartupTimingAttribute] = [],
    _ body: (StartupSpanContext) async throws -> T
  ) async rethrows -> T {
    let context = StartupSpanContext(attributes: attributes)
    let start = ContinuousClock.now
    do {
      let value = try await body(context)
      finish(phase, start, .success, context)
      return value
    } catch {
      finish(phase, start, Self.outcome(for: error), context)
      throw error
    }
  }

  /// Measure a synchronous phase.
  public func span<T>(
    _ phase: String,
    attributes: [StartupTimingAttribute] = [],
    _ body: (StartupSpanContext) throws -> T
  ) rethrows -> T {
    let context = StartupSpanContext(attributes: attributes)
    let start = ContinuousClock.now
    do {
      let value = try body(context)
      finish(phase, start, .success, context)
      return value
    } catch {
      finish(phase, start, Self.outcome(for: error), context)
      throw error
    }
  }

  private func finish(
    _ phase: String,
    _ start: ContinuousClock.Instant,
    _ outcome: StartupSpanOutcome,
    _ context: StartupSpanContext
  ) {
    let elapsed = ContinuousClock.now - start
    emit(
      StartupTiming(
        phase: phase,
        durationMilliseconds: Self.milliseconds(elapsed),
        outcome: outcome,
        attributes: context.attributes))
  }

  static func outcome(for error: any Error) -> StartupSpanOutcome {
    error is CancellationError ? .cancelled : .failure
  }

  static func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }
}

// MARK: - Formatting

extension StartupDiagnostics {
  /// Render a timing record as a single compact stderr line.
  ///
  /// The format is intentionally flat and greppable:
  /// `agentc: timing phase=rootfs.materialize duration_ms=12.4 outcome=success method=clone`.
  /// Values are escaped, so a configuration name containing spaces or control
  /// characters cannot break the line format or forge extra fields.
  public static func format(_ timing: StartupTiming) -> String {
    var line = "agentc: timing phase=\(escape(timing.phase))"
    line += " duration_ms=\(formatMilliseconds(timing.durationMilliseconds))"
    line += " outcome=\(timing.outcome.rawValue)"
    for attribute in timing.attributes {
      line += " \(sanitizeName(attribute.name))=\(escape(attribute.value))"
    }
    return line
  }

  /// A stderr-writing sink suitable for ``init(emit:)``.
  public static func stderrSink(
    write: @escaping @Sendable (String) -> Void
  ) -> @Sendable (StartupTiming) -> Void {
    { timing in write(format(timing) + "\n") }
  }

  static func formatMilliseconds(_ value: Double) -> String {
    guard value.isFinite else { return "0.0" }
    return String(format: "%.1f", value)
  }

  /// Restrict attribute names to a safe identifier alphabet.
  static func sanitizeName(_ name: String) -> String {
    let mapped = name.map { character -> Character in
      let isSafe =
        character.isASCII
        && (character.isLetter || character.isNumber || character == "_" || character == ".")
      return isSafe ? character : "_"
    }
    return mapped.isEmpty ? "_" : String(mapped)
  }

  /// Quote and escape a value so it always occupies exactly one field.
  static func escape(_ value: String) -> String {
    var needsQuoting = value.isEmpty
    var escaped = ""
    escaped.reserveCapacity(value.count)
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\":
        escaped += "\\\\"
        needsQuoting = true
      case "\"":
        escaped += "\\\""
        needsQuoting = true
      case "\n":
        escaped += "\\n"
        needsQuoting = true
      case "\r":
        escaped += "\\r"
        needsQuoting = true
      case "\t":
        escaped += "\\t"
        needsQuoting = true
      default:
        if scalar.value < 0x20 || scalar.value == 0x7f {
          escaped += String(format: "\\x%02x", scalar.value)
          needsQuoting = true
        } else {
          if scalar == " " || scalar == "=" { needsQuoting = true }
          escaped.unicodeScalars.append(scalar)
        }
      }
    }
    return needsQuoting ? "\"\(escaped)\"" : escaped
  }
}

// MARK: - Optional convenience

extension Optional where Wrapped == StartupDiagnostics {
  /// Measure an asynchronous phase when diagnostics are configured.
  ///
  /// With no diagnostics the body still runs — it just receives a `nil` context and
  /// nothing is recorded — so call sites need no branch of their own.
  public func span<T>(
    _ phase: String,
    attributes: [StartupTimingAttribute] = [],
    _ body: (StartupSpanContext?) async throws -> T
  ) async rethrows -> T {
    guard let diagnostics = self else { return try await body(nil) }
    return try await diagnostics.span(phase, attributes: attributes) { context in
      try await body(context)
    }
  }

  /// Measure a synchronous phase when diagnostics are configured.
  public func span<T>(
    _ phase: String,
    attributes: [StartupTimingAttribute] = [],
    _ body: (StartupSpanContext?) throws -> T
  ) rethrows -> T {
    guard let diagnostics = self else { return try body(nil) }
    return try diagnostics.span(phase, attributes: attributes) { context in
      try body(context)
    }
  }
}
