//
//  WorkspaceIOResponsivenessContractTests.swift
//  MarkDevKitTests
//
//  App-level I/O contracts that cannot import the MarkDev executable target.
//

import XCTest

final class WorkspaceIOResponsivenessContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repository
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    /// Removes full-line comments so an implementation promise cannot be
    /// satisfied by prose that merely describes the intended behavior.
    private func code(_ relativePath: String) throws -> String {
        try source(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func slice(
        _ source: String,
        from start: String,
        until end: String
    ) throws -> Substring {
        let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
        let endIndex = try XCTUnwrap(
            source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
        return source[startIndex..<endIndex]
    }

    /// Opening a document currently reaches a descriptor read from an
    /// `@MainActor` Workspace method. A remote or unavailable volume can then
    /// stop every window event. The UI path must await LocalDocumentIO and
    /// bind the completion to the exact pane/window generation that asked.
    func testDocumentOpenUsesAsyncReadAndGenerationBoundCommit() throws {
        let workspace = try code("app/MarkDevKit/Workspace/Workspace.swift")
        let view = try code("app/MarkDev/WorkspaceView.swift")
        let openFile = try slice(
            view,
            from: "private func openFile(",
            until: "private func takeFromInbox(")

        XCTAssertTrue(
            workspace.contains("func openAsync("),
            "Workspace needs one async canonical open seam for every UI entry point")
        XCTAssertTrue(
            workspace.contains("await documentIO.read("),
            "document bytes must be read by the bounded off-main I/O actor")
        XCTAssertTrue(
            openFile.contains("async") && openFile.contains("await workspace.openAsync("),
            "WorkspaceView must await the canonical async open rather than read on MainActor")
        XCTAssertFalse(
            openFile.contains("workspace.open("),
            "the executable target must not call the synchronous document reader")
        XCTAssertTrue(
            openFile.contains("workspaceIOLifecycle.isCurrent"),
            "a delayed read may commit only into the still-current window and pane generation")
    }

    /// `VaultIndex.open` walks and parses the whole vault synchronously. Both
    /// an explicit Open Vault and session restoration must prepare that index
    /// off-main, and a slower earlier request must never replace a later root.
    func testVaultOpenAndSessionRestoreNeverScanOnMainActor() throws {
        let view = try code("app/MarkDev/WorkspaceView.swift")
        let registry = try code("app/MarkDevKit/Vault/VaultIndexRegistry.swift")
        let openVault = try slice(
            view,
            from: "private func openVaultRoot(",
            until: "private func startWatching(")
        let restore = try slice(
            view,
            from: "private func restoreSessionOnce()",
            until: "private func persistSession()")

        XCTAssertTrue(
            registry.contains("func indexAsync("),
            "the shared registry needs an asynchronous index-construction boundary")
        XCTAssertTrue(
            registry.contains("VaultOpenImplementation"),
            "slow, cancellation, and dependency-down behavior needs an injected vault opener")
        XCTAssertTrue(
            openVault.contains("async")
                && openVault.contains("await VaultIndexRegistry.shared.indexAsync("),
            "opening a vault must suspend the UI while its scan runs elsewhere")
        XCTAssertTrue(
            openVault.contains("workspaceIOLifecycle.isCurrent"),
            "latest-root identity must guard the scan completion")
        XCTAssertFalse(
            restore.contains(".index(for:"),
            "session restoration must not retain the old synchronous registry path")
        XCTAssertTrue(
            restore.contains("openVaultRoot") && restore.contains("Task"),
            "restored roots must enter the same cancellable async path as explicit roots")
    }

    /// Restoring a layout can read every retained tab. Session bounds limit
    /// memory after the fact, but do not make those descriptor reads safe for
    /// MainActor. Restore must stage the bounded reads through LocalDocumentIO
    /// and atomically apply only the still-current launch generation.
    func testSessionDocumentRestoreUsesBoundedAsyncReadsAndAtomicCommit() throws {
        let workspace = try code("app/MarkDevKit/Workspace/Workspace.swift")
        let view = try code("app/MarkDev/WorkspaceView.swift")
        let restoreView = try slice(
            view,
            from: "private func restoreSessionOnce()",
            until: "private func persistSession()")

        XCTAssertTrue(
            workspace.contains("func restoreAsync("),
            "session restoration needs an async variant that owns all retained-tab reads")
        XCTAssertTrue(
            restoreView.contains("await workspace.restoreAsync("),
            "the launch path must not invoke synchronous Workspace.restore")
        XCTAssertFalse(restoreView.contains("workspace.restore(from:"))
        XCTAssertTrue(
            restoreView.contains("workspaceIOLifecycle.isCurrent"),
            "a restored snapshot may commit only into the window generation that claimed it")
        XCTAssertTrue(
            restoreView.contains("Task"),
            "the synchronous SwiftUI onAppear callback must hand restore to a cancellable task")
    }

    /// Choosing a name with `fileExists` and then writing it is a TOCTOU race,
    /// and the unbounded loop runs on MainActor. Creation must hold the parent
    /// directory, use O_EXCL relative to it, cap attempts, and propagate
    /// cancellation without following a replacement symlink.
    func testCreateNoteUsesBoundedDescriptorRelativeExclusiveCreationOffMain() throws {
        let view = try code("app/MarkDev/WorkspaceView.swift")
        let io = try code("app/MarkDevKit/Workspace/LocalDocumentIO.swift")
        let secureFS = try code("app/MarkDevKit/Workspace/SecureLocalFileSystem.swift")
        let createNote = try slice(
            view,
            from: "private func createNote(in folder: URL)",
            until: "private func renameNote(at url: URL)")

        XCTAssertFalse(createNote.contains("FileManager.default.fileExists"))
        XCTAssertFalse(createNote.contains(".write(to:"))
        XCTAssertTrue(
            createNote.contains("await") && createNote.contains("createUniqueEmptyDocument"),
            "the view must delegate note creation to cancellable off-main I/O")
        XCTAssertTrue(
            io.contains("func createUniqueEmptyDocument("),
            "LocalDocumentIO must own bounded scheduling and cancellation for creation")
        XCTAssertTrue(
            io.contains("CreateImplementation") && io.contains("maximumAttempts"),
            "creation needs an injectable slow/failing implementation and a finite name budget")
        XCTAssertTrue(
            secureFS.contains("func createExclusiveUserContentFile("),
            "the secure filesystem must own descriptor-relative exclusive creation")
        XCTAssertTrue(
            secureFS.contains("O_EXCL")
                && secureFS.contains("O_NOFOLLOW")
                && secureFS.contains("O_RESOLVE_BENEATH"),
            "exclusive creation must remain beneath the held directory without following links")
    }

    /// Direct Finder drops and Open-panel batches bypass DocumentInbox's
    /// existing bound. The UI must normalize every batch through one bounded
    /// request and retain an item-labelled failure for every attempted file,
    /// rather than showing only whichever error happened last.
    func testEveryOpenBatchIsBoundedAndRetainsPerItemFailures() throws {
        let view = try code("app/MarkDev/WorkspaceView.swift")
        let inbox = try code("app/MarkDevKit/Workspace/DocumentInbox.swift")
        let dropped = try slice(
            view,
            from: "private func open(dropped urls:",
            until: "private func openDroppedMarkdown(")
        let editorDrop = try slice(
            view,
            from: "private func openDroppedMarkdown(",
            until: "private func openVaultRoot(")

        XCTAssertTrue(
            inbox.contains("public struct DocumentOpenFailure"),
            "batch failures need an item-labelled, privacy-safe value type")
        XCTAssertTrue(
            inbox.contains("failures: [DocumentOpenFailure]"),
            "all attempted-item failures must survive accumulation")
        XCTAssertTrue(
            inbox.contains("static func bounded("),
            "DocumentInbox and direct UI batches must share one admission bound")
        XCTAssertTrue(
            dropped.contains("DocumentOpenRequest.bounded("),
            "window and Open-panel drops must not bypass the batch limit")
        XCTAssertTrue(
            editorDrop.contains("DocumentOpenRequest.bounded("),
            "editor-targeted drops must enforce the same finite admission policy")
        XCTAssertFalse(
            dropped.contains("resourceValues(forKeys:"),
            "per-item filesystem classification must not run on MainActor")
        XCTAssertTrue(
            dropped.contains("record(") && dropped.contains("item:"),
            "each failed URL must remain associated with its safe display name")
    }

    /// A main-actor `Task` remains main-actor isolated after its debounce.
    /// Watch handling, rename rebasing, and external reload therefore need
    /// async snapshot seams plus root/document generation checks after every
    /// suspension. A stale read must be refused, not applied to a replacement.
    func testWatcherRenameAndExternalReloadUseIdentityCheckedAsyncSnapshots() throws {
        let view = try code("app/MarkDev/WorkspaceView.swift")
        let watcher = try slice(
            view,
            from: "private func handleWatchedPaths(",
            until: "private func workspaceOpenDocument(")
        let openDocumentLookup = try slice(
            view,
            from: "private func workspaceOpenDocument(",
            until: "private func acceptExternalVersion(")
        let rename = try slice(
            view,
            from: "private func performRename(",
            until: "private func dropNotes(")
        let reload = try slice(
            view,
            from: "private func acceptExternalVersion(",
            until: "private func conflictBar(")
        let keepLocal = try slice(
            view,
            from: "private func keepLocalVersion(",
            until: "private func makeTabSwitcher()")

        for operation in [watcher, rename, reload] {
            XCTAssertFalse(
                operation.contains("NoteTextCache.shared.utf8Text("),
                "disk reads must cross an async bounded seam instead of running on MainActor")
            XCTAssertTrue(operation.contains("await"), "blocking I/O paths must suspend")
            XCTAssertTrue(
                operation.contains("workspaceIOLifecycle.isCurrent"),
                "every post-await mutation needs an exact lifecycle-generation guard")
        }
        XCTAssertTrue(
            openDocumentLookup.contains(
                "BoundedRegularFileReader.hasLocalFileAuthority(url)"),
            "a remote-authority spelling must not alias an open local document")
        XCTAssertTrue(
            watcher.contains("observeExternalChangesAsync"),
            "watch reads need a cancellable batch snapshot operation")
        XCTAssertTrue(
            watcher.contains("maximumWatchedPaths"),
            "one hostile or coalesced FSEvents batch must have a finite work budget")
        XCTAssertTrue(
            watcher.contains("omittedPathCount"),
            "a capped watcher batch must retain evidence that its coverage was incomplete")
        XCTAssertTrue(
            rename.contains("renameNoteOffMain") && rename.contains("rebaseFromDiskAsync"),
            "both Rust rename I/O and bystander reads must leave MainActor")
        XCTAssertTrue(
            reload.contains("reloadFromDiskAsync"),
            "reload must validate the document edit generation and file identity before commit")
        XCTAssertFalse(
            keepLocal.contains("workspace.keepLocal(document:"),
            "Keep Mine also reads the current disk version and cannot remain synchronous")
        XCTAssertTrue(
            keepLocal.contains("await workspace.keepLocalAsync("),
            "Keep Mine must use the same cancellable, exact-version read boundary")
    }

    /// I/O work can outlive the SwiftUI value that launched it. Teardown must
    /// cancel the tasks and invalidate a non-wrapping epoch before any old
    /// completion can touch recent documents, alerts, panes, or a new root.
    func testWorkspaceTeardownCancelsAndInvalidatesAllIO() throws {
        let view = try code("app/MarkDev/WorkspaceView.swift")
        let lifecycle = try code("app/MarkDevKit/Workspace/WorkspaceIOLifecycle.swift")
        let disappear = try slice(
            view,
            from: "private func workspaceDidDisappear()",
            until: "private var isTerminalVisible:")

        XCTAssertTrue(
            view.contains("@State private var workspaceIOLifecycle = WorkspaceIOLifecycle()"))
        XCTAssertTrue(
            view.contains("@State private var workspaceIOTasks = WorkspaceIOTaskBag()"))
        XCTAssertTrue(disappear.contains("workspaceIOLifecycle.invalidateAll()"))
        XCTAssertTrue(disappear.contains("workspaceIOTasks.cancelAll()"))
        XCTAssertTrue(
            lifecycle.contains("UUID"),
            "an integer epoch can alias after wrap and authorize an ancient completion")
        XCTAssertFalse(lifecycle.contains("&+="))
    }

    /// Raw Cocoa and POSIX descriptions can include absolute paths. UI errors
    /// may identify the requested item by a bounded basename, while diagnostic
    /// metadata records only typed counts/status — never a full path or note
    /// contents. Every async path must use that canonical projection.
    func testIOFailuresUseOneBoundedPrivacySafePresentation() throws {
        let view = try code("app/MarkDev/WorkspaceView.swift")
        let open = try slice(
            view,
            from: "private func openFile(",
            until: "private func takeFromInbox(")
        let create = try slice(
            view,
            from: "private func createNote(in folder: URL)",
            until: "private func renameNote(at url: URL)")
        let rename = try slice(
            view,
            from: "private func performRename(",
            until: "private func dropNotes(")
        let reload = try slice(
            view,
            from: "private func acceptExternalVersion(",
            until: "private func conflictBar(")

        XCTAssertTrue(
            view.contains("WorkspaceIOFailure.presentation("),
            "one formatter must bound item labels and redact paths/content")
        for operation in [open, create, rename, reload] {
            XCTAssertFalse(
                operation.contains("error.localizedDescription"),
                "raw dependency errors must not cross the user-facing privacy boundary")
            XCTAssertTrue(
                operation.contains("WorkspaceIOFailure.presentation("),
                "every failure path must use the same typed safe projection")
        }
    }

    /// A drag may contain several notes. Scheduling the single-note adapter
    /// once per item makes item two observe the first task as active and refuse
    /// itself deterministically; the batch must own one task and await the
    /// canonical mutation for every admitted item instead.
    func testNavigatorNoteDropOwnsOneDeterministicRenameBatch() throws {
        let view = try code("app/MarkDev/WorkspaceView.swift")
        let drop = try slice(
            view,
            from: "private func dropNotes(",
            until: "private func trashVaultItem(")

        XCTAssertTrue(drop.contains("WorkspaceRenameBatchRequest.bounded(urls)"))
        XCTAssertEqual(
            drop.components(separatedBy: "workspaceIOTasks.launch(in: scope").count - 1,
            1,
            "one drag must create one task owner, not one competing owner per note")
        XCTAssertTrue(drop.contains("for move in plannedMoves"))
        XCTAssertTrue(drop.contains("try await performRename("))
        XCTAssertTrue(drop.contains("outcome.record("))
        XCTAssertFalse(
            drop.contains("applyRename(from:"),
            "the synchronous single-item adapter self-refuses after the first loop iteration")
    }
}
