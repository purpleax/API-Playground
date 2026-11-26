import APIEngine
import AppKit
import SwiftUI

// MARK: - Top bar

/// The branch and what is waiting to be committed, pushed or pulled. Opens Git Sync.
struct GitChip: View {
    @Environment(AppModel.self) private var model
    let state: GitState

    var body: some View {
        Button {
            model.showingGit = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(state.status.branch ?? "No branch")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if state.status.isMerging {
                    Text("merging").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.warning)
                }
                if !state.rows.isEmpty {
                    Text("\(state.rows.count)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.warning.opacity(0.16), in: Capsule())
                }
                if state.status.ahead > 0 {
                    Text("↑\(state.status.ahead)").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(Theme.info)
                }
                if state.status.behind > 0 {
                    Text("↓\(state.status.behind)").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(Theme.violet)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var help: String {
        var parts = ["On branch \(state.status.branch ?? "none")"]
        if !state.rows.isEmpty { parts.append("\(state.rows.count) uncommitted \(state.rows.count == 1 ? "change" : "changes")") }
        if state.status.ahead > 0 { parts.append("\(state.status.ahead) to push") }
        if state.status.behind > 0 { parts.append("\(state.status.behind) to pull") }
        return parts.joined(separator: ", ") + ". Click to open Git Sync."
    }
}

// MARK: - Git Sync

struct GitView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .changes

    enum Tab: Hashable { case changes, history, branches, settings }

    var body: some View {
        Group {
            if model.mergeSession != nil {
                MergeView()
            } else if let state = model.git {
                content(state)
            } else {
                VStack(spacing: 14) {
                    Text("This workspace is not in Git").font(.system(size: 17, weight: .bold))
                    Text("Open a Local Vault and choose Git > Start Tracking, or clone a repository.")
                        .foregroundStyle(Theme.textSecondary)
                    Button("Done") { model.showingGit = false }.buttonStyle(PrimaryButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: 620)
        .task { await model.loadGit() }
    }

    @ViewBuilder
    private func content(_ state: GitState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(state)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            if state.status.isMerging {
                BannerRow(text: "A merge was started and not finished.", color: Theme.warning) {
                    Button("Continue") { Task { await model.continueMerge() } }
                    Button("Abandon", role: .destructive) { Task { await model.abandonMerge() } }
                }
            } else if let banner = model.gitBanner {
                BannerRow(text: banner.text, color: banner.isError ? Theme.danger : Theme.success) {
                    IconButton(systemImage: "xmark", help: "Dismiss") { model.gitBanner = nil }
                }
            }
            ThemedTabBar(tabs: [
                TabItem(id: Tab.changes, title: "Changes", badge: state.rows.isEmpty ? nil : "\(state.rows.count)", badgeColor: Theme.warning),
                TabItem(id: Tab.history, title: "History"),
                TabItem(id: Tab.branches, title: "Branches", badge: "\(state.branches.count)"),
                TabItem(id: Tab.settings, title: "Remote & Identity", badge: state.remoteURL == nil || !state.identity.isComplete ? "!" : nil, badgeColor: Theme.danger),
            ], selection: $tab)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            Rectangle().fill(Theme.stroke).frame(height: 1)

            Group {
                switch tab {
                case .changes: ChangesTab(state: state) { tab = .settings }
                case .history: HistoryTab(state: state)
                case .branches: BranchesTab(state: state)
                case .settings: GitSettingsTab(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack {
                Text(state.repo.root.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Done") { model.showingGit = false }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .disabled(model.gitBusy != nil)
    }

    private func header(_ state: GitState) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Git Sync").font(.system(size: 17, weight: .bold))
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(state.status.branch ?? "No branch").font(.system(size: 12.5, weight: .semibold))
                    if let upstream = state.status.upstream {
                        Text("tracks \(upstream)").foregroundStyle(Theme.textSecondary)
                    } else if state.remoteURL != nil {
                        Text("not pushed yet").foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("no remote").foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.system(size: 12))
            }
            Spacer()
            if let busy = model.gitBusy {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(Theme.textSecondary)
            }
            IconButton(systemImage: "arrow.clockwise", help: "Check the remote for new commits") {
                Task { await model.fetch() }
            }
            .disabled(state.remoteURL == nil)
            Button {
                Task { await model.pull() }
            } label: {
                Label(state.status.behind > 0 ? "Pull \(state.status.behind)" : "Pull", systemImage: "arrow.down")
            }
            .disabled(state.remoteURL == nil || state.status.isMerging)
            .help("Get the remote's commits for this branch and merge them in")
            Button {
                Task { await model.push() }
            } label: {
                Label(state.status.ahead > 0 ? "Push \(state.status.ahead)" : "Push", systemImage: "arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.remoteURL == nil || !state.status.hasCommits || state.status.isMerging)
            .help("Send this branch's commits to the remote")
        }
        .padding(14)
    }
}

private struct BannerRow<Actions: View>: View {
    let text: String
    let color: Color
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 5)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.12))
    }
}

private struct KindBadge: View {
    let kind: GitChange.Kind

    private var letter: String {
        switch kind {
        case .added: return "NEW"
        case .modified: return "EDIT"
        case .deleted: return "DEL"
        case .renamed: return "MOVE"
        case .conflicted: return "BOTH"
        }
    }

    private var color: Color {
        switch kind {
        case .added: return Theme.success
        case .modified: return Theme.info
        case .deleted: return Theme.danger
        case .renamed: return Theme.violet
        case .conflicted: return Theme.warning
        }
    }

    var body: some View {
        Text(letter)
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 38, height: 17)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct FileLabel: View {
    let info: WorkspaceFileInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(info.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Text(info.location.isEmpty ? info.kind.rawValue : "\(info.kind.rawValue) in \(info.location)")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }
}

// MARK: Changes

private struct ChangesTab: View {
    @Environment(AppModel.self) private var model
    let state: GitState
    let showSettings: () -> Void
    @State private var selected: String?
    @State private var lines: [DiffLine] = []
    @State private var message = ""
    @State private var confirmingDiscard = false

    private var current: GitChangeRow? {
        state.rows.first { $0.id == selected } ?? state.rows.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.rows.isEmpty {
                EmptyState(
                    systemImage: "checkmark.seal.fill", title: "Nothing to commit",
                    detail: "Every change in this workspace is committed. Edits you make show up here."
                )
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(state.rows) { row in
                                SelectableRow(isSelected: row.id == current?.id) {
                                    selected = row.id
                                } content: {
                                    KindBadge(kind: row.change.kind)
                                    FileLabel(info: row.info)
                                }
                                .frame(minHeight: 38)
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 300)
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                    detail
                }
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            commitBar
        }
        .task(id: "\(current?.id ?? "")|\(state.rows.count)|\(state.log.first?.id ?? "")") {
            if let current {
                lines = await model.diff(for: current.change)
            } else {
                lines = []
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let current {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    FileLabel(info: current.info)
                    Spacer()
                    Text(current.change.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Discard", role: .destructive) { confirmingDiscard = true }
                        .help("Throw this change away and go back to the committed version")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                DiffView(lines: lines)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .confirmationDialog("Discard the change to “\(current.info.title)”?", isPresented: $confirmingDiscard) {
                Button("Discard", role: .destructive) { Task { await model.discard(current.change) } }
            } message: {
                Text("It goes back to how it was at the last commit. This cannot be undone.")
            }
        }
    }

    @ViewBuilder
    private var commitBar: some View {
        if !state.identity.isComplete {
            HStack {
                Text("Git needs your name and email before the first commit.").foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Fill Them In", action: showSettings).buttonStyle(PrimaryButtonStyle())
            }
            .padding(12)
        } else {
            HStack(spacing: 10) {
                TextField("Say what changed, for example “Add the orders requests”", text: $message)
                    .textFieldStyle(ThemedTextFieldStyle())
                    .onSubmit(commit)
                Button(state.rows.isEmpty ? "Commit" : state.rows.count == 1 ? "Commit 1 Change" : "Commit \(state.rows.count) Changes", action: commit)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(state.rows.isEmpty || message.trimmingCharacters(in: .whitespaces).isEmpty || state.status.isMerging)
            }
            .padding(12)
        }
    }

    private func commit() {
        let text = message
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !state.rows.isEmpty else { return }
        Task {
            if await model.commit(text) { message = "" }
        }
    }
}

// MARK: History

private struct HistoryTab: View {
    let state: GitState

    var body: some View {
        if state.log.isEmpty {
            EmptyState(systemImage: "clock", title: "No commits yet", detail: "Commit your changes to start this workspace's history.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.log.enumerated()), id: \.element.id) { index, commit in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(index < state.status.ahead ? Theme.info : Theme.accent)
                                .frame(width: 8, height: 8)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.subject).font(.system(size: 12.5, weight: .medium))
                                Text("\(commit.author) · \(commit.date.formatted(.relative(presentation: .named)))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if index < state.status.ahead {
                                Chip(text: "not pushed", color: Theme.info, mono: false)
                            }
                            Text(commit.shortID)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        Rectangle().fill(Theme.stroke.opacity(0.6)).frame(height: 1)
                    }
                }
            }
        }
    }
}

// MARK: Branches

private struct BranchesTab: View {
    @Environment(AppModel.self) private var model
    let state: GitState
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.branches) { branch in
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(branch.isCurrent ? Theme.accent : Theme.textTertiary)
                            Text(branch.name).font(.system(size: 12.5, weight: branch.isCurrent ? .bold : .medium))
                            if branch.isCurrent { Chip(text: "current", color: Theme.accent, mono: false) }
                            if branch.isRemoteOnly { Chip(text: "on the remote", color: Theme.violet, mono: false) }
                            Spacer()
                            if !branch.isCurrent {
                                if !branch.isRemoteOnly, let current = state.status.branch {
                                    Button("Merge into \(current)") { Task { await model.merge(branch: branch.name) } }
                                        .help("Bring this branch's commits into \(current)")
                                }
                                Button("Switch") { Task { await model.switchBranch(branch.name) } }
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        Rectangle().fill(Theme.stroke.opacity(0.6)).frame(height: 1)
                    }
                }
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 10) {
                TextField("New branch name, for example try-new-auth", text: $newName)
                    .textFieldStyle(ThemedTextFieldStyle())
                    .onSubmit(create)
                Button("Create Branch", action: create)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || !state.status.hasCommits)
            }
            .padding(12)
        }
        .disabled(state.status.isMerging)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            if await model.createBranch(name) { newName = "" }
        }
    }
}

