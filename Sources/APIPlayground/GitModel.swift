import APIEngine
import Foundation

/// One changed file, with what it holds worked out for display.
struct GitChangeRow: Identifiable {
    var change: GitChange
    var info: WorkspaceFileInfo
    var id: String { change.path }
}

/// What the app knows about the workspace's repository, as of the last look.
struct GitState {
    var repo: GitRepository
    var status: GitStatus
    var rows: [GitChangeRow]
    var branches: [GitBranch]
    var log: [GitCommit]
    var remoteURL: String?
    var identity: GitIdentity
}

struct GitBanner: Equatable {
    var text: String
    var isError = false
}

/// A merge that is waiting for choices, and the choices made so far.
struct MergeSession {
    var conflicts: [FileConflict]
    /// Choices for single values, by file and then by conflict.
    var fieldChoices: [String: [String: MergeSide]] = [:]
    /// Choices for whole files.
    var fileChoices: [String: MergeSide] = [:]

    func isSettled(_ conflict: FileConflict) -> Bool {
        conflict.isSettled(fields: fieldChoices[conflict.id] ?? [:], file: fileChoices[conflict.id])
    }

    var allSettled: Bool { conflicts.allSatisfy(isSettled) }
    var settledCount: Int { conflicts.filter(isSettled).count }

    /// Picks one side for everything that has no choice yet.
    mutating func chooseRemaining(_ side: MergeSide) {
        for conflict in conflicts {
            if conflict.wholeFileReason != nil {
                if fileChoices[conflict.id] == nil { fileChoices[conflict.id] = side }
            } else {
                for field in conflict.fields where fieldChoices[conflict.id]?[field.id] == nil {
                    fieldChoices[conflict.id, default: [:]][field.id] = side
                }
            }
        }
    }
}

extension AppModel {
    // MARK: Looking

    nonisolated static func gitSnapshot(_ repo: GitRepository) throws -> GitState {
        let status = try repo.status()
        let rows = status.changes.map { change in
            // A deleted file's name has to come from the last commit.
            let working = try? Data(contentsOf: repo.root.appendingPathComponent(change.path))
            let committed = working == nil ? repo.committedFile(change.path) : nil
            return GitChangeRow(change: change, info: WorkspaceFileInfo(path: change.path, versions: [working, committed]))
        }
        return GitState(
            repo: repo, status: status, rows: rows,
            branches: (try? repo.branches()) ?? [], log: (try? repo.log()) ?? [],
            remoteURL: repo.remoteURL(), identity: repo.identity()
        )
    }

