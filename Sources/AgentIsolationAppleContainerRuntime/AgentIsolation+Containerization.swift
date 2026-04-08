#if canImport(Containerization)
  import AgentIsolation
  import Containerization
  import Foundation

  struct ContainerizationReaderStream: Containerization.ReaderStream {
    private let reader: any AgentIsolation.ReaderStream

    init(_ reader: any AgentIsolation.ReaderStream) {
      self.reader = reader
    }

    @inlinable func stream() -> AsyncStream<Data> {
      reader.stream()
    }
  }

  struct ContainerizationWriter: Containerization.Writer {
    private let writer: any AgentIsolation.Writer

    init(_ writer: any AgentIsolation.Writer) {
      self.writer = writer
    }

    @inlinable func write(_ data: Data) throws {
      try writer.write(data)
    }

    @inlinable func close() throws {
      try writer.close()
    }
  }

#endif