// MARK: Remote and identity

private struct GitSettingsTab: View {
    @Environment(AppModel.self) private var model
    let state: GitState
    @State private var remote = ""
    @State private var name = ""
    @State private var email = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Remote repository").sectionTitle()
                    Text("Where Push sends commits and Pull gets them from, such as a repository on GitHub. An https:// address uses the sign-in Git keeps in the Keychain, or asks for one. A git@ address uses your SSH keys.")
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        TextField("git@github.com:team/apis.git", text: $remote)
                            .textFieldStyle(ThemedTextFieldStyle())
                            .font(.system(size: 12.5, design: .monospaced))
                        Button("Save") { Task { await model.setRemote(remote) } }
                            .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty || remote == state.remoteURL)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your name on commits").sectionTitle()
                    Text("Saved for this workspace only.")
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 10) {
                        TextField("Name", text: $name).textFieldStyle(ThemedTextFieldStyle())
                        TextField("Email", text: $email).textFieldStyle(ThemedTextFieldStyle())
                        Button("Save") {
                            Task { await model.setIdentity(GitIdentity(name: name.trimmingCharacters(in: .whitespaces), email: email.trimmingCharacters(in: .whitespaces))) }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || email.trimmingCharacters(in: .whitespaces).isEmpty
                            || (name == state.identity.name && email == state.identity.email))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("What is shared").sectionTitle()
                    Text("Collections, requests, environments and their starting values are committed. Secret values stay in this Mac's Keychain, and current values, cookies, history and OAuth tokens stay in the app's private data. None of those are committed.")
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            remote = state.remoteURL ?? ""
            name = state.identity.name
            email = state.identity.email
        }
    }
}

