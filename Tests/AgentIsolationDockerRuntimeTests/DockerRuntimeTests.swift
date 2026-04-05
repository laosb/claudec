#if ContainerRuntimeDocker
  import AgentIsolation
  @testable import AgentIsolationDockerRuntime
  import Foundation
  import Testing

  // MARK: - DockerRuntime Unit Tests

  @Suite("DockerRuntime")
  struct DockerRuntimeTests {

    @Test("DockerImage conforms to ContainerRuntimeImage")
    func imageConformance() {
      var image = DockerImage(ref: "nginx:latest", digest: "sha256:abc123")
      #expect(image.ref == "nginx:latest")
      #expect(image.digest == "sha256:abc123")

      image.ref = "nginx:1.25"
      image.digest = "sha256:def456"
      #expect(image.ref == "nginx:1.25")
      #expect(image.digest == "sha256:def456")
    }

    @Test("DockerContainer conforms to ContainerRuntimeContainer")
    func containerConformance() {
      let _: any ContainerRuntimeContainer.Type = DockerContainer.self
    }

    @Test("DockerRuntime init accepts configuration")
    func runtimeInit() async throws {
      let config = ContainerRuntimeConfiguration(
        storagePath: "/tmp/test",
        endpoint: "/var/run/docker.sock"
      )
      let runtime = DockerRuntime(config: config)
      try await runtime.shutdown()
    }

    @Test("DockerRuntime init uses default endpoint when nil")
    func runtimeDefaultEndpoint() async throws {
      let config = ContainerRuntimeConfiguration(storagePath: "/tmp/test")
      let runtime = DockerRuntime(config: config)
      try await runtime.shutdown()
    }

    @Test("DockerRuntimeError has descriptive messages")
    func errorDescriptions() {
      let errors: [DockerRuntimeError] = [
        .dockerNotAccessible("connection refused"),
        .pullFailed("image not found"),
        .imageNotFound("nginx:latest"),
        .apiError(500, "internal server error"),
        .attachFailed("connection timeout"),
        .socketError("permission denied"),
      ]

      for error in errors {
        let description = error.errorDescription ?? ""
        #expect(!description.isEmpty, "Error should have a description: \(error)")
      }
    }

    @Test("currentPlatformJSON returns valid JSON for current architecture")
    func platformJSON() {
      let json = DockerRuntime.currentPlatformJSON
      #expect(!json.isEmpty, "Platform JSON should not be empty on supported architectures")

      // Parse and verify structure
      let data = Data(json.utf8)
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
      #expect(obj != nil, "Should be valid JSON")
      #expect(obj?["os"] == "linux")

      let arch = obj?["architecture"]
      #if arch(arm64)
        #expect(arch == "arm64")
      #elseif arch(x86_64)
        #expect(arch == "amd64")
      #endif
    }

    @Test("DockerRuntime is Sendable")
    func runtimeSendable() async throws {
      let config = ContainerRuntimeConfiguration(storagePath: "/tmp/test")
      let runtime = DockerRuntime(config: config)
      defer { Task { try? await runtime.shutdown() } }

      // Verify Sendable by passing across isolation boundaries
      let _: any Sendable = runtime
    }

    @Test("DockerImage is Sendable")
    func imageSendable() {
      let image = DockerImage(ref: "test:latest", digest: "sha256:abc")
      let _: any Sendable = image
    }
  }

  // MARK: - DockerAPIClient URL Construction Tests

  @Suite("DockerAPIClient URL Construction")
  struct DockerAPIClientURLTests {

    // MARK: - parseImageRef

    @Test("parseImageRef splits simple image:tag")
    func parseSimpleRef() {
      let (image, tag) = DockerAPIClient.parseImageRef("nginx:latest")
      #expect(image == "nginx")
      #expect(tag == "latest")
    }

    @Test("parseImageRef defaults to 'latest' when no tag")
    func parseNoTag() {
      let (image, tag) = DockerAPIClient.parseImageRef("ubuntu")
      #expect(image == "ubuntu")
      #expect(tag == "latest")
    }

    @Test("parseImageRef handles registry with port and tag")
    func parseRegistryPortAndTag() {
      let (image, tag) = DockerAPIClient.parseImageRef("myhost:5000/myimage:v2")
      #expect(image == "myhost:5000/myimage")
      #expect(tag == "v2")
    }

    @Test("parseImageRef handles registry with port but no tag")
    func parseRegistryPortNoTag() {
      let (image, tag) = DockerAPIClient.parseImageRef("myhost:5000/myimage")
      #expect(image == "myhost:5000/myimage")
      #expect(tag == "latest")
    }

    @Test("parseImageRef handles fully qualified ghcr.io ref")
    func parseGHCR() {
      let (image, tag) = DockerAPIClient.parseImageRef("ghcr.io/user/repo:sha-abc123")
      #expect(image == "ghcr.io/user/repo")
      #expect(tag == "sha-abc123")
    }

    @Test("parseImageRef handles numeric tag like ubuntu:22.04")
    func parseNumericTag() {
      let (image, tag) = DockerAPIClient.parseImageRef("ubuntu:22.04")
      #expect(image == "ubuntu")
      #expect(tag == "22.04")
    }

    @Test("parseImageRef handles sha256 digest reference with @")
    func parseDigestRef() {
      // Docker digest refs use '@' separator, but parseImageRef is designed
      // for ':' tag syntax. With @sha256:..., the last ':' splits it.
      // This is expected — digest refs should be used as-is, not parsed for tags.
      let ref = "ubuntu@sha256:abcdef1234567890"
      let (image, tag) = DockerAPIClient.parseImageRef(ref)
      #expect(image == "ubuntu@sha256")
      #expect(tag == "abcdef1234567890")
    }

    @Test("parseImageRef handles empty string")
    func parseEmptyRef() {
      let (image, tag) = DockerAPIClient.parseImageRef("")
      #expect(image == "")
      #expect(tag == "latest")
    }

    // MARK: - pathEncodeComponent

    @Test("pathEncodeComponent encodes slashes in image refs")
    func pathEncodeSlashes() {
      let encoded = DockerAPIClient.pathEncodeComponent("library/nginx")
      #expect(encoded == "library%2Fnginx")
    }

    @Test("pathEncodeComponent encodes special characters")
    func pathEncodeSpecial() {
      let encoded = DockerAPIClient.pathEncodeComponent("image name:tag")
      #expect(encoded.contains("%20") || encoded.contains("+"))
      #expect(!encoded.contains(" "))
    }

    @Test("pathEncodeComponent preserves safe characters")
    func pathEncodeSafe() {
      let encoded = DockerAPIClient.pathEncodeComponent("alpine")
      #expect(encoded == "alpine")
    }

    @Test("pathEncodeComponent handles colons in digest refs")
    func pathEncodeDigest() {
      // Colons are allowed in URL path segments per RFC 3986, so they are NOT encoded
      let encoded = DockerAPIClient.pathEncodeComponent("sha256:abc123")
      #expect(encoded == "sha256:abc123")
    }

    // MARK: - buildURL with Unix socket

    @Test("buildURL produces correct path for Unix socket endpoint")
    func buildURLUnixSocket() async throws {
      let client = DockerAPIClient(endpoint: "/var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/_ping")
      #expect(url.hasPrefix("http+unix://"))
      #expect(url.contains("%2Fvar%2Frun%2Fdocker.sock"))
      #expect(url.hasSuffix("/v1.44/_ping"))
    }

    @Test("buildURL includes query items properly encoded")
    func buildURLWithQuery() async throws {
      let client = DockerAPIClient(endpoint: "/var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(
        path: "/images/create",
        queryItems: [
          URLQueryItem(name: "fromImage", value: "ghcr.io/user/repo"),
          URLQueryItem(name: "tag", value: "v1.0"),
        ])
      #expect(url.contains("/v1.44/images/create?"))
      #expect(url.contains("fromImage=ghcr.io/user/repo") || url.contains("fromImage=ghcr.io%2Fuser%2Frepo"))
      #expect(url.contains("tag=v1.0"))
    }

    @Test("buildURL with platform JSON query encodes braces")
    func buildURLWithPlatformJSON() async throws {
      let client = DockerAPIClient(endpoint: "/var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let platformJSON = #"{"os":"linux","architecture":"arm64"}"#
      let url = client.buildURL(
        path: "/images/create",
        queryItems: [
          URLQueryItem(name: "fromImage", value: "alpine"),
          URLQueryItem(name: "tag", value: "latest"),
          URLQueryItem(name: "platform", value: platformJSON),
        ])
      // URLQueryItem should encode the JSON properly
      #expect(url.contains("platform="))
      // The raw braces and colons should be percent-encoded in query
      #expect(!url.contains("platform={"))
    }

    @Test("buildURL with no query items omits question mark")
    func buildURLNoQuery() async throws {
      let client = DockerAPIClient(endpoint: "/var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/containers/abc123/start")
      #expect(!url.contains("?"))
      #expect(url.hasSuffix("/v1.44/containers/abc123/start"))
    }

    // MARK: - buildURL with TCP endpoint

    @Test("buildURL produces correct URL for TCP endpoint")
    func buildURLTCP() async throws {
      let client = DockerAPIClient(endpoint: "http://localhost:2375")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/_ping")
      #expect(url == "http://localhost:2375/v1.44/_ping")
    }

    @Test("buildURL for TCP endpoint without scheme adds http")
    func buildURLTCPNoScheme() async throws {
      let client = DockerAPIClient(endpoint: "localhost:2375")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/_ping")
      #expect(url.hasPrefix("http://"))
      #expect(url.hasSuffix("/v1.44/_ping"))
    }

    @Test("buildURL strips trailing slash from TCP endpoint")
    func buildURLTCPTrailingSlash() async throws {
      let client = DockerAPIClient(endpoint: "http://myhost:2375/")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/_ping")
      #expect(url == "http://myhost:2375/v1.44/_ping")
    }

    // MARK: - Unix socket with unix:// prefix

    @Test("buildURL handles unix:// prefix in endpoint")
    func buildURLUnixPrefix() async throws {
      let client = DockerAPIClient(endpoint: "unix:///var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/_ping")
      #expect(url.hasPrefix("http+unix://"))
      #expect(url.contains("%2Fvar%2Frun%2Fdocker.sock"))
      #expect(url.hasSuffix("/v1.44/_ping"))
    }
  }

  // MARK: - DockerRuntime Integration Tests

  private func isDockerAvailable() -> Bool {
    FileManager.default.fileExists(atPath: "/var/run/docker.sock")
      || ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"] != nil
  }

  @Suite("DockerRuntime Integration", .enabled(if: isDockerAvailable()))
  struct DockerRuntimeIntegrationTests {

    private func makeRuntime() -> DockerRuntime {
      let endpoint = ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"]
      let config = ContainerRuntimeConfiguration(
        storagePath: "/tmp/claudec-test-docker", endpoint: endpoint)
      return DockerRuntime(config: config)
    }

    private func makeClient() -> DockerAPIClient {
      let endpoint =
        ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"]
        ?? "/var/run/docker.sock"
      return DockerAPIClient(endpoint: endpoint)
    }

    @Test("buildURL produces correct URLs for Docker API")
    func verifyURLConstruction() async throws {
      let client = makeClient()
      defer { Task { try? await client.shutdown() } }

      let pingURL = client.buildURL(path: "/_ping")
      print("DIAG ping URL: \(pingURL)")
      #expect(pingURL.hasSuffix("/v1.44/_ping"))

      let inspectURL = client.buildURL(path: "/images/alpine:latest/json")
      print("DIAG inspect URL: \(inspectURL)")
      #expect(inspectURL.contains("/v1.44/images/"))

      let pullURL = client.buildURL(
        path: "/images/create",
        queryItems: [
          URLQueryItem(name: "fromImage", value: "alpine"),
          URLQueryItem(name: "tag", value: "latest"),
        ])
      print("DIAG pull URL: \(pullURL)")
      #expect(pullURL.contains("fromImage=alpine"))
    }

    @Test("prepare succeeds when Docker is available")
    func prepareSucceeds() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
    }

    @Test("inspectImage returns nil for non-existent image")
    func inspectNonExistent() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      let image = try await runtime.inspectImage(
        ref: "this-image-definitely-does-not-exist-\(UUID().uuidString):latest")
      #expect(image == nil)
    }

    @Test("pullImage and inspectImage work for a small image")
    func pullAndInspect() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      let image = try await runtime.pullImage(ref: "alpine:latest")
      #expect(image != nil)
      #expect(image?.ref == "alpine:latest")
      #expect(image?.digest.isEmpty == false)

      let inspected = try await runtime.inspectImage(ref: "alpine:latest")
      #expect(inspected != nil)
      #expect(inspected?.digest == image?.digest)
    }

    @Test("removeImage removes a pulled image")
    func removeImage() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      let image = try await runtime.pullImage(ref: "alpine:3.18")
      try #require(image != nil, "Failed to pull alpine:3.18")

      try await runtime.removeImage(ref: "alpine:3.18")
    }

    @Test("runContainer executes a command and returns exit code")
    func runContainer() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      _ = try await runtime.pullImage(ref: "alpine:latest")

      let containerConfig = ContainerConfiguration(
        entrypoint: ["echo", "hello-from-docker"],
        io: .standardIO
      )

      let container = try await runtime.runContainer(
        imageRef: "alpine:latest",
        configuration: containerConfig
      )

      let exitCode = try await container.wait(timeoutInSeconds: 30)
      #expect(exitCode == 0)

      try await runtime.removeContainer(container)
    }
  }
#endif
