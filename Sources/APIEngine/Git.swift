import Foundation

public struct GitError: LocalizedError, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct GitOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public var text: String {
        String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs the `git` command. Everything the app does with Git goes through here, so the
/// command can later be replaced by a built-in library without touching the rest.
public struct GitRunner: Sendable {
    public var executable: URL
    /// Extra environment variables, set on top of the app's own.
    public var environment: [String: String]

    public init(executable: URL, environment: [String: String] = [:]) {
        self.executable = executable
        self.environment = environment
    }

    /// Finds Git on this Mac, or returns nil when it is not installed.
    public static func locate() -> URL? {
        let fm = FileManager.default
        // /usr/bin/git is a placeholder that offers to install Apple's developer tools
        // unless they are already present, so only use it when they are.
        let toolDirectories = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        if fm.isExecutableFile(atPath: "/usr/bin/git"), toolDirectories.contains(where: fm.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: "/usr/bin/git")
        }
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static func standard() throws -> GitRunner {
        guard let executable = locate() else {
            throw GitError("Git is not installed on this Mac. Install Apple's Command Line Tools, then try again.")
        }
        return GitRunner(executable: executable)
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    /// Runs Git and waits for it to finish.
    /// - Parameter allowFailure: When false, a non-zero exit throws Git's own message.
    @discardableResult
    public func run(_ arguments: [String], in directory: URL, allowFailure: Bool = false) throws -> GitOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "core.quotepath=false"] + arguments
        process.currentDirectoryURL = directory

        var env = ProcessInfo.processInfo.environment
        // Never stop to ask a question nobody can see: fail with a message instead.
        env["GIT_TERMINAL_PROMPT"] = "0"
        if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        env["LC_ALL"] = "C"
        env.merge(environment) { _, new in new }
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw GitError("Could not run Git: \(error.localizedDescription)")
        }

        // Read both pipes at once, so a large output on one cannot block the other. The
        // second reader gets a thread of its own: borrowing one from a shared pool can
        // deadlock when every thread in that pool is waiting here.
        let errBox = Box()
        let done = DispatchSemaphore(value: 0)
        let reader = Thread {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        reader.start()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        process.waitUntilExit()

        let stderr = String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let output = GitOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        if output.status != 0 && !allowFailure {
            throw GitError(Self.friendly(stderr.isEmpty ? output.text : stderr))
        }
        return output
    }

    /// Turns Git's most common failures into plain advice. Anything else is passed through.
    static func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("non-fast-forward") || lower.contains("fetch first") {
            return "The remote has changes you do not have yet. Pull first, then push again."
        }
        if lower.contains("could not read username") || lower.contains("authentication failed")
            || lower.contains("permission denied (publickey") || lower.contains("terminal prompts disabled") {
            return "The remote refused the sign-in. Check that Git on this Mac can reach it, "
                + "for example by running a pull in Terminal once.\n\n\(message)"
        }
        if lower.contains("please tell me who you are") || lower.contains("unable to auto-detect email") {
            return "Git does not know your name and email yet. Fill them in, then commit again."
        }
        if lower.contains("would be overwritten by") {
            return "You have changes that this would overwrite. Commit or discard them first."
        }
        if message.isEmpty { return "Git failed without saying why." }
        return message
    }
}

public struct GitChange: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case added, modified, deleted, renamed, conflicted
    }

    public var path: String
    public var kind: Kind
    public var id: String { path }

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

public struct GitStatus: Equatable, Sendable {
    /// The branch that is checked out, or nil when no branch is.
    public var branch: String?
    /// The remote branch this one pushes to and pulls from.
    public var upstream: String?
    /// Commits here that the remote does not have, and the reverse.
    public var ahead = 0
    public var behind = 0
    public var changes: [GitChange] = []
    public var hasCommits = true
    /// True while a merge has been started and not finished.
    public var isMerging = false

    public init() {}
}

public struct GitCommit: Identifiable, Equatable, Sendable {
    public var id: String
    public var author: String
    public var date: Date
    public var subject: String