// MARK: - Merge

/// Settles a merge: for everything both sides changed, choose whose version to keep.
struct MergeView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var confirmingAbandon = false

    var body: some View {
        if let session = model.mergeSession {
            let current = session.conflicts.first { $0.id == selected } ?? session.conflicts.first
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settle the merge").font(.system(size: 17, weight: .bold))
                    Text("You and the other side changed the same things. Everything else has already been combined. For each one below, choose which version to keep.")
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                if let banner = model.gitBanner, banner.isError {
                    BannerRow(text: banner.text, color: Theme.danger) {
                        IconButton(systemImage: "xmark", help: "Dismiss") { model.gitBanner = nil }
                    }
                }

                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(session.conflicts) { conflict in
                                SelectableRow(isSelected: conflict.id == current?.id) {
                                    selected = conflict.id
                                } content: {
                                    Image(systemName: session.isSettled(conflict) ? "checkmark.circle.fill" : "circle.dashed")
                                        .foregroundStyle(session.isSettled(conflict) ? Theme.success : Theme.warning)
                                    FileLabel(info: conflict.info)
                                }
                                .frame(minHeight: 38)
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 280)
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                    if let current {
                        ScrollView {
                            ConflictDetail(conflict: current)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(current.id)
                    }
                }
                .frame(maxHeight: .infinity)

                Rectangle().fill(Theme.stroke).frame(height: 1)
                HStack(spacing: 10) {
                    Button("Abandon Merge", role: .destructive) { confirmingAbandon = true }
                    Spacer()
                    if let busy = model.gitBusy {
                        ProgressView().controlSize(.small)
                        Text(busy).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("\(session.settledCount) of \(session.conflicts.count) settled").foregroundStyle(Theme.textSecondary)
                    }
                    Button("Mine for the Rest") { model.mergeSession?.chooseRemaining(.ours) }
                        .disabled(session.allSettled)
                    Button("Theirs for the Rest") { model.mergeSession?.chooseRemaining(.theirs) }
                        .disabled(session.allSettled)
                    Button("Finish Merge") { Task { await model.completeMerge() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!session.allSettled)
                }
                .padding(12)
            }
            .disabled(model.gitBusy != nil)
            .confirmationDialog("Abandon this merge?", isPresented: $confirmingAbandon) {
                Button("Abandon Merge", role: .destructive) { Task { await model.abandonMerge() } }
            } message: {
                Text("Your workspace goes back to how it was before the merge. The other side's commits can be merged again later.")
            }
        }
    }
}

