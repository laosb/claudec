import Foundation
import Synchronization
import Testing

@testable import AgentIsolation

/// Collects timing records emitted during a test.
private final class TimingRecorder: Sendable {
  private let storage = Mutex<[StartupTiming]>([])

  /// A diagnostics value that appends into this recorder.
  ///
  /// The closure captures the recorder itself; `Mutex` is non-copyable, so it can
  /// never be captured directly.
  var diagnostics: StartupDiagnostics {
    StartupDiagnostics { timing in self.append(timing) }
  }

  private func append(_ timing: StartupTiming) {
    storage.withLock { $0.append(timing) }
  }

  var recorded: [StartupTiming] { storage.withLock { $0 } }
}

@Suite("Startup diagnostics record format")
struct StartupDiagnosticsFormatTests {

  @Test("A plain record renders phase, duration, and outcome")
  func plainRecord() {
    let line = StartupDiagnostics.format(
      StartupTiming(phase: "rootfs.materialize", durationMilliseconds: 12.44, outcome: .success))
    #expect(line == "agentc: timing phase=rootfs.materialize duration_ms=12.4 outcome=success")
  }

  @Test("Attributes are appended in the order they were set")
  func attributeOrder() {
    let line = StartupDiagnostics.format(
      StartupTiming(
        phase: "profile.ownership",
        durationMilliseconds: 0.83,
        outcome: .success,
        attributes: [.init("action", "verified"), .init("visited", "0"), .init("changed", "0")]))
    #expect(
      line == "agentc: timing phase=profile.ownership duration_ms=0.8 outcome=success "
        + "action=verified visited=0 changed=0")
  }

  @Test("Values containing spaces are quoted")
  func quotesSpaces() {
    #expect(StartupDiagnostics.escape("my config") == "\"my config\"")
  }

  @Test("Values containing an equals sign are quoted so they stay one field")
  func quotesEquals() {
    #expect(StartupDiagnostics.escape("a=b") == "\"a=b\"")
  }

  @Test("Quotes and backslashes are escaped")
  func escapesQuotes() {
    #expect(StartupDiagnostics.escape(#"say "hi"\"#) == #""say \"hi\"\\""#)
  }

  @Test("Newlines cannot break a record onto a second line")
  func escapesNewlines() {
    let value = "evil\nagentc: timing phase=forged"
    let escaped = StartupDiagnostics.escape(value)
    #expect(!escaped.contains("\n"))
    #expect(escaped.contains("\\n"))
  }

  @Test("Control characters are hex-escaped")
  func escapesControlCharacters() {
    #expect(StartupDiagnostics.escape("a\u{0}b") == "\"a\\x00b\"")
    #expect(StartupDiagnostics.escape("a\u{7f}b") == "\"a\\x7fb\"")
  }

  @Test("Empty values are quoted rather than vanishing")
  func quotesEmpty() {
    #expect(StartupDiagnostics.escape("") == "\"\"")
  }

  @Test("Ordinary values are left unquoted")
  func leavesPlainValuesAlone() {
    #expect(StartupDiagnostics.escape("clone") == "clone")
    #expect(StartupDiagnostics.escape("sha256:abc-123.def") == "sha256:abc-123.def")
  }

  @Test("Attribute names are reduced to a safe alphabet")
  func sanitizesNames() {
    #expect(StartupDiagnostics.sanitizeName("cache hit") == "cache_hit")
    #expect(StartupDiagnostics.sanitizeName("a=b") == "a_b")
    #expect(StartupDiagnostics.sanitizeName("visited") == "visited")
    #expect(StartupDiagnostics.sanitizeName("") == "_")
  }

  @Test("A configuration name cannot forge extra fields")
  func configurationNameCannotForgeFields() {
    let line = StartupDiagnostics.format(
      StartupTiming(
        phase: "bootstrap.prepare_script",
        durationMilliseconds: 1,
        outcome: .success,
        attributes: [.init("configuration", "x outcome=success secret=leaked")]))
    // Everything the caller supplied stays inside a single quoted field, so the
    // `outcome=` it contains cannot be mistaken for a record of its own.
    #expect(
      line == "agentc: timing phase=bootstrap.prepare_script duration_ms=1.0 outcome=success "
        + "configuration=\"x outcome=success secret=leaked\"")
  }
}

