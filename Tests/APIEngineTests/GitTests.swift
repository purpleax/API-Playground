import Foundation
import Testing
@testable import APIEngine

/// A temporary folder with a remote repository and any number of people working from it.
/// Git is cut off from this Mac's own settings, so the tests behave the same everywhere.
private struct Sandbox {
    let dir: URL
    let runner: GitRunner

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let executable = try #require(GitRunner.locate())
        runner = GitRunner(executable: executable, environment: [
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test Person", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test Person", "GIT_COMMITTER_EMAIL": "test@example.com",
        ])
        try runner.run(["init", "--bare", "-b", "main", "remote.git"], in: dir)
    }

    var remote: String { dir.appendingPathComponent("remote.git").path }

    func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The first person: makes a workspace, commits it and pushes it.
    func start(_ collection: APICollection) throws -> GitRepository {
        let folder = dir.appendingPathComponent("alice", isDirectory: true)
        let repo = try GitRepository.initialise(folder, runner: runner)
        try store(repo).save(collection)
        try repo.commitAll(message: "Start")
        try repo.setRemoteURL(remote)
        try repo.push()
        return repo
    }

    func clone(_ name: String) throws -> GitRepository {
        try GitRepository.clone(remote, to: dir.appendingPathComponent(name, isDirectory: true), runner: runner)
    }

    func store(_ repo: GitRepository) -> WorkspaceStore {
        WorkspaceStore(root: repo.root, secrets: InMemorySecretStore())
    }

    /// Changes one request in a person's copy, commits, and optionally pushes.
    func edit(_ repo: GitRepository, _ message: String, push: Bool = true, _ change: (inout RequestItem) -> Void) throws {
        let store = store(repo)
        var collection = try #require(try store.loadCollections().first)
        var request = try #require(collection.allRequests.first)
        change(&request)
        collection.updateRequest(request)
        try store.save(collection)
        try repo.commitAll(message: message)
        if push { try repo.push() }
    }

    func request(_ repo: GitRepository) throws -> RequestItem {
        try #require(try store(repo).loadCollections().first?.allRequests.first)
    }

    /// Pulls the way the app does: merge, settle what can be settled, finish if nothing is left.
    func pull(_ repo: GitRepository) throws -> (outcome: MergeOutcome, conflicts: [FileConflict]) {
        let outcome = try repo.pull()
        guard outcome == .conflicts else { return (outcome, []) }
        let conflicts = try repo.mergeConflicts()
        if conflicts.isEmpty { try repo.finishMerge() }
        return (outcome, conflicts)
    }
}

private func pets() -> APICollection {
    APICollection(name: "Pets", items: [
        .request(RequestItem(
            name: "List pets", method: "GET", url: "https://example.com/pets",
            headers: [KeyValue(key: "Accept", value: "application/json")]
        )),
    ])
}