private struct ConflictDetail: View {
    @Environment(AppModel.self) private var model
    let conflict: FileConflict

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                FileLabel(info: conflict.info)
                Spacer()
                Text(conflict.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let reason = conflict.wholeFileReason {
                Text(reason).foregroundStyle(Theme.textSecondary)
                HStack(alignment: .top, spacing: 10) {
                    ChoiceCard(
                        title: "Mine", value: summary(conflict.ours), isChosen: model.mergeSession?.fileChoices[conflict.id] == .ours
                    ) { model.mergeSession?.fileChoices[conflict.id] = .ours }
                    ChoiceCard(
                        title: "Theirs", value: summary(conflict.theirs), isChosen: model.mergeSession?.fileChoices[conflict.id] == .theirs
                    ) { model.mergeSession?.fileChoices[conflict.id] = .theirs }
                }
            } else {
                ForEach(conflict.fields) { field in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(field.label).font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        if let base = field.base {
                            Text("Before: \(model.gitDisplay(base))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(3)
                        } else {
                            Text("Added on both sides").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        }
                        HStack(alignment: .top, spacing: 10) {
                            ChoiceCard(
                                title: "Mine", value: field.ours.map(model.gitDisplay),
                                isChosen: model.mergeSession?.fieldChoices[conflict.id]?[field.id] == .ours
                            ) { model.mergeSession?.fieldChoices[conflict.id, default: [:]][field.id] = .ours }
                            ChoiceCard(
                                title: "Theirs", value: field.theirs.map(model.gitDisplay),
                                isChosen: model.mergeSession?.fieldChoices[conflict.id]?[field.id] == .theirs
                            ) { model.mergeSession?.fieldChoices[conflict.id, default: [:]][field.id] = .theirs }
                        }
                    }
                }
            }
        }
    }

    /// A whole file, shortened to its opening lines.
    private func summary(_ data: Data?) -> String? {
        guard let data else { return nil }
        let text = model.gitDisplay(String(decoding: data, as: UTF8.self))
        let lines = text.split(whereSeparator: \.isNewline)
        return lines.prefix(14).joined(separator: "\n") + (lines.count > 14 ? "\n…" : "")
    }
}