@Suite("Startup diagnostics spans")
struct StartupDiagnosticsSpanTests {

  @Test("A successful span records its phase and outcome")
  func recordsSuccess() async throws {
    let recorder = TimingRecorder()
    let value = await recorder.diagnostics.span("cli.thing") { _ in
      await Task.yield()
      return 42
    }
    #expect(value == 42)
    #expect(recorder.recorded.count == 1)
    #expect(recorder.recorded[0].phase == "cli.thing")
    #expect(recorder.recorded[0].outcome == .success)
  }

  @Test("A throwing span records failure and rethrows")
  func recordsFailure() async {
    struct Boom: Error {}
    let recorder = TimingRecorder()
    await #expect(throws: Boom.self) {
      try await recorder.diagnostics.span("cli.thing") { _ in
        await Task.yield()
        throw Boom()
      }
    }
    #expect(recorder.recorded.count == 1)
    #expect(recorder.recorded[0].outcome == .failure)
  }

  @Test("Cancellation is distinguished from other failures")
  func recordsCancellation() async {
    let recorder = TimingRecorder()
    await #expect(throws: CancellationError.self) {
      try await recorder.diagnostics.span("cli.thing") { _ in
        await Task.yield()
        throw CancellationError()
      }
    }
    #expect(recorder.recorded[0].outcome == .cancelled)
  }

  @Test("Attributes set inside the body are recorded")
  func recordsContextAttributes() async {
    let recorder = TimingRecorder()
    await recorder.diagnostics.span("rootfs.materialize") { context in
      await Task.yield()
      context.set("method", "clone")
      context.set("hit", true)
      context.set("visited", 0)
    }
    let attributes = recorder.recorded[0].attributes
    #expect(attributes == [.init("method", "clone"), .init("hit", "true"), .init("visited", "0")])
  }

  @Test("Setting an attribute twice replaces it in place")
  func replacesAttribute() async {
    let recorder = TimingRecorder()
    await recorder.diagnostics.span("rootfs.materialize") { context in
      await Task.yield()
      context.set("method", "clone")
      context.set("method", "copy")
    }
    #expect(recorder.recorded[0].attributes == [.init("method", "copy")])
  }

  @Test("With no diagnostics the body still runs and nothing is recorded")
  func nilDiagnosticsStillRunsBody() async {
    let diagnostics: StartupDiagnostics? = nil
    var ran = false
    await diagnostics.span("cli.thing") { context in
      await Task.yield()
      ran = true
      // A nil context must be safe to annotate.
      context?.set("method", "clone")
    }
    #expect(ran)
  }

  @Test("The optional wrapper records when diagnostics are present")
  func optionalWrapperRecords() async {
    let recorder = TimingRecorder()
    let diagnostics: StartupDiagnostics? = recorder.diagnostics
    await diagnostics.span("cli.thing") { context in
      await Task.yield()
      context?.set("mode", "file")
    }
    #expect(recorder.recorded.count == 1)
    #expect(recorder.recorded[0].attributes == [.init("mode", "file")])
  }

  @Test("Durations are non-negative and finite")
  func durationsAreSane() async {
    let recorder = TimingRecorder()
    await recorder.diagnostics.span("cli.thing") { _ in await Task.yield() }
    let duration = recorder.recorded[0].durationMilliseconds
    #expect(duration >= 0)
    #expect(duration.isFinite)
  }
}

@Suite("Bootstrap mode diagnostics label")
struct BootstrapModeLabelTests {

  @Test("The label names the mode without leaking the bootstrap path")
  func labelsWithoutPaths() {
    let mode = BootstrapMode.file(URL(fileURLWithPath: "/Users/someone/secret/bootstrap"))
    #expect(mode.diagnosticLabel == "file")
    #expect(BootstrapMode.imageDefault.diagnosticLabel == "image-default")
  }
}
