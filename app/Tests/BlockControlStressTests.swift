//
//  BlockControlStressTests.swift
//  MarkDevKitTests
//
//  What the block chips do under documents nobody wrote by hand, and clicks
//  nobody aimed.
//
//  The unit tests in `BlockControlTests` each pin one arrangement. This suite
//  exists for the failure that arrangement cannot show: a chip is drawn by the
//  fragment and hit-tested by the text view, and *nothing in AppKit connects
//  those two*. They agree only for as long as both keep reading the same
//  geometry, and a chip drawn an inch from where it is clickable looks exactly
//  like a chip that does nothing at all. So the property asserted here is the
//  one that matters: whatever is drawn, at wherever it lands, is clickable.
//
//  The seed ranges here are the ones worth paying for on every run. They were
//  chosen after a sweep of roughly ten times as many — about 4,300 seeds across
//  these seven properties — which found nothing the committed ranges had not
//  already found. Three of the four defects this suite was written against fail
//  inside the first ten seeds; widening buys distance from the corpus, not
//  depth, and the corpus is the thing to extend when a new construct grows a
//  chip.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class BlockControlStressTests: XCTestCase {
    /// Blocks with a chip, blocks without, and the containers that change what
    /// a code block's *syntax* is — a fence inside a list item is marked line
    /// by line, and one inside a quote wears a `> ` on every line.
    private static let atoms = [
        "```swift\nlet x = 1\nlet y = 2\n```\n",
        "```sh\necho hello\n```\n",
        "```\nplain fence\n```\n",
        "~~~\ntilde fence\n~~~\n",
        "```unclosed\nstill code\n",
        "```\n```\n",
        "    indented code\n    second line\n",
        "- item with a fence\n\n  ```sh\n  nested\n  ```\n",
        "> ```sh\n> quoted\n> ```\n",
        "```mermaid\ngraph TD;\nA-->B;\n```\n",
        "$$\nx^2 + y^2\n$$\n",
        "---\ntitle: front\n---\n",
        "# Heading\n", "Prose with `inline code` in it.\n", "- bullet\n",
        "- [x] done\n", "> quote\n", "| a | b |\n|---|---|\n| 1 | 2 |\n",
        "---\n", "\n",
    ]

    private func randomDocument(seed: UInt64, blocks: Int) -> String {
        var rng = SeededGenerator(seed: seed)
        return (0..<blocks).map { _ in Self.atoms.randomElement(using: &rng)! }.joined()
    }

    private func view(_ markdown: String, mode: EditorMode = .reading) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.mode = mode
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        view.setMarkdown(markdown)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func fragments(_ view: MarkdownTextView) -> [MarkdownLayoutFragment] {
        guard let manager = view.textLayoutManager else { return [] }
        manager.ensureLayout(for: manager.documentRange)
        var found: [MarkdownLayoutFragment] = []
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            if let fragment = fragment as? MarkdownLayoutFragment { found.append(fragment) }
            return true
        }
        return found
    }

    /// Where a fragment's chip is drawn, in the view's own coordinates.
    private func onScreen(
        _ rect: CGRect, of fragment: MarkdownLayoutFragment, in view: MarkdownTextView
    ) -> CGPoint {
        let frame = fragment.layoutFragmentFrame
        let origin = view.textContainerOrigin
        return CGPoint(x: rect.midX + frame.minX + origin.x, y: rect.midY + frame.minY + origin.y)
    }

    // MARK: - Drawn is clickable

    func testEveryChipDrawnIsAChipThatCanBeClicked() {
        // The whole reason `BlockControlLayout` exists. Over random documents,
        // every control any fragment reports drawing must hit-test back to
        // itself at the point it is drawn.
        for seed in (1...80) as ClosedRange<UInt64> {
            let source = randomDocument(seed: seed, blocks: 10)
            let view = view(source)
            var chips = 0

            for fragment in fragments(view) {
                for (control, rect) in fragment.controlRects {
                    chips += 1
                    let point = onScreen(rect, of: fragment, in: view)
                    guard let hit = view.blockControl(at: point) else {
                        XCTFail("seed \(seed): a \(control) chip is drawn where nothing is clickable")
                        continue
                    }
                    XCTAssertEqual(hit.control, control, "seed \(seed): the wrong chip answered")
                    XCTAssertTrue(
                        hit.fragment === fragment,
                        "seed \(seed): a neighbouring fragment claimed this chip")
                }
            }

            // A sweep that found nothing would pass every assertion above.
            if source.contains("```") { XCTAssertGreaterThan(chips, 0, "seed \(seed) drew no chip") }
        }
    }

    func testAChipNeverClaimsTheRestOfItsOwnPanel() {
        // The chip is drawn on top of the block, so it takes the click before
        // the caret moves. If its hit area were measured wrongly it would
        // swallow the panel, and a code block would stop being selectable.
        for seed in (100...150) as ClosedRange<UInt64> {
            let view = view(randomDocument(seed: seed, blocks: 8))
            for fragment in fragments(view) where !fragment.controlRects.isEmpty {
                let panel = fragment.decorationRect
                let leading = CGRect(
                    x: panel.minX, y: panel.minY, width: 1, height: max(panel.height, 1))
                XCTAssertNil(
                    view.blockControl(at: onScreen(leading, of: fragment, in: view)),
                    "seed \(seed): the chip is swallowing clicks at the panel's leading edge")
            }
        }
    }

    // MARK: - Clicking anywhere at all

    func testRandomClicksAcrossTheSurfaceNeverMisbehave() {
        // Every point of the view, plus points outside it: `mouseDown` runs the
        // control hit test before anything else, and `textLayoutFragment(for:)`
        // answers with the *nearest* fragment rather than only a containing
        // one — so the margins are exactly where a careless guard reports a hit
        // that is not there.
        for seed in (200...260) as ClosedRange<UInt64> {
            var rng = SeededGenerator(seed: seed)
            let view = view(randomDocument(seed: seed, blocks: 10))

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("untouched", forType: .string)

            for _ in 0..<40 {
                let point = CGPoint(
                    x: CGFloat.random(in: -80...600, using: &rng),
                    y: CGFloat.random(in: -80...1200, using: &rng))
                if view.handleControlClick(at: point) {
                    // A click that reported doing something must have done it:
                    // a copy that clears the pasteboard and writes nothing is
                    // the one outcome worse than not copying at all.
                    let copied = NSPasteboard.general.string(forType: .string)
                    XCTAssertNotNil(copied, "seed \(seed): the pasteboard was left empty")
                    XCTAssertFalse(
                        copied?.isEmpty ?? true, "seed \(seed): an empty string was copied")
                }
            }
        }
    }

    // MARK: - What lands on the pasteboard

    /// A fragment's range in document offsets, worked out here rather than
    /// asked of the view: an oracle that calls the code under test is not one.
    private func characterRange(
        of fragment: MarkdownLayoutFragment, in view: MarkdownTextView
    ) -> NSRange? {
        guard let manager = view.textLayoutManager,
            let element = fragment.textElement?.elementRange
        else { return nil }
        let start = manager.offset(from: manager.documentRange.location, to: element.location)
        let end = manager.offset(from: manager.documentRange.location, to: element.endLocation)
        guard start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The code-like blocks of a parse, in document order — the test's own copy
    /// of the question the view answers by binary search over an index.
    private func codeBlocks(of view: MarkdownTextView) -> [BlockDescriptor] {
        view.parsed.blocks.filter {
            switch $0.kind {
            case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter: true
            default: false
            }
        }
    }

    func testEveryChipCopiesTheBlockItIsDrawnOn() {
        // Two things at once, and the second is why this is a *stress* test.
        //
        // A chip that copies nothing at all: `offersCopy` is decided by finding
        // the block that *intersects* the fragment's line, and the action used
        // to look it up from a bare offset instead. Those differ for every code
        // block whose container indents it — a fence inside a list item starts
        // after the two spaces its line starts with — so the chip appeared,
        // clicked, and quietly did nothing.
        //
        // And a chip that copies the *wrong* block: the index behind that
        // lookup is rebuilt per parse, and an off-by-one there is discovered by
        // the reader, after pasting, somewhere that matters.
        for seed in (300...370) as ClosedRange<UInt64> {
            let view = view(randomDocument(seed: seed, blocks: 8))
            for fragment in fragments(view) where fragment.offersCopy {
                guard let rect = fragment.controlRects.first(where: { $0.control == .copy })?.rect
                else { continue }

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("untouched", forType: .string)
                XCTAssertTrue(
                    view.handleControlClick(at: onScreen(rect, of: fragment, in: view)),
                    "seed \(seed): a chip the fragment draws did not answer a click on it")

                let copied = NSPasteboard.general.string(forType: .string) ?? ""
                XCTAssertNotEqual(
                    copied, "untouched",
                    "seed \(seed): a chip was drawn and clicked, and copied nothing")
                XCTAssertFalse(copied.isEmpty, "seed \(seed): the chip copied an empty string")

                // The block the chip is drawn on, found the test's own way.
                guard let range = characterRange(of: fragment, in: view),
                    let block = codeBlocks(of: view).first(
                        where: { NSIntersectionRange($0.range, range).length > 0 })
                else { continue }
                XCTAssertEqual(
                    copied,
                    CodeBlockSource.copyText(
                        of: block, in: view.parsed, text: view.markdown as NSString),
                    "seed \(seed): the chip copied a block other than the one it sits on")
            }
        }
    }

    // MARK: - One confirmation, one hover

    func testNoSequenceOfCopiesLeavesTwoChipsTicked() {
        // The bug this pins: the tick is state on the fragment, and only the
        // timer started with it ever took it off — so a second copy cancelled
        // the first timer and left the first chip ticked for good, two chips
        // both claiming to hold the pasteboard.
        for seed in (400...450) as ClosedRange<UInt64> {
            var rng = SeededGenerator(seed: seed)
            let view = view(randomDocument(seed: seed, blocks: 10))
            let copyable = fragments(view).filter(\.offersCopy)
            guard copyable.count > 1 else { continue }

            for _ in 0..<8 {
                let fragment = copyable.randomElement(using: &rng)!
                guard let rect = fragment.controlRects.first(where: { $0.control == .copy })?.rect
                else { continue }
                view.handleControlClick(at: onScreen(rect, of: fragment, in: view))

                XCTAssertLessThanOrEqual(
                    fragments(view).filter(\.copyConfirmed).count, 1,
                    "seed \(seed): more than one chip is showing a confirmation")
            }
        }
    }

    func testAHoverSweepLeavesAtMostOneChipLit() {
        for seed in (500...540) as ClosedRange<UInt64> {
            var rng = SeededGenerator(seed: seed)
            let view = view(randomDocument(seed: seed, blocks: 10))

            for _ in 0..<30 {
                view.updateHover(
                    at: CGPoint(
                        x: CGFloat.random(in: -40...600, using: &rng),
                        y: CGFloat.random(in: -40...1200, using: &rng)))
                XCTAssertLessThanOrEqual(
                    fragments(view).filter({ $0.hoveredControl != nil }).count, 1,
                    "seed \(seed): two chips are lit at once")
            }

            view.updateHover(at: nil)
            XCTAssertTrue(fragments(view).allSatisfy { $0.hoveredControl == nil })
        }
    }

    // MARK: - Under editing

    func testChipsSurviveRandomEditsWithoutDriftingFromTheirBlocks() {
        // The index a chip's block is found through is rebuilt on every parse.
        // An edit that moves a fence must move its chip with it, or the chip
        // copies a neighbour's snippet — which the reader discovers only after
        // pasting it somewhere that matters.
        for seed in (600...640) as ClosedRange<UInt64> {
            var rng = SeededGenerator(seed: seed)
            let view = view(randomDocument(seed: seed, blocks: 8), mode: .livePreview)

            for _ in 0..<20 {
                let length = (view.markdown as NSString).length
                let start = length == 0 ? 0 : Int.random(in: 0...length, using: &rng)
                view.setSelectedRange(NSRange(location: start, length: 0))
                view.insertText(
                    Self.atoms.randomElement(using: &rng)!, replacementRange: view.selectedRange())
                view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

                for fragment in fragments(view) where fragment.offersCopy {
                    guard let rect = fragment.controlRects.first(where: { $0.control == .copy })?
                        .rect
                    else { continue }
                    let hit = view.blockControl(at: onScreen(rect, of: fragment, in: view))
                    XCTAssertTrue(
                        hit?.fragment === fragment,
                        "seed \(seed): after an edit, a chip is drawn where it cannot be clicked")
                }
            }
        }
    }
}
