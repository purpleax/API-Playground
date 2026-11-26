import Clibgit2
import Foundation
import Security

public struct GitError: LocalizedError, Equatable, Sendable {
    public var message: String
    /// Set when the remote asked for a sign-in the app could not give: the server's name.
    public var signInHost: String?

    public init(_ message: String, signInHost: String? = nil) {
        self.message = message
        self.signInHost = signInHost
    }

    public var errorDescription: String? { message }

    /// Turns Git's most common failures into plain advice. Anything else is passed through.
    static func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("non-fast") || lower.contains("fastforwardable") || lower.contains("fetch first")
            || lower.contains("commits that are not present locally") {
            return "The remote has changes you do not have yet. Pull first, then push again."
        }
        if lower.contains("authentication") || lower.contains("permission denied (publickey") || lower.contains("status code: 401")
            || lower.contains("status code: 403") {
            return "The remote refused the sign-in. Check the user name and the token or key it expects.\n\n\(message)"
        }
        if lower.contains("prevents checkout") || lower.contains("prevent checkout") || lower.contains("would be overwritten by") {
            return "You have changes that this would overwrite. Commit or discard them first."
        }
        if message.isEmpty { return "Git failed without saying why." }
        return message
    }
}

/// Sign-ins for remotes reached over HTTPS, kept in the Keychain.
///
/// They are stored the way Git's own Keychain helper stores them, so a sign-in saved by
/// Git in Terminal is found here, and one saved here is found by Git.
public enum GitCredentials {
    public struct SignIn: Equatable, Sendable {
        public var user: String
        public var password: String
    }

    private static func query(host: String) -> [CFString: Any] {
        [kSecClass: kSecClassInternetPassword, kSecAttrServer: host, kSecAttrProtocol: kSecAttrProtocolHTTPS]
    }

    public static func find(host: String, user: String? = nil) -> SignIn? {
        var query = query(host: host)
        if let user, !user.isEmpty { query[kSecAttrAccount] = user }
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnAttributes] = true
        query[kSecReturnData] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let found = item as? [CFString: Any],
              let account = found[kSecAttrAccount] as? String, let data = found[kSecValueData] as? Data else { return nil }
        // Git may keep an expiry date and a refresh token on further lines.
        let password = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !password.isEmpty else { return nil }
        return SignIn(user: account, password: password)
    }

    public static func save(host: String, user: String, password: String) throws {
        var item = query(host: host)
        item[kSecAttrAccount] = user
        SecItemDelete(item as CFDictionary)
        item[kSecValueData] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GitError("The sign-in could not be saved in the Keychain (error \(status)).")
        }
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

// MARK: - libgit2

/// Starts the built-in Git library, once.
private let gitLibrary: Void = {
    // A remote that hangs up mid-transfer must fail the transfer, not end the app.
    signal(SIGPIPE, SIG_IGN)
    git_libgit2_init()
    // SSH remotes go through the Mac's own ssh. Never let it stop to ask a question nobody can see.
    setenv("GIT_SSH_COMMAND", "ssh -o BatchMode=yes", 0)
}()

private func lastGitMessage() -> String {
    guard let error = git_error_last(), let message = error.pointee.message else { return "" }
    return String(cString: message)
}

@discardableResult
private func check(_ code: Int32) throws -> Int32 {
    if code < 0 { throw GitError(GitError.friendly(lastGitMessage())) }
    return code
}

/// Passes a list of strings to a call that takes libgit2's string array.
private func withStrings<T>(_ strings: [String], _ body: (inout git_strarray) throws -> T) rethrows -> T {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        var array = git_strarray(strings: buffer.baseAddress, count: strings.count)
        return try body(&array)
    }
}

/// What a conversation with a remote needs to remember while it runs.
private final class RemoteContext {
    var attempts = 0
    var signInHost: String?
    var rejection: String?

    var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    static func from(_ payload: UnsafeMutableRawPointer?) -> RemoteContext? {
        payload.map { Unmanaged<RemoteContext>.fromOpaque($0).takeUnretainedValue() }
    }

    /// The error to report for a failed call: a request to sign in, when that is what stopped it.
    func error() -> GitError {
        if let host = signInHost {
            return GitError("\(host) needs a sign-in: your user name, and a personal access token in place of a password.", signInHost: host)
        }
        return GitError(GitError.friendly(lastGitMessage()))
    }