    /// Looks at the workspace's repository again, shortly after the last request to.
    func refreshGit() {
        gitRefreshTask?.cancel()
        guard vaultURL != nil else {
            git = nil
            return
        }
        gitRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.loadGit()
        }
    }

    func loadGit() async {
        guard let vault = vaultURL else {
            git = nil
            return
        }
        let state = await Task.detached { () -> GitState? in
            guard let runner = try? GitRunner.standard(), let repo = GitRepository.open(vault, runner: runner) else { return nil }
            return try? AppModel.gitSnapshot(repo)
        }.value
        guard vaultURL == vault else { return }
        git = state
    }

    /// True when the workspace is a folder that could be put in Git but is not yet.
    var canStartTracking: Bool { vaultURL != nil && git == nil }

    /// Masks the workspace's secret values in text shown on the Git screens.
    func gitDisplay(_ text: String) -> String {
        guard secretsHidden else { return text }
        let variables = globals + environments.flatMap(\.variables) + collections.flatMap(\.variables)
        return Redactor(variables: variables, auths: collections.map(\.auth)).redact(text)
    }

    // MARK: Running Git

    private func report(_ text: String, isError: Bool = false) {
        if showingGit || showingClone {
            gitBanner = GitBanner(text: text, isError: isError)
        } else if isError {
            notice = Notice(title: "Git Sync", message: text)
        }
    }

    /// Runs Git work away from the main thread, one piece at a time.
    /// - Returns: The work's result, or nil when it failed or Git was already busy.
    private func gitRun<T: Sendable>(_ label: String, _ work: @escaping @Sendable (GitRepository) throws -> T) async -> T? {
        guard let repo = git?.repo, gitBusy == nil else { return nil }
        flushPendingSaves()
        gitBusy = label
        gitBanner = nil
        defer { gitBusy = nil }
        do {
            return try await Task.detached { try work(repo) }.value
        } catch {
            report(error.localizedDescription, isError: true)
            return nil
        }
    }

    // MARK: Starting

    func startTracking() async {
        guard let vault = vaultURL, git == nil else { return }
        flushPendingSaves()
        do {
            _ = try await Task.detached { try GitRepository.initialise(vault, runner: .standard()) }.value
            await loadGit()
            showingGit = true
        } catch {
            notice = Notice(title: "Could not start tracking with Git", message: error.localizedDescription)
        }
    }

    /// Copies a remote repository into `folder` and opens it as the workspace.
    func clone(_ remote: String, into folder: URL) async {
        guard gitBusy == nil else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else {
            gitBanner = GitBanner(text: "“\(folder.lastPathComponent)” already exists there and is not empty. Choose another name.", isError: true)
            return
        }
        gitBusy = "Cloning…"
        gitBanner = nil
        defer { gitBusy = nil }
        do {
            _ = try await Task.detached { try GitRepository.clone(remote, to: folder, runner: .standard()) }.value
            showingClone = false
            openVault(folder)
            await loadGit()
        } catch {
            gitBanner = GitBanner(text: error.localizedDescription, isError: true)
        }
    }

    // MARK: Everyday work

    func commit(_ message: String) async -> Bool {
        guard mock == nil else {
            report("Stop the mock server before committing. While it runs it keeps a temporary environment in the workspace.", isError: true)
            return false
        }
        let done: Void? = await gitRun("Committing…") { try $0.commitAll(message: message) }
        await loadGit()
        if done != nil { report("Committed.") }
        return done != nil
    }

    func push() async {
        let done: Void? = await gitRun("Pushing…") { try $0.push() }
        await loadGit()
        if done != nil { report("Pushed to the remote.") }
    }

    /// Asks the remote what it has, without changing anything here.
    func fetch() async {
        let done: Void? = await gitRun("Checking the remote…") { try $0.fetch() }
        await loadGit()
        if done != nil, let status = git?.status {
            report(status.behind == 0 ? "Nothing new on the remote." : "The remote has \(status.behind) new \(status.behind == 1 ? "commit" : "commits"). Pull to get them.")
        }
    }

    func pull() async {
        guard let outcome = await gitRun("Pulling…", { try $0.pull() }) else {
            await loadGit()
            return
        }
        await finish(outcome, upToDate: "Already up to date.", done: "Pulled the latest changes.")
    }

    func merge(branch: String) async {
        guard let outcome = await gitRun("Merging…", { try $0.merge(branch) }) else {
            await loadGit()
            return
        }
        await finish(outcome, upToDate: "“\(branch)” has nothing new.", done: "Merged “\(branch)”.")
    }

    private func finish(_ outcome: MergeOutcome, upToDate: String, done: String) async {
        switch outcome {
        case .upToDate:
            await loadGit()
            report(upToDate)
        case .fastForwarded, .merged:
            reload()
            await loadGit()
            report(done)
        case .conflicts:
            await continueMerge()
        }
    }

    /// Settles what can be settled without help, then either finishes the merge or asks.
    func continueMerge() async {
        guard let remaining = await gitRun("Merging…", { try $0.mergeConflicts() }) else {
            await loadGit()
            return
        }
        if remaining.isEmpty {
            let done: Void? = await gitRun("Merging…") { try $0.finishMerge() }
            reload()
            await loadGit()
            if done != nil { report("Merged. Both sides' changes fitted together.") }
        } else {
            await loadGit()
            mergeSession = MergeSession(conflicts: remaining)
            showingGit = true
        }
    }

    func completeMerge() async {
        guard let session = mergeSession, session.allSettled else { return }
        let done: Void? = await gitRun("Finishing the merge…") { repo in
            for conflict in session.conflicts {
                try repo.resolve(conflict, fields: session.fieldChoices[conflict.id] ?? [:], file: session.fileChoices[conflict.id])
            }
            try repo.finishMerge()
        }
        if done != nil {
            mergeSession = nil
            reload()
        }
        await loadGit()
        if done != nil { report("Merged.") }
    }

    func abandonMerge() async {
        let done: Void? = await gitRun("Putting things back…") { try $0.abortMerge() }
        if done != nil {
            mergeSession = nil
            reload()
        }
        await loadGit()
        if done != nil { report("The merge was abandoned. Nothing changed.") }
    }

    func discard(_ change: GitChange) async {
        let done: Void? = await gitRun("Discarding…") { try $0.discard(change) }
        if done != nil { reload() }
        await loadGit()
    }

    func switchBranch(_ name: String) async {
        let done: Void? = await gitRun("Switching…") { try $0.switchBranch(name) }
        if done != nil { reload() }
        await loadGit()
        if done != nil { report("Now on “\(name)”.") }
    }

    func createBranch(_ name: String) async -> Bool {
        let done: Void? = await gitRun("Creating the branch…") { try $0.createBranch(name) }
        await loadGit()
        if done != nil { report("Created “\(name)” and switched to it.") }
        return done != nil
    }

    func setRemote(_ url: String) async {
        let done: Void? = await gitRun("Saving…") { try $0.setRemoteURL(url) }
        await loadGit()
        if done != nil { report("Saved the remote address.") }
    }

    func setIdentity(_ identity: GitIdentity) async {
        let done: Void? = await gitRun("Saving…") { try $0.setIdentity(identity) }
        await loadGit()
        if done != nil { report("Saved your name and email for this workspace.") }
    }

    /// The committed and current text of a changed file, for showing what changed.
    func diff(for change: GitChange) async -> [DiffLine] {
        guard let repo = git?.repo else { return [] }
        let (old, new) = await Task.detached { () -> (String, String) in
            let committed = repo.committedFile(change.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let working = (try? String(contentsOf: repo.root.appendingPathComponent(change.path), encoding: .utf8)) ?? ""
            return (committed, working)
        }.value
        return LineDiff.diff(old: gitDisplay(old), new: gitDisplay(new))
    }
}