/// One side of a conflict, as a card to click.
private struct ChoiceCard: View {
    let title: String
    /// The value on this side. Nil means this side removed it.
    let value: String?
    let isChosen: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isChosen ? Theme.accent : Theme.textTertiary)
                    Text(title).font(.system(size: 11.5, weight: .bold)).foregroundStyle(isChosen ? Theme.accent : Theme.textSecondary)
                    Spacer()
                }
                if let value {
                    Text(value.isEmpty ? "(empty)" : value)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(value.isEmpty ? Theme.textTertiary : Theme.text)
                        .lineLimit(14)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Removed").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.danger)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(isChosen ? Theme.accent.opacity(0.10) : (hovering ? Theme.raised : Theme.canvas), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius)
                    .strokeBorder(isChosen ? Theme.accent : Theme.stroke, lineWidth: isChosen ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title): \(value ?? "removed")")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

// MARK: - Clone

/// Asks for the user name and token an HTTPS remote wants.
struct GitSignInView: View {
    @Environment(AppModel.self) private var model
    let request: GitSignIn
    @State private var user = ""
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign In to \(request.host)").font(.system(size: 17, weight: .bold))
                Text("Enter your user name and a personal access token. Most Git hosts no longer take the account password here. The sign-in is kept in the Keychain, where Git in Terminal can use it too.")
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("User name").sectionTitle()
                TextField("User name", text: $user).textFieldStyle(ThemedTextFieldStyle())
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Token").sectionTitle()
                SecureField("Personal access token", text: $token).textFieldStyle(ThemedTextFieldStyle())
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { model.gitSignIn = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Sign In") {
                    Task { await model.signIn(request, user: user.trimmingCharacters(in: .whitespaces), token: token.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(user.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

extension View {
    /// Shows the sign-in sheet over a Git screen when a remote asks for one.
    func gitSignInSheet(_ model: AppModel) -> some View {
        sheet(item: Binding(get: { model.gitSignIn }, set: { model.gitSignIn = $0 })) { request in
            GitSignInView(request: request)
                .environment(model)
                .themedSheet()
        }
    }
}

struct CloneView: View {
    @Environment(AppModel.self) private var model
    @State private var remote = ""
    @State private var parent = CloneView.startingParent()
    @State private var name = ""
    @State private var nameEdited = false

    private var folderName: String {
        nameEdited ? name.trimmingCharacters(in: .whitespaces) : Self.suggestedName(for: remote)
    }

    private static let parentKey = "cloneParentPath"

    /// The folder the last clone went into if it is still there, otherwise Documents.
    static func startingParent() -> URL {
        var isDirectory: ObjCBool = false
        if let path = UserDefaults.standard.string(forKey: parentKey),
           FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The last part of a repository address, without ".git": the name Git itself would use.
    static func suggestedName(for remote: String) -> String {
        var last = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        while last.hasSuffix("/") { last.removeLast() }
        if let cut = last.lastIndex(where: { $0 == "/" || $0 == ":" }) { last = String(last[last.index(after: cut)...]) }
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clone a Repository").font(.system(size: 17, weight: .bold))
                Text("Copies a shared workspace from Git onto this Mac and opens it. Commit, push and pull then keep it in step with everyone else's.")
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            if let banner = model.gitBanner {
                BannerRow(text: banner.text, color: banner.isError ? Theme.danger : Theme.success) { EmptyView() }
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Repository address").sectionTitle()
                    TextField("git@github.com:team/apis.git or https://…", text: $remote)
                        .textFieldStyle(ThemedTextFieldStyle())
                        .font(.system(size: 12.5, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keep it in").sectionTitle()
                    HStack(spacing: 10) {
                        Text(parent.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Choose…", action: chooseParent)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Folder name").sectionTitle()
                    TextField("Folder name", text: Binding(
                        get: { nameEdited ? name : Self.suggestedName(for: remote) },
                        set: { name = $0; nameEdited = true }
                    ))
                    .textFieldStyle(ThemedTextFieldStyle())
                }
            }
            .padding(14)
            Spacer(minLength: 0)

            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 10) {
                if let busy = model.gitBusy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Cancel") { model.showingClone = false }
                    .keyboardShortcut(.cancelAction)
                Button("Clone") {
                    let target = parent.appendingPathComponent(folderName, isDirectory: true)
                    Task { await model.clone(remote.trimmingCharacters(in: .whitespacesAndNewlines), into: target) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty || folderName.isEmpty || folderName.contains("/"))
            }
            .padding(12)
        }
        .frame(width: 560, height: 400)
        .disabled(model.gitBusy != nil)
        .onAppear { model.gitBanner = nil }
        .gitSignInSheet(model)
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = parent
        panel.prompt = "Choose"
        panel.message = "Choose the folder to put the cloned workspace in."
        if panel.runModal() == .OK, let url = panel.url {
            parent = url
            UserDefaults.standard.set(url.path, forKey: Self.parentKey)
        }
    }
}
