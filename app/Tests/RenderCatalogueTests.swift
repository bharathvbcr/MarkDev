//
//  RenderCatalogueTests.swift
//  MarkDevKitTests
//
//  A diagnostic harness, not a gate. Renders a set of stress documents to
//  PNGs under MARKDEV_CATALOGUE_DIR so the drawing can be inspected as
//  pixels rather than reasoned about from attributes. Skips unless that
//  variable is set, so an ordinary test run never pays for it.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class RenderCatalogueTests: XCTestCase {
    private func dump(
        _ name: String, _ markdown: String, height: CGFloat = 560, caret: Int? = nil
    ) throws {
        guard let directory = ProcessInfo.processInfo.environment["MARKDEV_CATALOGUE_DIR"] else {
            throw XCTSkip("MARKDEV_CATALOGUE_DIR unset")
        }

        let view = MarkdownTextView.make()
        // Without both of these the capture is white text on a transparent
        // bitmap: `.labelColor` resolves against the effective appearance,
        // which for a windowless view in the test runner is dark, and nothing
        // fills the rep behind it.
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = true
        view.backgroundColor = .white
        view.frame = NSRect(x: 0, y: 0, width: 720, height: height)
        view.setMarkdown(markdown)
        if let caret {
            view.setSelectedRange(NSRange(location: caret, length: 0))
        }
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    func testTableWithLongTrailingCell() throws {
        try dump(
            "01-table-long-trailing",
            """
            Intro paragraph.

            | Concern | Details |
            |---|---|
            | Local dependencies | `docker-compose.yml` provides Postgres, Redis, Temporal, and a Go orchestrator service definition |
            | Container engine | Podman is the default for local development; Docker remains supported as a fallback and is what CI builds images with |
            | Secret source | Google Cloud Secret Manager is canonical |
            """, caret: 0)
    }

    func testTableWithLongMiddleCell() throws {
        try dump(
            "02-table-long-middle",
            """
            Intro paragraph.

            | Step | What it does | Owner |
            |---|---|---|
            | Preflight | Regenerates the generated endpoint env file and then runs compose, choosing podman then docker | Platform |
            | Deploy | Ships | Release |
            """, caret: 0)
    }

    func testTableNarrow() throws {
        try dump(
            "03-table-narrow",
            """
            Intro paragraph.

            | Name | Age | City |
            |---|---|---|
            | Ada | 36 | London |
            | Grace | 45 | New York |
            | Alan | 41 | Cambridge |
            """,
            height: 260, caret: 0)
    }

    func testTableWithManyColumns() throws {
        try dump(
            "04-table-many-columns",
            """
            Intro paragraph.

            | Service | Language | Port | Engine | Secrets | Notes |
            |---|---|---|---|---|---|
            | gateway | Rust | 8080 | podman | GSM | edge |
            | orchestrator | Go | 8081 | podman | GSM | core |
            | sidecar | Python | 8082 | docker | GSM | helper |
            """,
            height: 300, caret: 0)
    }

    func testTableAlignmentAndEmphasis() throws {
        try dump(
            "05-table-emphasis",
            """
            Intro paragraph.

            | Left | Center | Right |
            |:---|:---:|---:|
            | **bold cell** | `code` | 42 |
            | plain | *italic* | 1,024 |
            """,
            height: 260, caret: 0)
    }

    func testNestedListsAndTasks() throws {
        try dump(
            "06-lists",
            """
            Intro paragraph.

            - Top level item
              - Nested once, with enough text that this particular item has to
                wrap onto a second line to be read at all
                - Nested twice
            - [ ] An unchecked task
            - [x] A checked task
            1. Ordered
            2. Also ordered
               1. Nested ordered
            """,
            height: 380, caret: 0)
    }

    func testCalloutsAndQuotes() throws {
        try dump(
            "07-callouts",
            """
            Intro paragraph.

            > [!NOTE]
            > A callout whose body is long enough to wrap across more than one
            > line, which is where the accent bar and the indent have to agree.

            > An ordinary block quote
            > - containing a list
            > - with two items
            """,
            height: 360, caret: 0)
    }

    func testCodeBlocksAndInlineCode() throws {
        try dump(
            "08-code",
            """
            Intro paragraph.

            Prose with `inline code` and a `much_longer_inline_code_identifier` in it.

            ```swift
            let aVeryLongLineOfCode = someFunction(withArgument: "one", andAnother: "two", andAThird: 3)
            let short = 1
            ```

            ### A heading with `code` in it
            """,
            height: 400, caret: 0)
    }

    func testBlockControls() throws {
        // The chips: copy on every code panel, labelled or not, and zoom in the
        // corner of a rendered diagram.
        try dump(
            "17-controls",
            """
            Intro paragraph.

            ```swift
            let x = 1
            let somewhatLonger = 2
            ```

            ```
            a fence with no language at all
            ```

            ```mermaid
            flowchart TD
            A[Start] --> B[Finish]
            ```
            """,
            height: 620, caret: 0)
    }

    func testTableInsideQuote() throws {
        try dump(
            "09-table-in-quote",
            """
            Intro paragraph.

            > | Key | Value |
            > |---|---|
            > | one | a reasonably long value that will need the width |
            """,
            height: 240, caret: 0)
    }

    /// The same narrow table, but with a trailing newline and a paragraph
    /// after it — isolating whether the last block's revealed syntax is about
    /// being last in the *document* or last in the table.
    func testTableFollowedByProse() throws {
        try dump(
            "11-table-then-prose",
            """
            Intro paragraph.

            | Name | Age | City |
            |---|---|---|
            | Ada | 36 | London |
            | Grace | 45 | New York |
            | Alan | 41 | Cambridge |

            A paragraph after the table.
            """,
            height: 300, caret: 0)
    }

    /// A heading last in the document versus a heading with a newline after
    /// it. Same question, cheapest possible construct.
    func testTrailingNewlineOnLastBlock() throws {
        try dump("12-heading-last", "Prose first.\n\n### A heading last", height: 200)
        try dump("13-heading-newline", "Prose first.\n\n### A heading last\n", height: 200)
    }

    /// Headings first, middle, and last. If only the last one shows its
    /// `#` markers, the defect is about being last in the document rather
    /// than about the caret or about tables.
    func testHeadingsThroughout() throws {
        try dump(
            "15-headings",
            """
            # First heading

            Some prose with `code`.

            ## Middle heading

            More prose.

            ### Last heading
            """,
            height: 460)
    }

    /// The same document with the caret parked at the very start. If the
    /// last heading now collapses and the first one reveals, the "last block"
    /// effect is just live preview following a caret the harness left at the
    /// end of the text.
    func testHeadingsCaretAtStart() throws {
        try dump(
            "16-headings-caret-start",
            """
            # First heading

            Some prose with `code`.

            ## Middle heading

            More prose.

            ### Last heading
            """,
            height: 460, caret: 0)
    }

    func testOrderedListDepth() throws {
        try dump(
            "14-ordered",
            """
            Intro paragraph.

            1. First at top level
            2. Second at top level
            3. Third at top level

            Done.
            """,
            height: 300, caret: 0)
    }

    func testTableRaggedRows() throws {
        try dump(
            "10-table-ragged",
            """
            Intro paragraph.

            | A | B | C |
            |---|---|---|
            | 1 | 2 |
            | 1 | 2 | 3 | 4 |
            | | | |
            """,
            height: 280, caret: 0)
    }
}