    func callbacks() -> git_remote_callbacks {
        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        callbacks.payload = pointer
        callbacks.credentials = { out, url, userFromURL, allowed, payload in
            guard let context = RemoteContext.from(payload) else { return GIT_PASSTHROUGH.rawValue }
            let user = userFromURL.map { String(cString: $0) }
            if allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 {
                let host = url.flatMap { URLComponents(string: String(cString: $0))?.host } ?? ""
                context.attempts += 1
                // A saved sign-in gets one try. If the remote turns it down, ask for a new one.
                if context.attempts == 1, let found = GitCredentials.find(host: host, user: user) {
                    return git_credential_userpass_plaintext_new(out, found.user, found.password)
                }
                context.signInHost = host
                return GIT_EAUTH.rawValue
            }
            if allowed & GIT_CREDENTIAL_USERNAME.rawValue != 0 {
                return git_credential_username_new(out, user ?? "git")
            }
            return GIT_PASSTHROUGH.rawValue
        }
        callbacks.push_update_reference = { _, status, payload in
            if let status { RemoteContext.from(payload)?.rejection = String(cString: status) }
            return 0
        }
        return callbacks
    }
}

/// A folder that is a Git repository. The work is done by libgit2, built into the app,
/// so nothing needs to be installed on the Mac.
public struct GitRepository: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private func withRepo<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        _ = gitLibrary
        var repo: OpaquePointer?
        try check(git_repository_open_ext(&repo, root.path, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil))
        defer { git_repository_free(repo) }
        return try body(repo!)
    }

    // MARK: Creating and finding

    /// Returns the repository whose top folder is exactly `folder`, or nil.
    /// A folder inside a larger repository does not count: syncing it would touch files outside it.
    public static func open(_ folder: URL) -> GitRepository? {
        let candidate = GitRepository(root: folder)
        let isWorkspace = try? candidate.withRepo { git_repository_is_bare($0) == 0 }
        return isWorkspace == true ? candidate : nil
    }

    private static func create(_ folder: URL, bare: Bool) throws {
        _ = gitLibrary
        var options = git_repository_init_options()
        git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        options.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue | (bare ? GIT_REPOSITORY_INIT_BARE.rawValue : 0)
        var repo: OpaquePointer?
        try "main".withCString { main in
            options.initial_head = main
            try check(git_repository_init_ext(&repo, folder.path, &options))
        }
        git_repository_free(repo)
    }

    /// Makes `folder` a repository with a first branch called `main`.
    public static func initialise(_ folder: URL) throws -> GitRepository {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try create(folder, bare: false)
        let ignore = folder.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try Data(".DS_Store\n.tmp-*/\n".utf8).write(to: ignore)
        }
        return GitRepository(root: folder)
    }

    /// Makes a repository with no working files, the kind a remote is.
    static func initialiseBare(_ folder: URL) throws {
        try create(folder, bare: true)
    }

    /// Copies a remote repository into `folder`, which must not exist yet or be empty.
    public static func clone(_ remote: String, to folder: URL) throws -> GitRepository {
        _ = gitLibrary
        let address = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw GitError("Enter the address of the remote repository.") }
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = RemoteContext()
        var options = git_clone_options()
        git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION))
        options.fetch_opts.callbacks = context.callbacks()
        var repo: OpaquePointer?
        guard git_clone(&repo, address, folder.path, &options) == 0 else { throw context.error() }
        git_repository_free(repo)
        return GitRepository(root: folder)
    }

    // MARK: Status

    public func status() throws -> GitStatus {
        try withRepo { repo in
            var status = GitStatus()

            var head: OpaquePointer?
            let found = git_repository_head(&head, repo)
            defer { git_reference_free(head) }
            if found == 0, let head {
                if git_reference_is_branch(head) == 1 {
                    status.branch = String(cString: git_reference_shorthand(head))
                    var upstream: OpaquePointer?
                    if git_branch_upstream(&upstream, head) == 0, let upstream {
                        defer { git_reference_free(upstream) }
                        status.upstream = String(cString: git_reference_shorthand(upstream))
                        var ahead = 0, behind = 0
                        if let mine = git_reference_target(head), let theirs = git_reference_target(upstream),
                           git_graph_ahead_behind(&ahead, &behind, repo, mine, theirs) == 0 {
                            status.ahead = ahead
                            status.behind = behind
                        }
                    }
                }
            } else {
                // No commit yet: HEAD names the branch the first commit will start.
                status.hasCommits = false
                var symbolic: OpaquePointer?
                if git_reference_lookup(&symbolic, repo, "HEAD") == 0, let symbolic {
                    defer { git_reference_free(symbolic) }
                    if let target = git_reference_symbolic_target(symbolic) {
                        let name = String(cString: target)
                        status.branch = name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
                    }
                }
            }

            var options = git_status_options()
            git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
            options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
            options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
                | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
            var list: OpaquePointer?
            try check(git_status_list_new(&list, repo, &options))
            defer { git_status_list_free(list) }
            var seen = Set<String>()
            for index in 0..<git_status_list_entrycount(list) {
                guard let entry = git_status_byindex(list, index)?.pointee else { continue }
                let flags = entry.status.rawValue
                func has(_ flag: git_status_t) -> Bool { flags & flag.rawValue != 0 }
                guard flags != 0, !has(GIT_STATUS_IGNORED) else { continue }
                let delta = entry.index_to_workdir ?? entry.head_to_index
                guard let raw = delta?.pointee.new_file.path ?? delta?.pointee.old_file.path else { continue }
                let path = String(cString: raw)
                let kind: GitChange.Kind
                if has(GIT_STATUS_CONFLICTED) {
                    kind = .conflicted
                } else if has(GIT_STATUS_INDEX_DELETED) || has(GIT_STATUS_WT_DELETED) {
                    kind = .deleted
                } else if has(GIT_STATUS_WT_NEW) || has(GIT_STATUS_INDEX_NEW) {
                    kind = .added
                } else if has(GIT_STATUS_INDEX_RENAMED) {
                    kind = .renamed
                } else {
                    kind = .modified
                }
                if seen.insert(path).inserted { status.changes.append(GitChange(path: path, kind: kind)) }
            }
            status.changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            status.isMerging = git_repository_state(repo) == GIT_REPOSITORY_STATE_MERGE.rawValue
            return status
        }
    }

    public var isMerging: Bool {
        (try? withRepo { git_repository_state($0) == GIT_REPOSITORY_STATE_MERGE.rawValue }) ?? false
    }

    /// The latest commit on the current branch, or nil before the first one. The caller frees it.
    private func headCommit(_ repo: OpaquePointer) -> OpaquePointer? {
        var oid = git_oid()
        guard git_reference_name_to_id(&oid, repo, "HEAD") == 0 else { return nil }
        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, &oid) == 0 else { return nil }
        return commit
    }

    private func content(_ repo: OpaquePointer, blob id: git_oid) -> Data? {
        var id = id
        var blob: OpaquePointer?
        guard git_blob_lookup(&blob, repo, &id) == 0, let blob else { return nil }
        defer { git_blob_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        guard size > 0, let bytes = git_blob_rawcontent(blob) else { return Data() }
        return Data(bytes: bytes, count: size)
    }

    /// The content of a file as of the last commit, or nil if it was not in it.
    public func committedFile(_ path: String) -> Data? {
        (try? withRepo { repo -> Data? in
            guard let commit = headCommit(repo) else { return nil }
            defer { git_commit_free(commit) }
            var tree: OpaquePointer?
            guard git_commit_tree(&tree, commit) == 0 else { return nil }
            defer { git_tree_free(tree) }
            var entry: OpaquePointer?
            guard git_tree_entry_bypath(&entry, tree, path) == 0, let entry else { return nil }
            defer { git_tree_entry_free(entry) }
            guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB, let id = git_tree_entry_id(entry) else { return nil }
            return content(repo, blob: id.pointee)
        }) ?? nil
    }

    // MARK: Identity

    public func identity() -> GitIdentity {
        (try? withRepo { repo -> GitIdentity in
            var config: OpaquePointer?
            guard git_repository_config_snapshot(&config, repo) == 0 else { return GitIdentity(name: "", email: "") }
            defer { git_config_free(config) }
            func value(_ key: String) -> String {
                var text: UnsafePointer<CChar>?
                guard git_config_get_string(&text, config, key) == 0, let text else { return "" }
                return String(cString: text)
            }
            return GitIdentity(name: value("user.name"), email: value("user.email"))
        }) ?? GitIdentity(name: "", email: "")
    }

    /// Sets the name and email for commits in this repository only.
    public func setIdentity(_ identity: GitIdentity) throws {
        try withRepo { repo in
            var config: OpaquePointer?
            try check(git_repository_config(&config, repo))
            defer { git_config_free(config) }
            try check(git_config_set_string(config, "user.name", identity.name))
            try check(git_config_set_string(config, "user.email", identity.email))
        }
    }

    // MARK: Commits

    /// The commits a merge in progress is bringing in.
    private func mergeHeads(_ repo: OpaquePointer) -> [git_oid] {
        guard let folder = git_repository_path(repo),
              let text = try? String(contentsOfFile: String(cString: folder) + "MERGE_HEAD", encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            var oid = git_oid()
            return git_oid_fromstr(&oid, String(line)) == 0 ? oid : nil
        }
    }

    /// The message Git prepared for a merge, without the lines meant only for its editor.
    private func mergeMessage(_ repo: OpaquePointer) -> String? {
        var buffer = git_buf()
        guard git_repository_message(&buffer, repo) == 0, let text = buffer.ptr else { return nil }
        defer { git_buf_dispose(&buffer) }
        let lines = String(cString: text).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
        let message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    /// Commits what the index holds. A merge in progress is completed by it.
    private func commitIndex(_ repo: OpaquePointer, message: String, requireChange: Bool) throws {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        var treeID = git_oid()
        try check(git_index_write_tree(&treeID, index))
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repo, &treeID))
        defer { git_tree_free(tree) }

        var parents: [OpaquePointer?] = []
        defer { parents.forEach { git_commit_free($0) } }
        if let head = headCommit(repo) { parents.append(head) }
        let merging = mergeHeads(repo)
        for var oid in merging {
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, repo, &oid))
            parents.append(commit)
        }
        if requireChange, merging.isEmpty, let head = parents.first, let headTree = git_commit_tree_id(head),
           git_oid_equal(headTree, &treeID) != 0 {
            throw GitError("There is nothing to commit: no file has changed.")
        }

        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, repo) == 0 else {
            throw GitError("Git does not know your name and email yet. Fill them in, then commit again.")
        }
        defer { git_signature_free(signature) }
        var id = git_oid()
        try check(git_commit_create(&id, repo, "HEAD", signature, signature, nil, message, tree, parents.count, &parents))
        if !merging.isEmpty {
            git_repository_state_cleanup(repo)
            git_index_name_clear(index)
            git_index_write(index)
        }
    }

    /// Commits every change in the folder.
    public func commitAll(message: String) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError("Write a short message saying what changed.") }
        try withRepo { repo in
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            // New and changed files, then files that are gone.
            try check(git_index_add_all(index, nil, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil))
            try check(git_index_update_all(index, nil, nil, nil))
            try check(git_index_write(index))
            try commitIndex(repo, message: trimmed, requireChange: true)
        }
    }

    public func log(limit: Int = 100) throws -> [GitCommit] {
        try withRepo { repo in
            guard let head = headCommit(repo) else { return [] }
            git_commit_free(head)
            var walk: OpaquePointer?
            try check(git_revwalk_new(&walk, repo))
            defer { git_revwalk_free(walk) }
            git_revwalk_sorting(walk, GIT_SORT_TIME.rawValue)
            try check(git_revwalk_push_head(walk))
            var commits: [GitCommit] = []
            var oid = git_oid()
            while commits.count < limit, git_revwalk_next(&oid, walk) == 0 {
                var commit: OpaquePointer?
                guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { continue }
                defer { git_commit_free(commit) }
                var hex = [CChar](repeating: 0, count: 41)
                git_oid_tostr(&hex, hex.count, &oid)
                let author = git_commit_author(commit)?.pointee
                commits.append(GitCommit(
                    id: hex.withUnsafeBufferPointer { String(cString: $0.baseAddress!) },
                    author: author?.name.map { String(cString: $0) } ?? "",
                    date: Date(timeIntervalSince1970: TimeInterval(author?.when.time ?? 0)),
                    subject: git_commit_summary(commit).map { String(cString: $0) } ?? ""
                ))
            }
            return commits
        }
    }

    /// Throws away the uncommitted change to one file.
    public func discard(_ change: GitChange) throws {
        let wasCommitted = committedFile(change.path) != nil
        try withRepo { repo in
            if wasCommitted, let head = headCommit(repo) {
                defer { git_commit_free(head) }
                try withStrings([change.path]) { paths in
                    try check(git_reset_default(repo, head, &paths))
                    var options = git_checkout_options()
                    git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
                    options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
                    options.paths = paths
                    try check(git_checkout_head(repo, &options))
                }
            } else {
                var index: OpaquePointer?
                try check(git_repository_index(&index, repo))
                defer { git_index_free(index) }
                git_index_remove_bypath(index, change.path)
                try check(git_index_write(index))
                try? FileManager.default.removeItem(at: root.appendingPathComponent(change.path))
            }
        }
    }

    // MARK: Branches

    private func branchNames(_ repo: OpaquePointer, _ type: git_branch_t) throws -> [(name: String, isCurrent: Bool)] {
        var iterator: OpaquePointer?
        try check(git_branch_iterator_new(&iterator, repo, type))
        defer { git_branch_iterator_free(iterator) }
        var names: [(String, Bool)] = []
        var reference: OpaquePointer?
        var found = GIT_BRANCH_LOCAL
        while git_branch_next(&reference, &found, iterator) == 0 {
            defer { git_reference_free(reference) }
            var name: UnsafePointer<CChar>?
            if git_branch_name(&name, reference) == 0, let name {
                names.append((String(cString: name), git_branch_is_head(reference) == 1))
            }
        }
        return names.sorted { $0.0 < $1.0 }
    }

    public func branches() throws -> [GitBranch] {
        try withRepo { repo in
            var result = try branchNames(repo, GIT_BRANCH_LOCAL).map { GitBranch(name: $0.name, isCurrent: $0.isCurrent, isRemoteOnly: false) }
            let local = Set(result.map(\.name))
            for remote in try branchNames(repo, GIT_BRANCH_REMOTE) where remote.name.hasPrefix("origin/") {
                let name = String(remote.name.dropFirst("origin/".count))
                if name != "HEAD", !local.contains(name) {
                    result.append(GitBranch(name: name, isCurrent: false, isRemoteOnly: true))
                }
            }
            return result
        }
    }

    private func checkBranchName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var valid: Int32 = 0
        git_branch_name_is_valid(&valid, trimmed)
        guard valid == 1, !trimmed.hasPrefix("-"), !trimmed.contains(" ") else {
            throw GitError("“\(name)” cannot be used as a branch name. Use letters, digits, hyphens and slashes.")
        }
        return trimmed
    }

    /// Makes a branch from the current commit and switches to it. Uncommitted changes come along.
    public func createBranch(_ name: String) throws {
        let name = try checkBranchName(name)
        try withRepo { repo in
            if let head = headCommit(repo) {
                defer { git_commit_free(head) }
                var branch: OpaquePointer?
                guard git_branch_create(&branch, repo, name, head, 0) == 0 else {
                    throw GitError("There is already a branch called “\(name)”.")
                }
                git_reference_free(branch)
            }
            try check(git_repository_set_head(repo, "refs/heads/\(name)"))
        }
    }

    private func safeCheckout() -> git_checkout_options {
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        return options
    }

    /// Switches to a branch. A branch that exists only on the remote gets a local one first.
    public func switchBranch(_ name: String) throws {
        let name = try checkBranchName(name)
        try withRepo { repo in
            var branch: OpaquePointer?
            if git_branch_lookup(&branch, repo, name, GIT_BRANCH_LOCAL) != 0 {
                var remote: OpaquePointer?
                guard git_branch_lookup(&remote, repo, "origin/\(name)", GIT_BRANCH_REMOTE) == 0 else {
                    throw GitError("There is no branch called “\(name)”.")
                }
                defer { git_reference_free(remote) }
                var commit: OpaquePointer?
                try check(git_reference_peel(&commit, remote, GIT_OBJECT_COMMIT))
                defer { git_object_free(commit) }
                try check(git_branch_create(&branch, repo, name, commit, 0))
                git_branch_set_upstream(branch, "origin/\(name)")
            }
            defer { git_reference_free(branch) }
            var target: OpaquePointer?
            try check(git_reference_peel(&target, branch, GIT_OBJECT_COMMIT))
            defer { git_object_free(target) }
            var options = safeCheckout()
            try check(git_checkout_tree(repo, target, &options))
            try check(git_repository_set_head(repo, "refs/heads/\(name)"))
        }
    }

    // MARK: Remote

    public func remoteURL() -> String? {
        (try? withRepo { repo -> String? in
            var remote: OpaquePointer?
            guard git_remote_lookup(&remote, repo, "origin") == 0 else { return nil }
            defer { git_remote_free(remote) }
            guard let url = git_remote_url(remote) else { return nil }
            let text = String(cString: url)
            return text.isEmpty ? nil : text
        }) ?? nil
    }

    public func setRemoteURL(_ url: String) throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { throw GitError("Enter the address of the remote repository.") }
        let exists = remoteURL() != nil
        try withRepo { repo in
            if exists {
                try check(git_remote_set_url(repo, "origin", trimmed))
            } else {
                var remote: OpaquePointer?
                try check(git_remote_create(&remote, repo, "origin", trimmed))
                git_remote_free(remote)
            }
        }
    }

    private func withRemote<T>(_ body: (OpaquePointer, OpaquePointer, RemoteContext) throws -> T) throws -> T {
        try withRepo { repo in
            var remote: OpaquePointer?
            guard git_remote_lookup(&remote, repo, "origin") == 0, let remote else {
                throw GitError("This workspace has no remote repository yet.")
            }
            defer { git_remote_free(remote) }
            return try body(repo, remote, RemoteContext())
        }
    }

    public func fetch() throws {
        try withRemote { _, remote, context in
            var options = git_fetch_options()
            git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
            options.prune = GIT_FETCH_PRUNE
            options.callbacks = context.callbacks()
            guard git_remote_fetch(remote, nil, &options, nil) == 0 else { throw context.error() }
        }
    }

    /// Sends this branch's commits to the remote, creating the branch there if needed.
    public func push() throws {
        try withRemote { repo, remote, context in
            var head: OpaquePointer?
            guard git_repository_head(&head, repo) == 0, let head, git_reference_is_branch(head) == 1 else {
                throw GitError("There is nothing to push yet. Commit something first.")
            }
            defer { git_reference_free(head) }
            let branch = String(cString: git_reference_shorthand(head))
            var options = git_push_options()
            git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
            options.callbacks = context.callbacks()
            let pushed = withStrings(["refs/heads/\(branch):refs/heads/\(branch)"]) { git_remote_push(remote, &$0, &options) }
            guard pushed == 0 else { throw context.error() }
            if let rejection = context.rejection { throw GitError(GitError.friendly(rejection)) }
            git_branch_set_upstream(head, "origin/\(branch)")
        }
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
        return try withRepo { repo in
            // Naming the branch, where there is one, gives the merge commit a readable message.
            var theirs: OpaquePointer?
            var reference: OpaquePointer?
            if git_reference_dwim(&reference, repo, branch) == 0 {
                defer { git_reference_free(reference) }
                try check(git_annotated_commit_from_ref(&theirs, repo, reference))
            } else {
                guard git_annotated_commit_from_revspec(&theirs, repo, branch) == 0 else {
                    throw GitError("“\(branch)” is not a branch.")
                }
            }
            defer { git_annotated_commit_free(theirs) }
            var heads: [OpaquePointer?] = [theirs]

            var analysis = GIT_MERGE_ANALYSIS_NONE
            var preference = GIT_MERGE_PREFERENCE_NONE
            try check(git_merge_analysis(&analysis, &preference, repo, &heads, 1))
            if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 { return .upToDate }

            if analysis.rawValue & (GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue | GIT_MERGE_ANALYSIS_UNBORN.rawValue) != 0 {
                guard let id = git_annotated_commit_id(theirs) else { throw GitError("“\(branch)” is not a branch.") }
                var target: OpaquePointer?
                try check(git_object_lookup(&target, repo, id, GIT_OBJECT_COMMIT))
                defer { git_object_free(target) }
                var options = safeCheckout()
                try check(git_checkout_tree(repo, target, &options))
                // Move the branch itself, so HEAD keeps pointing at it.
                var symbolic: OpaquePointer?
                try check(git_reference_lookup(&symbolic, repo, "HEAD"))
                defer { git_reference_free(symbolic) }
                var moved: OpaquePointer?
                if let name = git_reference_symbolic_target(symbolic) {
                    try check(git_reference_create(&moved, repo, name, id, 1, "merge \(branch): Fast-forward"))
                } else {
                    try check(git_repository_set_head_detached(repo, id))
                }
                git_reference_free(moved)
                return .fastForwarded
            }

            var mergeOptions = git_merge_options()
            git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION))
            var checkout = safeCheckout()
            try check(git_merge(repo, &heads, 1, &mergeOptions, &checkout))
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            if git_index_has_conflicts(index) == 1 { return .conflicts }
            try commitIndex(repo, message: mergeMessage(repo) ?? "Merge \(branch)", requireChange: false)
            return .merged
        }
    }

    /// The renames a merge in progress found: a file one side renamed while the other changed it
    /// is listed in the index under both names, and this is what ties the two together.
    private func mergeRenames(_ index: OpaquePointer?) -> [(base: String?, ours: String?, theirs: String?)] {
        (0..<git_index_name_entrycount(index)).compactMap { position in
            guard let entry = git_index_name_get_byindex(index, position)?.pointee else { return nil }
            return (entry.ancestor.map { String(cString: $0) }, entry.ours.map { String(cString: $0) }, entry.theirs.map { String(cString: $0) })
        }
    }

    /// The files both sides changed, with the three versions of each.
    func rawConflicts() throws -> [(path: String, base: Data?, ours: Data?, theirs: Data?)] {
        try withRepo { repo in
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            var iterator: OpaquePointer?
            try check(git_index_conflict_iterator_new(&iterator, index))
            defer { git_index_conflict_iterator_free(iterator) }

            // Every version in conflict, by path and by side: 1 is the common start, 2 ours, 3 theirs.
            var versions: [String: [Int: Data]] = [:]
            var base: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            while git_index_conflict_next(&base, &ours, &theirs, iterator) == 0 {
                for (side, entry) in [(1, base), (2, ours), (3, theirs)] {
                    guard let entry = entry?.pointee, let path = entry.path else { continue }
                    versions[String(cString: path), default: [:]][side] = content(repo, blob: entry.id)
                }
            }

            var result: [(path: String, base: Data?, ours: Data?, theirs: Data?)] = []
            func take(_ path: String?, _ side: Int) -> Data? {
                guard let path else { return nil }
                return versions[path]?.removeValue(forKey: side)
            }
            for rename in mergeRenames(index) {
                guard let path = rename.ours ?? rename.theirs, versions[rename.ours ?? ""] != nil || versions[rename.theirs ?? ""] != nil else { continue }
                let found = (take(rename.base, 1), take(rename.ours, 2), take(rename.theirs, 3))
                result.append((path, found.0, found.1, found.2))
            }
            for (path, sides) in versions where !sides.isEmpty {
                result.append((path, sides[1], sides[2], sides[3]))
            }
            return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    /// Settles one file: writes `content` as its merged version, or removes the file when nil.
    func settle(_ path: String, content: Data?) throws {
        let url = root.appendingPathComponent(path)
        if let content {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        try withRepo { repo in
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            // A renamed file is in conflict under its other names too. They go, with their files.
            for rename in mergeRenames(index) where rename.ours == path || (rename.ours == nil && rename.theirs == path) {
                for other in Set([rename.base, rename.ours, rename.theirs].compactMap { $0 }) where other != path {
                    git_index_conflict_remove(index, other)
                    git_index_remove_bypath(index, other)
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(other))
                }
            }
            if content != nil {
                try check(git_index_add_bypath(index, path))
            } else {
                git_index_remove_bypath(index, path)
                git_index_conflict_remove(index, path)
            }
            try check(git_index_write(index))
        }
    }

    /// Completes a merge once every conflict is settled.
    public func finishMerge() throws {
        guard try !status().changes.contains(where: { $0.kind == .conflicted }) else {
            throw GitError("Some conflicts still need a choice.")
        }
        try withRepo { repo in
            guard !mergeHeads(repo).isEmpty else { throw GitError("No merge is in progress.") }
            try commitIndex(repo, message: mergeMessage(repo) ?? "Merge", requireChange: false)
        }
    }

    /// Gives up on a merge and puts everything back as it was before it started.
    public func abortMerge() throws {
        try withRepo { repo in
            guard !mergeHeads(repo).isEmpty, let head = headCommit(repo) else { throw GitError("No merge is in progress.") }
            defer { git_commit_free(head) }
            try check(git_reset(repo, head, GIT_RESET_HARD, nil))
            git_repository_state_cleanup(repo)
        }
    }
}