    public var shortID: String { String(id.prefix(7)) }
}

public struct GitBranch: Identifiable, Equatable, Sendable {
    public var name: String
    public var isCurrent: Bool
    /// True for a branch that so far exists only on the remote.
    public var isRemoteOnly: Bool
    public var id: String { (isRemoteOnly ? "remote/" : "local/") + name }
}

public struct GitIdentity: Equatable, Sendable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    public var isComplete: Bool { !name.isEmpty && !email.isEmpty }
}

public enum MergeOutcome: Equatable, Sendable {
    case upToDate
    /// The branch simply moved forward to the other side's commits.
    case fastForwarded
    /// Both sides had changes, and they were combined without help.
    case merged
    /// Both sides changed the same things. The merge waits for choices.
    case conflicts
}

/// A folder that is a Git repository.
public struct GitRepository: Sendable {
    public let root: URL
    public let runner: GitRunner

    public init(root: URL, runner: GitRunner) {
        self.root = root
        self.runner = runner
    }

    @discardableResult
    func git(_ arguments: String..., allowFailure: Bool = false) throws -> GitOutput {
        try runner.run(arguments, in: root, allowFailure: allowFailure)
    }

    // MARK: Creating and finding

    /// Returns the repository whose top folder is exactly `folder`, or nil.
    /// A folder inside a larger repository does not count: syncing it would touch files outside it.
    public static func open(_ folder: URL, runner: GitRunner) -> GitRepository? {
        guard let output = try? runner.run(["rev-parse", "--show-toplevel"], in: folder, allowFailure: true),
              output.status == 0 else { return nil }
        let top = URL(fileURLWithPath: output.text).resolvingSymlinksInPath().standardizedFileURL.path
        guard top == folder.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return GitRepository(root: folder, runner: runner)
    }

