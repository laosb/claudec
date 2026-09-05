#if canImport(FoundationEssentials) && canImport(Musl)
  import FoundationEssentials
  import Musl

  /// The privileged half of the bootstrap: everything that has to happen before
  /// the process drops to the agent user.
  ///
  /// Split into three separable pieces — account creation, small directory
  /// initialization, and profile ownership — because only the last of them is
  /// expensive, and only the last of them has to negotiate with the host.
  /// ``ProfileOwnership`` handles that separately.
  enum RootSetup {
    /// Create the agent account and the directories the container needs.
    ///
    /// Deliberately does *not* touch the profile home: ownership is settled
    /// afterwards, once the host has said what it expects.
    static func perform() throws {
      try Diagnostics.span("bootstrap.agent_user") { try createAgentUser() }
      Diagnostics.span("bootstrap.sudo") { configureSudo() }
      Diagnostics.span("bootstrap.directories") { createDirectories() }
    }

    private static func createAgentUser() throws {
      // Skip if agent user already exists.
      guard getpwnam("agent") == nil else { return }

      let shell = access("/bin/bash", X_OK) == 0 ? "/bin/bash" : "/bin/sh"

      if Helpers.commandExists("useradd") {
        // Debian/Ubuntu: -d sets home without creating it (no -m).
        try Helpers.run(
          command: "useradd",
          arguments: ["-d", "/home/agent", "-s", shell, "agent"],
          output: .stderr)
      } else if Helpers.commandExists("adduser") {
        // Alpine/BusyBox: -H prevents creating the home directory.
        try Helpers.run(
          command: "adduser",
          arguments: [
            "-D", "-h", "/home/agent", "-s", shell, "-H", "agent",
          ],
          output: .stderr)
      } else {
        throw BootstrapError.setupFailed(
          "No useradd or adduser command found")
      }
    }

    private static func configureSudo() {
      Helpers.mkdirp("/etc/sudoers.d")
      let url = URL(fileURLWithPath: "/etc/sudoers.d/agent")
      try? Data("agent ALL=(ALL) NOPASSWD:ALL\n".utf8).write(to: url)
      chmod("/etc/sudoers.d/agent", 0o440)
    }

    /// Create the small, fixed set of container-owned directories.
    ///
    /// These are container paths, not profile contents, so they are cheap and
    /// unconditional. `/home/agent` is left to ``ProfileOwnership``.
    private static func createDirectories() {
      Helpers.mkdirp("/workspace")
      Helpers.mkdirp("/agent-isolation")

      guard let identity = ProfileOwnership.resolveAgentIdentity() else { return }
      chown("/workspace", identity.uid, identity.gid)
      chown("/agent-isolation", identity.uid, identity.gid)
    }
  }
#endif
