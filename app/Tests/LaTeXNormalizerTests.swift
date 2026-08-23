//
//  LaTeXNormalizerTests.swift
//  MarkDevKitTests
//
//  The mapping layer between conventional LaTeX and SwiftMath's command
//  table.
//
//  Two failure directions are pinned here, because each shipped once:
//  a mapping whose replacement still refuses to typeset (the reader gets a
//  refusal that names a command this layer could have rewritten), and a
//  rewrite that silently drops content — measured against SwiftMath's
//  parser, which *deletes* characters it cannot name, so `\therefore` → "∴"
//  parses to zero atoms and `p∴q` renders as `p q`. Deletion is the one
//  outcome worse than an honest refusal, which is why no such mapping exists.
//

import AppKit
import XCTest

@testable import MarkDevKit

final class LaTeXNormalizerTests: XCTestCase {
    // MARK: - Every mapping typesets

    /// A mapping is only as good as its replacement's render. Each entry here
    /// goes through the real renderer; a replacement SwiftMath refuses fails
    /// this test rather than shipping as a red strip in someone's note.
    @MainActor
    func testEveryMappingTypesets() {
        let cases = [
            "\\varnothing",
            "\\implies",
            "\\impliedby",
            "\\leqslant",
            "\\geqslant",
            "\\smallsetminus",
            "\\lvert x \\rvert",
            "\\lVert v \\rVert",
            "\\dots",
            "\\tfrac{1}{2}",
            "\\dfrac{1}{2}",
            "\\tbinom{n}{k}",
            "\\dbinom{n}{k}",
            "\\coloneqq",
            "\\eqqcolon",
            "\\operatorname{softmax}(z)",
            "\\operatorname*{argmin}_x f",
            "\\operatorname {spaced}(x)",
            "\\boldsymbol{\\theta}",
            "\\overrightarrow{AB}",
            "a \\pmod n",
            "a \\pmod{n}",
            "x \\bmod y",
            "\\argmax_\\theta L",
            "\\argmin_x f(x)",
            "\\arcsec x + \\arccsc y + \\arccot z",
            "\\sech t \\cdot \\csch u",
            "\\arcsinh w",
            "\\arsinh v",
            "a \\& b",
        ]
        for latex in cases {
            switch RichContentRenderer.shared.math(
                latex, fontSize: 16, color: .black, display: true)
            {
            case .success(let content):
                XCTAssertTrue(content.size.width > 0, "\(latex) typeset empty")
                XCTAssertTrue(content.size.height > 0, "\(latex) typeset empty")
            case .failure(let failure):
                XCTFail("\(latex) does not typeset after normalization: \(failure.reason)")
            }
        }
    }

    /// Commands with no honest equivalent stay unmapped — loudly. The parser
    /// deletes characters it cannot name, so a glyph spelling rewritten into
    /// its Unicode character would vanish while looking like success.
    @MainActor
    func testUnmappedCommandsFailLoudly() {
        let cases = [
            "\\therefore", "\\because", "\\vdash", "\\substack{a \\\\ b}", "\\overset{x}{=}",
        ]
        for latex in cases {
            switch RichContentRenderer.shared.math(
                latex, fontSize: 16, color: .black, display: true)
            {
            case .success:
                XCTFail("\(latex) should not typeset")
            case .failure(let failure):
                XCTAssertFalse(failure.reason.isEmpty)
            }
        }
    }

    // MARK: - Supported input passes through untouched

    func testNormalizerPreservesSupportedInput() {
        let untouched = [
            "E = mc^2",
            "\\frac{1}{2}",
            "\\sum_{i=1}^{n} i^2",
            "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}",
            "\\begin{cases} x & x > 0 \\\\ 0 & \\text{else} \\end{cases}",
            "\\text{dend}",
            "\\alpha \\beta \\gamma \\theta \\Delta\\theta \\Omega \\omega",
            "\\left( x \\right)",
            "\\sqrt[3]{8}",
            "\\int_0^\\infty e^{-x} dx",
            "a & b",
            "\\\\",
            "\\%",
            "\\$",
            "#", "$", "^", "_", "{", "}", "~",
            "\\therefore p \\vdash q",   // unknown commands pass through verbatim
        ]
        for latex in untouched {
            XCTAssertEqual(LaTeXNormalizer.normalize(latex), latex, "mangled: \(latex)")
        }
    }

    // MARK: - Rewrites are exact