    /// Makes `folder` a repository with a first branch called `main`.
    public static func initialise(_ folder: URL, runner: GitRunner) throws -> GitRepository {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try runner.run(["init", "-b", "main"], in: folder)
        let ignore = folder.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try Data(".DS_Store\n.tmp-*/\n".utf8).write(to: ignore)
        }
        return GitRepository(root: folder, runner: runner)
    }

    /// Copies a remote repository into `folder`, which must not exist yet or be empty.
    public static func clone(_ remote: String, to folder: URL, runner: GitRunner) throws -> GitRepository {
        let parent = folder.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try runner.run(["clone", "--", remote, folder.path], in: parent)
        return GitRepository(root: folder, runner: runner)
    }

    // MARK: Status

    public func status() throws -> GitStatus {
        let output = try git("status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z")
        var status = GitStatus()
        var tokens = String(decoding: output.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true)[...]
        while let token = tokens.popFirst() {
            if token.hasPrefix("# branch.oid ") {
                status.hasCommits = !token.hasSuffix("(initial)")
            } else if token.hasPrefix("# branch.head ") {
                let name = String(token.dropFirst("# branch.head ".count))
                status.branch = name == "(detached)" ? nil : name
            } else if token.hasPrefix("# branch.upstream ") {
                status.upstream = String(token.dropFirst("# branch.upstream ".count))
            } else if token.hasPrefix("# branch.ab ") {
                let parts = token.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 {
                    status.ahead = Int(parts[0].dropFirst()) ?? 0
                    status.behind = Int(parts[1].dropFirst()) ?? 0
                }
            } else if token.hasPrefix("? ") {
                status.changes.append(GitChange(path: String(token.dropFirst(2)), kind: .added))
            } else if token.hasPrefix("1 ") || token.hasPrefix("2 ") || token.hasPrefix("u ") {
                // The path comes after a fixed number of fields, and may itself contain spaces.
                let fieldsBeforePath = token.hasPrefix("1 ") ? 8 : token.hasPrefix("2 ") ? 9 : 10
                let fields = token.split(separator: " ", maxSplits: fieldsBeforePath, omittingEmptySubsequences: false)
                guard fields.count == fieldsBeforePath + 1 else { continue }
                let path = String(fields[fieldsBeforePath])
                let codes = fields[1]
                let kind: GitChange.Kind
                if token.hasPrefix("u ") {
                    kind = .conflicted
                } else if codes.contains("D") {
                    kind = .deleted
                } else if codes.hasPrefix("A") {
                    kind = .added
                } else if token.hasPrefix("2 ") {
                    kind = .renamed
                    _ = tokens.popFirst() // the name it had before
                } else {
                    kind = .modified
                }
                if token.hasPrefix("2 "), kind != .renamed { _ = tokens.popFirst() }
                status.changes.append(GitChange(path: path, kind: kind))
            }
        }
        status.changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        status.isMerging = isMerging
        return status
    }

    public var isMerging: Bool {
        (try? git("rev-parse", "-q", "--verify", "MERGE_HEAD", allowFailure: true).status) == 0
    }

    private func head() -> String? {
        guard let output = try? git("rev-parse", "-q", "--verify", "HEAD", allowFailure: true), output.status == 0 else { return nil }
        return output.text
    }

    /// The content of a file as of the last commit, or nil if it was not in it.
    public func committedFile(_ path: String) -> Data? {
        file(path, at: "HEAD")
    }

    func file(_ path: String, at revision: String) -> Data? {
        guard let output = try? git("show", "\(revision):\(path)", allowFailure: true), output.status == 0 else { return nil }
        return output.stdout
    }

    // MARK: Identity

    public func identity() -> GitIdentity {
        let name = (try? git("config", "user.name", allowFailure: true).text) ?? ""
        let email = (try? git("config", "user.email", allowFailure: true).text) ?? ""
        return GitIdentity(name: name, email: email)
    }

    /// Sets the name and email for commits in this repository only.
    public func setIdentity(_ identity: GitIdentity) throws {
        try git("config", "user.name", identity.name)
        try git("config", "user.email", identity.email)
    }

    // MARK: Commits

    /// Commits every change in the folder.
    public func commitAll(message: String) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError("Write a short message saying what changed.") }
        try git("add", "-A", "--", ".")
        try git("commit", "-m", trimmed)
    }

    public func log(limit: Int = 100) throws -> [GitCommit] {
        guard head() != nil else { return [] }
        let output = try git("log", "-n", String(limit), "--format=%H%x1f%an%x1f%aI%x1f%s%x1e")
        let formatter = ISO8601DateFormatter()
        return output.text.split(separator: "\u{1E}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            return GitCommit(
                id: String(fields[0]), author: String(fields[1]),
                date: formatter.date(from: String(fields[2])) ?? Date(timeIntervalSince1970: 0),
                subject: String(fields[3])
            )
        }
    }

    /// Throws away the uncommitted change to one file.
    public func discard(_ change: GitChange) throws {
        if committedFile(change.path) != nil {
            try git("restore", "--source=HEAD", "--staged", "--worktree", "--", change.path)
        } else {
            try git("rm", "-q", "--cached", "--ignore-unmatch", "--", change.path)
            try? FileManager.default.removeItem(at: root.appendingPathComponent(change.path))
        }
    }

    // MARK: Branches

    public func branches() throws -> [GitBranch] {
        let local = try git("for-each-ref", "--format=%(refname:short)%1f%(HEAD)", "refs/heads").text
        var result: [GitBranch] = local.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard let name = fields.first else { return nil }
            return GitBranch(name: String(name), isCurrent: fields.count > 1 && fields[1] == "*", isRemoteOnly: false)
        }
        let localNames = Set(result.map(\.name))
        let remote = try git("for-each-ref", "--format=%(refname:lstrip=3)", "refs/remotes/origin").text
        for line in remote.split(whereSeparator: \.isNewline) {
            let name = String(line)
            if name != "HEAD", !localNames.contains(name) {
                result.append(GitBranch(name: name, isCurrent: false, isRemoteOnly: true))
            }
        }
        return result
    }

    private func checkBranchName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let valid = try git("check-ref-format", "--branch", trimmed, allowFailure: true).status == 0
        guard valid, !trimmed.hasPrefix("-") else {
            throw GitError("“\(name)” cannot be used as a branch name. Use letters, digits, hyphens and slashes.")
        }
        return trimmed
    }

    /// Makes a branch from the current commit and switches to it. Uncommitted changes come along.
    public func createBranch(_ name: String) throws {
        try git("switch", "-c", try checkBranchName(name))
    }

    /// Switches to a branch. A branch that exists only on the remote is fetched into a local one first.
    public func switchBranch(_ name: String) throws {
        try git("switch", try checkBranchName(name))
    }

    // MARK: Remote

    public func remoteURL() -> String? {
        guard let output = try? git("remote", "get-url", "origin", allowFailure: true), output.status == 0 else { return nil }
        return output.text.isEmpty ? nil : output.text
    }

    public func setRemoteURL(_ url: String) throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { throw GitError("Enter the address of the remote repository.") }
        if remoteURL() == nil {
            try git("remote", "add", "origin", trimmed)
        } else {
            try git("remote", "set-url", "origin", trimmed)
        }
    }

    public func fetch() throws {
        guard remoteURL() != nil else { throw GitError("This workspace has no remote repository yet.") }
        try git("fetch", "--prune", "origin")
    }

    /// Sends this branch's commits to the remote, creating the branch there if needed.
    public func push() throws {
        guard remoteURL() != nil else { throw GitError("This workspace has no remote repository yet.") }
        try git("push", "-u", "origin", "HEAD")
    }

    /// Fetches the remote's commits for this branch and merges them in.
    public func pull() throws -> MergeOutcome {
        guard try status().changes.isEmpty else {
            throw GitError("Commit or discard your changes before pulling.")
        }
        try fetch()
        guard let upstream = try status().upstream else {
            throw GitError("This branch has not been pushed yet, so there is nothing to pull.")
        }
        return try merge(upstream)
    }

    // MARK: Merging

    /// Merges another branch into the current one.
    public func merge(_ branch: String) throws -> MergeOutcome {
        guard !branch.hasPrefix("-") else { throw GitError("“\(branch)” is not a branch.") }
        guard try status().changes.isEmpty else {
            throw GitError("Commit or discard your changes before merging.")
        }
        let before = head()
        let output = try git("merge", "--no-edit", branch, allowFailure: true)
        if output.status == 0 {
            guard let after = head(), after != before else { return .upToDate }
            // A fast-forward lands exactly on the other side's latest commit.
            let theirs = try git("rev-parse", "\(branch)^{commit}").text
            return after == theirs ? .fastForwarded : .merged
        }
        if isMerging { return .conflicts }
        throw GitError(GitRunner.friendly(output.stderr.isEmpty ? output.text : output.stderr))
    }

    /// The files both sides changed, with the three versions of each.
    func rawConflicts() throws -> [(path: String, base: Data?, ours: Data?, theirs: Data?)] {
        try status().changes.filter { $0.kind == .conflicted }.map { change in
            (change.path, file(change.path, at: ":1"), file(change.path, at: ":2"), file(change.path, at: ":3"))
        }
    }

    /// Settles one file: writes `content` as its merged version, or removes the file when nil.
    func settle(_ path: String, content: Data?) throws {
        let url = root.appendingPathComponent(path)
        if let content {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, options: .atomic)
            try git("add", "--", path)
        } else {
            try? FileManager.default.removeItem(at: url)
            try git("rm", "-q", "--cached", "--ignore-unmatch", "--", path)
        }
    }

    /// Completes a merge once every conflict is settled.
    public func finishMerge() throws {
        guard try !status().changes.contains(where: { $0.kind == .conflicted }) else {
            throw GitError("Some conflicts still need a choice.")
        }
        try git("commit", "--no-edit")
    }

    /// Gives up on a merge and puts everything back as it was before it started.
    public func abortMerge() throws {
        try git("merge", "--abort")
    }
}