private func json(_ text: String) -> Data { Data(text.utf8) }

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct JSONMerging {
    @Test func changesToDifferentFieldsCombine() throws {
        let result = try JSONMerge.merge(
            base: json(#"{"method":"GET","url":"/a","name":"One"}"#),
            ours: json(#"{"method":"POST","url":"/a","name":"One"}"#),
            theirs: json(#"{"method":"GET","url":"/b","name":"One"}"#)
        )
        #expect(result.conflicts.isEmpty)
        let merged = try object(result.merged)
        #expect(merged["method"] as? String == "POST")
        #expect(merged["url"] as? String == "/b")
    }

    @Test func theSameFieldChangedTwoWaysIsAConflict() throws {
        let base = json(#"{"url":"/a","name":"One"}"#)
        let ours = json(#"{"url":"/mine","name":"One"}"#)
        let theirs = json(#"{"url":"/theirs","name":"One"}"#)
        let result = try JSONMerge.merge(base: base, ours: ours, theirs: theirs)
        #expect(result.conflicts.count == 1)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.label == "url")
        #expect(conflict.base == "/a")
        #expect(conflict.ours == "/mine")
        #expect(conflict.theirs == "/theirs")
        #expect(try object(result.merged)["url"] as? String == "/mine")

        let chosen = try JSONMerge.merge(base: base, ours: ours, theirs: theirs, choices: [conflict.id: .theirs])
        #expect(try object(chosen.merged)["url"] as? String == "/theirs")
    }

    @Test func bothMakingTheSameChangeIsNotAConflict() throws {
        let result = try JSONMerge.merge(
            base: json(#"{"url":"/a"}"#), ours: json(#"{"url":"/b"}"#), theirs: json(#"{"url":"/b"}"#)
        )
        #expect(result.conflicts.isEmpty)
    }

    @Test func headersAreMatchedByNameNotPosition() throws {
        let result = try JSONMerge.merge(
            base: json(#"{"headers":[{"key":"Accept","value":"a","enabled":true}]}"#),
            ours: json(#"{"headers":[{"key":"X-Mine","value":"1","enabled":true},{"key":"Accept","value":"a","enabled":true}]}"#),
            theirs: json(#"{"headers":[{"key":"Accept","value":"b","enabled":true},{"key":"X-Theirs","value":"2","enabled":true}]}"#)
        )
        #expect(result.conflicts.isEmpty)
        let headers = try #require(try object(result.merged)["headers"] as? [[String: Any]])
        #expect(headers.map { $0["key"] as? String } == ["X-Mine", "Accept", "X-Theirs"])
        #expect(headers[1]["value"] as? String == "b")
    }

    @Test func aConflictInsideAListNamesTheItem() throws {
        let result = try JSONMerge.merge(
            base: json(#"{"headers":[{"key":"Accept","value":"a"}]}"#),
            ours: json(#"{"headers":[{"key":"Accept","value":"b"}]}"#),
            theirs: json(#"{"headers":[{"key":"Accept","value":"c"}]}"#)
        )
        #expect(result.conflicts.map(\.label) == ["headers › Accept › value"])
    }

    @Test func removingAnItemTheOtherSideChangedIsAConflict() throws {
        let result = try JSONMerge.merge(
            base: json(#"{"headers":[{"key":"Accept","value":"a"},{"key":"Keep","value":"k"}]}"#),
            ours: json(#"{"headers":[{"key":"Keep","value":"k"}]}"#),
            theirs: json(#"{"headers":[{"key":"Accept","value":"b"},{"key":"Keep","value":"k"}]}"#)
        )
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.label == "headers › Accept")
        #expect(conflict.ours == nil)
    }

    @Test func removingAnUntouchedItemJustRemovesIt() throws {
        let result = try JSONMerge.merge(
            base: json(#"{"headers":[{"key":"Accept","value":"a"},{"key":"Keep","value":"k"}]}"#),
            ours: json(#"{"headers":[{"key":"Keep","value":"k"}]}"#),
            theirs: json(#"{"headers":[{"key":"Accept","value":"a"},{"key":"Keep","value":"changed"}]}"#)
        )
        #expect(result.conflicts.isEmpty)
        let headers = try #require(try object(result.merged)["headers"] as? [[String: Any]])
        #expect(headers.count == 1)
        #expect(headers[0]["value"] as? String == "changed")
    }

    @Test func listsOfNamesKeepBothSidesAdditions() {
        let merged = JSONMerge.mergeList(
            base: ["a.request.json", "b.request.json", "c.request.json"],
            ours: ["c.request.json", "a.request.json", "b.request.json", "mine.request.json"],
            theirs: ["a.request.json", "theirs.request.json", "c.request.json"]
        )
        // Our order, without the one they removed, with theirs after the item it followed.
        #expect(merged == ["c.request.json", "a.request.json", "theirs.request.json", "mine.request.json"])
    }

    @Test func mergedFilesAreWrittenLikeSavedOnes() throws {
        let result = try JSONMerge.merge(
            base: json(#"{"b":1,"a":"x"}"#), ours: json(#"{"b":2,"a":"x"}"#), theirs: json(#"{"b":1,"a":"https://example.com/y"}"#)
        )
        let text = String(decoding: result.merged, as: UTF8.self)
        #expect(text == "{\n  \"a\" : \"https://example.com/y\",\n  \"b\" : 2\n}\n")
    }
}

@Suite struct WorkspaceFiles {
    @Test func filesAreDescribedByWhatTheyHold() {
        let request = WorkspaceFileInfo(
            path: "collections/pets/admin/list-pets.request.json", versions: [nil, json(#"{"name":"List pets"}"#)]
        )
        #expect(request.kind == .request)
        #expect(request.title == "List pets")
        #expect(request.location == "pets / admin")

        let folder = WorkspaceFileInfo(path: "collections/pets/admin/folder.json", versions: [json(#"{"name":"Admin"}"#)])
        #expect(folder.kind == .folder)
        #expect(folder.location == "pets")

        #expect(WorkspaceFileInfo(path: "environments/local.env.json").kind == .environment)
        #expect(WorkspaceFileInfo(path: "globals.json").title == "Global variables")
        #expect(WorkspaceFileInfo(path: ".gitignore").title == ".gitignore")
    }
}

@Suite struct GitRepositories {
    @Test func aFolderInsideAnotherRepositoryIsNotOpened() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let folder = sandbox.dir.appendingPathComponent("outer", isDirectory: true)
        _ = try GitRepository.initialise(folder, runner: sandbox.runner)
        let inner = folder.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(GitRepository.open(folder, runner: sandbox.runner) != nil)
        #expect(GitRepository.open(inner, runner: sandbox.runner) == nil)
        #expect(GitRepository.open(sandbox.dir, runner: sandbox.runner) == nil)
    }

    @Test func statusListsEachKindOfChange() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let repo = try GitRepository.initialise(sandbox.dir.appendingPathComponent("work"), runner: sandbox.runner)
        #expect(try repo.status().hasCommits == false)
        try Data("one".utf8).write(to: repo.root.appendingPathComponent("keep me.txt"))
        try Data("two".utf8).write(to: repo.root.appendingPathComponent("remove.txt"))
        try repo.commitAll(message: "First")

        try Data("changed".utf8).write(to: repo.root.appendingPathComponent("keep me.txt"))
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("remove.txt"))
        try Data("new".utf8).write(to: repo.root.appendingPathComponent("brand new.txt"))

        let status = try repo.status()
        #expect(status.branch == "main")
        #expect(status.hasCommits)
        #expect(status.upstream == nil)
        #expect(status.changes == [
            GitChange(path: "brand new.txt", kind: .added),
            GitChange(path: "keep me.txt", kind: .modified),
            GitChange(path: "remove.txt", kind: .deleted),
        ])
        #expect(repo.committedFile("keep me.txt") == Data("one".utf8))
    }

    @Test func discardPutsAFileBack() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let repo = try GitRepository.initialise(sandbox.dir.appendingPathComponent("work"), runner: sandbox.runner)
        let kept = repo.root.appendingPathComponent("kept.txt")
        try Data("one".utf8).write(to: kept)
        try repo.commitAll(message: "First")
        try Data("changed".utf8).write(to: kept)
        try Data("new".utf8).write(to: repo.root.appendingPathComponent("new.txt"))

        for change in try repo.status().changes { try repo.discard(change) }
        #expect(try repo.status().changes.isEmpty)
        #expect(try Data(contentsOf: kept) == Data("one".utf8))
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("new.txt").path))
    }

    @Test func commitsAppearInTheLogNewestFirst() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let repo = try sandbox.start(pets())
        try sandbox.edit(repo, "Use POST", push: false) { $0.method = "POST" }
        let log = try repo.log()
        #expect(log.map(\.subject) == ["Use POST", "Start"])
        #expect(log[0].author == "Test Person")
        #expect(log[0].shortID.count == 7)
        #expect(throws: GitError.self) { try repo.commitAll(message: "  ") }
    }

    @Test func branchesCanBeMadeSwitchedAndMerged() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let repo = try sandbox.start(pets())
        try repo.createBranch("try-post")
        #expect(try repo.status().branch == "try-post")
        try sandbox.edit(repo, "Use POST", push: false) { $0.method = "POST" }

        try repo.switchBranch("main")
        #expect(try sandbox.request(repo).method == "GET")
        #expect(try repo.branches().map(\.name).sorted() == ["main", "try-post"])
        #expect(try repo.branches().first { $0.isCurrent }?.name == "main")

        #expect(try repo.merge("try-post") == .fastForwarded)
        #expect(try sandbox.request(repo).method == "POST")
        #expect(try repo.merge("try-post") == .upToDate)
        #expect(throws: GitError.self) { try repo.createBranch("not a name") }
    }

    @Test func aBranchOnTheRemoteCanBeSwitchedTo() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let alice = try sandbox.start(pets())
        let bob = try sandbox.clone("bob")
        try alice.createBranch("feature")
        try sandbox.edit(alice, "Use PUT") { $0.method = "PUT" }

        try bob.fetch()
        let remoteOnly = try #require(try bob.branches().first { $0.name == "feature" })
        #expect(remoteOnly.isRemoteOnly)
        try bob.switchBranch("feature")
        #expect(try sandbox.request(bob).method == "PUT")
        #expect(try bob.status().upstream == "origin/feature")
    }
}

@Suite struct GitSync {
    @Test func pullBringsInTheOtherPersonsCommits() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let alice = try sandbox.start(pets())
        let bob = try sandbox.clone("bob")
        #expect(try sandbox.pull(bob).outcome == .upToDate)

        try sandbox.edit(alice, "Use POST") { $0.method = "POST" }
        try bob.fetch()
        #expect(try bob.status().behind == 1)
        #expect(try sandbox.pull(bob).outcome == .fastForwarded)
        #expect(try sandbox.request(bob).method == "POST")
    }

    @Test func pushIsRefusedWithAdviceWhenBehind() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let alice = try sandbox.start(pets())
        let bob = try sandbox.clone("bob")
        try sandbox.edit(alice, "Use POST") { $0.method = "POST" }
        try sandbox.edit(bob, "Rename", push: false) { $0.name = "All pets" }
        #expect(try bob.status().ahead == 1)
        do {
            try bob.push()
            Issue.record("The push should have been refused")
        } catch {
            #expect(error.localizedDescription.contains("Pull first"))
        }
    }

    @Test func changesToDifferentFieldsOfOneRequestMerge() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let alice = try sandbox.start(pets())
        let bob = try sandbox.clone("bob")
        // Neighbouring lines of one file: a merge by lines of text would collide here.
        try sandbox.edit(alice, "Use POST") { $0.method = "POST" }
        try sandbox.edit(bob, "Add a header and move it", push: false) {
            $0.url = "https://example.com/v2/pets"
            $0.headers.append(KeyValue(key: "X-Trace", value: "1"))
        }

        let result = try sandbox.pull(bob)
        #expect(result.conflicts.isEmpty)
        #expect(try bob.status().isMerging == false)
        #expect(try bob.status().changes.isEmpty)
        let merged = try sandbox.request(bob)
        #expect(merged.method == "POST")
        #expect(merged.url == "https://example.com/v2/pets")
        #expect(merged.headers.map(\.key) == ["Accept", "X-Trace"])

        try bob.push()
        let back = try sandbox.pull(alice)
        #expect(back.outcome == .fastForwarded)
        #expect(try sandbox.request(alice) == merged)
    }

    @Test func theSameFieldChangedTwoWaysWaitsForAChoice() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let alice = try sandbox.start(pets())
        let bob = try sandbox.clone("bob")
        try sandbox.edit(alice, "Alice's address") { $0.url = "https://alice.example.com/pets"; $0.method = "POST" }
        try sandbox.edit(bob, "Bob's address", push: false) { $0.url = "https://bob.example.com/pets"; $0.name = "All pets" }

        let result = try sandbox.pull(bob)
        #expect(result.outcome == .conflicts)
        let conflict = try #require(result.conflicts.first)
        #expect(result.conflicts.count == 1)
        #expect(conflict.info.kind == .request)
        #expect(conflict.fields.map(\.label) == ["url"])
        #expect(conflict.fields[0].ours == "https://bob.example.com/pets")
        #expect(conflict.fields[0].theirs == "https://alice.example.com/pets")
        #expect(try bob.status().isMerging)
        #expect(throws: GitError.self) { try bob.finishMerge() }
        #expect(throws: GitError.self) { try bob.resolve(conflict) }

        try bob.resolve(conflict, fields: [conflict.fields[0].id: .theirs])
        try bob.finishMerge()
        #expect(try bob.status().isMerging == false)
        let merged = try sandbox.request(bob)
        #expect(merged.url == "https://alice.example.com/pets")
        // The changes that did not collide are both kept.
        #expect(merged.method == "POST")
        #expect(merged.name == "All pets")
        #expect(try bob.log().first?.subject.hasPrefix("Merge") == true)
    }

    @Test func aMergeCanBeAbandoned() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let alice = try sandbox.start(pets())
        let bob = try sandbox.clone("bob")
        try sandbox.edit(alice, "Alice's address") { $0.url = "https://alice.example.com/pets" }
        try sandbox.edit(bob, "Bob's address", push: false) { $0.url = "https://bob.example.com/pets" }
        #expect(try sandbox.pull(bob).conflicts.count == 1)

        try bob.abortMerge()
        #expect(try bob.status().isMerging == false)
        #expect(try bob.status().changes.isEmpty)
        #expect(try sandbox.request(bob).url == "https://bob.example.com/pets")
    }

    @Test func deletingWhatTheOtherPersonChangedAsksWhichToKeep() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let alice = try sandbox.start(pets())
        let bob = try sandbox.clone("bob")
        try sandbox.edit(alice, "Use POST") { $0.method = "POST" }

        let store = sandbox.store(bob)
        var collection = try #require(try store.loadCollections().first)
        collection.items = []
        try store.save(collection)
        try bob.commitAll(message: "Remove the request")

        let result = try sandbox.pull(bob)
        let conflict = try #require(result.conflicts.first { $0.info.kind == .request })
        #expect(conflict.wholeFileReason != nil)
        #expect(conflict.ours == nil)
        #expect(!conflict.isSettled(fields: [:], file: nil))

        for other in result.conflicts where other.id != conflict.id {
            try bob.resolve(other, fields: Dictionary(uniqueKeysWithValues: other.fields.map { ($0.id, .ours) }), file: .ours)
        }
        try bob.resolve(conflict, file: .theirs)
        try bob.finishMerge()
        // Their version is back, and the workspace still opens with it in place.
        #expect(try sandbox.request(bob).method == "POST")
    }

    @Test func twoNewRequestsWithOneNameAreBothKept() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let alice = try sandbox.start(pets())
        let bob = try sandbox.clone("bob")
        for (repo, url) in [(alice, "https://example.com/a"), (bob, "https://example.com/b")] {
            let store = sandbox.store(repo)
            var collection = try #require(try store.loadCollections().first)
            collection.items.append(.request(RequestItem(name: "Add pet", method: "POST", url: url)))
            try store.save(collection)
            try repo.commitAll(message: "Add a request")
        }
        try alice.push()

        let result = try sandbox.pull(bob)
        #expect(result.conflicts.isEmpty)
        let requests = try #require(try sandbox.store(bob).loadCollections().first).allRequests
        #expect(requests.count == 3)
        #expect(Set(requests.filter { $0.name == "Add pet" }.map(\.url)) == ["https://example.com/a", "https://example.com/b"])
    }

    @Test func uncommittedChangesBlockAMerge() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let alice = try sandbox.start(pets())
        try Data("stray".utf8).write(to: alice.root.appendingPathComponent("note.txt"))
        do {
            _ = try alice.pull()
            Issue.record("The pull should have been refused")
        } catch {
            #expect(error.localizedDescription.contains("Commit or discard"))
        }
    }
}