    func testBracedAndBareArgumentsRewrite() {
        XCTAssertEqual(
            LaTeXNormalizer.normalize("\\operatorname{softmax}(z)"), "\\mathrm{softmax}(z)")
        XCTAssertEqual(
            LaTeXNormalizer.normalize("\\operatorname*{argmin}_x"), "\\mathrm{argmin}_x")
        XCTAssertEqual(
            LaTeXNormalizer.normalize("\\operatorname {spaced}"), "\\mathrm{spaced}")
        XCTAssertEqual(LaTeXNormalizer.normalize("\\boldsymbol{x}"), "\\mathbf{x}")
        XCTAssertEqual(LaTeXNormalizer.normalize("\\overrightarrow{AB}"), "\\vec{AB}")
        XCTAssertEqual(LaTeXNormalizer.normalize("a \\pmod n"), "a \\ (\\mathrm{mod}\\ n)")
        XCTAssertEqual(LaTeXNormalizer.normalize("a \\pmod{n}"), "a \\ (\\mathrm{mod}\\ n)")
        XCTAssertEqual(LaTeXNormalizer.normalize("x \\bmod y"), "x \\ \\mathrm{mod}\\  y")
        XCTAssertEqual(LaTeXNormalizer.normalize("\\argmax_\\theta"), "\\arg\\max_\\theta")
        XCTAssertEqual(LaTeXNormalizer.normalize("\\&"), "&")
    }

    /// Nested groups survive: the argument may itself carry braces.
    func testNestedGroupsSurvive() {
        XCTAssertEqual(
            LaTeXNormalizer.normalize("\\operatorname{f{g}}"), "\\mathrm{f{g}}")
        XCTAssertEqual(
            LaTeXNormalizer.normalize("\\boldsymbol{\\theta_{ij}}"), "\\mathbf{\\theta_{ij}}")
    }

    /// A braced command written without its group passes through for
    /// SwiftMath to reject, rather than being guessed at.
    func testCommandWithoutGroupPassesThrough() {
        XCTAssertEqual(LaTeXNormalizer.normalize("\\pmod"), "\\pmod")
        XCTAssertEqual(LaTeXNormalizer.normalize("\\operatorname*"), "\\operatorname*")
    }

    /// Malformed braces reach SwiftMath unchanged, which reports them with
    /// better context than any rewriter could.
    func testUnterminatedGroupPassesThrough() {
        let malformed = "\\operatorname{softmax"
        XCTAssertEqual(LaTeXNormalizer.normalize(malformed), "\\operatorname{softmax")
    }

    // MARK: - Composition properties

    /// Idempotence: wherever two callers both normalize, the second call is
    /// a no-op.
    func testIdempotence() {
        let inputs = [
            "\\varnothing \\implies p",
            "\\operatorname{softmax}(\\boldsymbol{z})",
            "\\pmod{7}", "\\bmod", "\\argmax", "\\&", "\\dots",
            "\\overrightarrow{AB}", "\\leqslant \\geqslant", "\\tbinom{n}{k}",
            "\\operatorname*", "\\operatorname", "\\pmod", "\\therefore",
            "plain text without commands",
        ]
        for latex in inputs {
            let once = LaTeXNormalizer.normalize(latex)
            XCTAssertEqual(LaTeXNormalizer.normalize(once), once, "not idempotent: \(latex)")
        }
    }

    /// Normalizing never deletes *mathematics*: every variable, digit, and
    /// operator the reader wrote survives into the output. Command names
    /// themselves may be rewritten away — `\implies` becoming `\Rightarrow`
    /// is the point — but the content between commands is untouchable.
    func testNoContentIsDeleted() {
        let expectations: [(input: String, keep: [String])] = [
            ("p\\implies q", ["p", "q"]),
            ("p\\impliedby q", ["p", "q"]),
            ("a\\&b", ["a", "&", "b"]),
            ("x\\bmod y", ["x", "y"]),
            ("a\\leqslant b", ["a", "b"]),
            ("\\boldsymbol{\\theta_5}", ["theta", "5"]),
            ("\\overrightarrow{AB}", ["A", "B"]),
            ("f\\colon\\eqqcolon g", ["f", "g"]),
        ]
        for (latex, keep) in expectations {
            let normalized = LaTeXNormalizer.normalize(latex)
            for character in keep {
                XCTAssertTrue(
                    normalized.contains(String(character)),
                    "'\(character)' from '\(latex)' vanished in '\(normalized)'")
            }
        }
        // And a formula whose only content is inside a rewrite keeps that
        // content: nothing between delimiters disappears.
        XCTAssertEqual(LaTeXNormalizer.normalize("\\tfrac{42}"), "\\frac{42}")
    }
}
