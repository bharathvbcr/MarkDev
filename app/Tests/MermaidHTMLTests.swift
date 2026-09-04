//
//  MermaidHTMLTests.swift
//  MarkDevKitTests
//
//  GitHub README mermaid writes HTML in node labels. The native renderer
//  cannot format those tags, so they must not appear as text in the picture.
//

import BeautifulMermaid
import XCTest

@testable import MarkDevKit

@MainActor
final class MermaidHTMLTests: XCTestCase {

    func testABoldAndCodeLabelKeepsTheWordsAndDropsTheTags() {
        let cleaned = MermaidHTML.sanitizeLabel(
            #"<b>Work</b> (<code>work</code>)<br/>Worktrees, PRs, remotes & verdicts"#)
        XCTAssertFalse(cleaned.contains("<"), cleaned)
        XCTAssertFalse(cleaned.contains("b>"), cleaned)
        XCTAssertTrue(cleaned.contains("Work"))
        XCTAssertTrue(cleaned.contains("work"))
        XCTAssertTrue(cleaned.contains("Worktrees"))
        XCTAssertTrue(
            cleaned.contains("\\n"),
            "a <br/> must become mermaid's \\n so the parse still sees one line: \(cleaned.debugDescription)")
        XCTAssertFalse(
            cleaned.contains("\n"),
            "a real newline would split the mermaid line: \(cleaned.debugDescription)")
    }

    func testQuotedLabelsAreRewrittenAndTheHeaderIsNot() {
        let source = """
            flowchart LR
              A["<b>Hello</b>"] --> B
            """
        let cleaned = MermaidHTML.sanitized(source)
        XCTAssertTrue(cleaned.hasPrefix("flowchart LR"), cleaned)
        XCTAssertFalse(cleaned.contains("<b>"), cleaned)
        XCTAssertTrue(cleaned.contains("Hello"), cleaned)
    }

    func testADiagramWithoutHTMLIsUntouched() {
        let source = "flowchart TD\n  A[Start] --> B[End]"
        XCTAssertEqual(MermaidHTML.sanitized(source), source)
    }
    /// The GitPulse README view map: subgraphs, emoji titles, and HTML labels.
    private let gitpulse = """
        flowchart LR
            subgraph Work["🔨 Work Views"]
                WorkTab["<b>Work</b> (<code>work</code>)<br/>Worktrees, PRs, remotes & verdicts"]
                Files["<b>Files</b> (<code>files</code>)<br/>IDE file explorer & code viewer"]
                Graph["<b>Graph</b> (<code>history</code>)<br/>Canvas commit graph & lanes"]
                Diff["<b>Diff</b> (<code>diff</code>)<br/>Word-level diff & selective staging"]
                Conflict["<b>Resolve</b> (<code>conflict</code>)<br/>3-way merge conflict editor"]
            end

            subgraph Inspect["🔍 Inspect Views"]
                Blame["<b>Blame</b> (<code>blame</code>)<br/>Line authorship & heatmap"]
                Coverage["<b>Coverage</b> (<code>coverage</code>)<br/>Universal scanner & line gutters"]
                Health["<b>Health</b> (<code>health</code>)<br/>Vulnerabilities & Dependabot"]
                Storage["<b>Storage</b> (<code>storage</code>)<br/>Disk usage & history trends"]
                Stack["<b>Stack</b> (<code>stack</code>)<br/>Stacked branch visualization"]
                Pulse["<b>Pulse</b> (<code>pulse</code>)<br/>Cadence, heatmap, rhythm & hygiene"]
            end

            subgraph System["⚙️ System & Ops"]
                Terminal["<b>Terminal</b> (<code>terminal</code>)<br/>Isolated native PTY shell"]
                MANVI["<b>MANVI</b> (<code>manvi</code>)<br/>Policy gate & local AI harness"]
                GitHub["<b>GitHub</b> (<code>github</code>)<br/>PRs, workflow dispatch & CI:local"]
                Reflog["<b>Reflog</b> (<code>reflog</code>)<br/>Reference history log"]
            end
        """

    func testSanitizedGitPulseLabelsHaveNoHTML() throws {
        let graph = try MermaidRenderer.parse(MermaidHTML.sanitized(gitpulse))
        guard case .flowchart(let model) = graph.typedPayload else {
            return XCTFail("expected a flowchart")
        }
        XCTAssertGreaterThanOrEqual(model.nodesInOrder.count, 14)
        XCTAssertEqual(model.subgraphs.count, 3, "Work, Inspect, and System")
        for (_, node) in model.nodesInOrder {
            XCTAssertFalse(
                node.label.contains("<"),
                "\(node.id) still carries HTML: \(node.label.debugDescription)")
            XCTAssertFalse(node.label.isEmpty, "\(node.id) lost its label")
        }
        for subgraph in model.subgraphs {
            XCTAssertFalse(subgraph.label.contains("<"), subgraph.label)
        }
    }

    func testDisconnectedLRSubgraphsSitInARow() throws {
        // ELK ranks disconnected subgraphs on the cross-axis, so a
        // `flowchart LR` with two groups and no edges arrives as a column
        // unless packing restacks them.
        let source = """
            flowchart LR
              subgraph Left["Left"]
                L1[L1]
              end
              subgraph Right["Right"]
                R1[R1]
              end
            """
        let packed = MermaidSubgraphPack.applied(
            to: try MermaidRenderer.layout(MermaidHTML.sanitized(source)))
        guard case .flowchart(_, _, let groups) = packed.content,
            let left = groups.first(where: { $0.id == "Left" }),
            let right = groups.first(where: { $0.id == "Right" })
        else { return XCTFail("expected both subgraphs") }
        XCTAssertLessThan(
            left.x + left.width, right.x + 1,
            "Left should sit to the left of Right, not above it")
        XCTAssertEqual(left.y, right.y, accuracy: 2, "sibling groups top-align")
        XCTAssertGreaterThan(packed.width, packed.height)
    }

    func testDisconnectedTDSubgraphsAreNotPacked() throws {
        // Packing is an LR/RL correction. A TD diagram must keep ELK's
        // placement even when its subgraphs have no edges between them.
        let source = """
            flowchart TD
              subgraph Top["Top"]
                T1[T1]
              end
              subgraph Bottom["Bottom"]
                B1[B1]
              end
            """
        let laidOut = try MermaidRenderer.layout(source)
        let packed = MermaidSubgraphPack.applied(to: laidOut)
        guard case .flowchart(_, _, let before) = laidOut.content,
            case .flowchart(_, _, let after) = packed.content,
            let topBefore = before.first(where: { $0.id == "Top" }),
            let topAfter = after.first(where: { $0.id == "Top" }),
            let bottomBefore = before.first(where: { $0.id == "Bottom" }),
            let bottomAfter = after.first(where: { $0.id == "Bottom" })
        else { return XCTFail("expected both subgraphs") }
        XCTAssertEqual(topBefore.x, topAfter.x, accuracy: 0.5)
        XCTAssertEqual(topBefore.y, topAfter.y, accuracy: 0.5)
        XCTAssertEqual(bottomBefore.x, bottomAfter.x, accuracy: 0.5)
        XCTAssertEqual(bottomBefore.y, bottomAfter.y, accuracy: 0.5)
    }

    func testLinkedSubgraphsKeepELKsPlacement() throws {
        let source = """
            flowchart LR
              subgraph Left["Left"]
                L1[L1]
              end
              subgraph Right["Right"]
                R1[R1]
              end
              L1 --> R1
            """
        let laidOut = try MermaidRenderer.layout(source)
        let packed = MermaidSubgraphPack.applied(to: laidOut)
        guard case .flowchart(_, _, let before) = laidOut.content,
            case .flowchart(_, _, let after) = packed.content,
            let leftBefore = before.first(where: { $0.id == "Left" }),
            let leftAfter = after.first(where: { $0.id == "Left" }),
            let rightBefore = before.first(where: { $0.id == "Right" }),
            let rightAfter = after.first(where: { $0.id == "Right" })
        else { return XCTFail("expected both subgraphs") }
        XCTAssertEqual(leftBefore.x, leftAfter.x, accuracy: 0.5)
        XCTAssertEqual(leftBefore.y, leftAfter.y, accuracy: 0.5)
        XCTAssertEqual(rightBefore.x, rightAfter.x, accuracy: 0.5)
        XCTAssertEqual(rightBefore.y, rightAfter.y, accuracy: 0.5)
    }

    func testTheGitPulseViewMapRendersAsAWideDiagram() {
        let renderer = RichContentRenderer()
        switch renderer.diagram(gitpulse, maxWidth: 900, dark: false) {
        case .success(let content):
            XCTAssertGreaterThan(content.size.width, 200)
            XCTAssertGreaterThan(content.size.height, 80)
            XCTAssertGreaterThan(
                content.size.width, content.size.height * 0.8,
                "flowchart LR should read as a wide map, not a stacked column")
        case .failure(let failure):
            XCTFail("the README view map should render: \(failure.reason)")
        }
    }

    /// Nested subgraphs, inner `direction`, HTML `<code>`/`<br/>` labels,
    /// a dotted edge, and edges that name a subgraph rather than a node.
    private let architecture = """
        flowchart TB
            subgraph Frontend["Svelte 5 + TypeScript Frontend"]
                direction TB
                UI["Views & Components<br/><code>src/lib/components/</code>"]
                Stores["State & Mutation Stores<br/><code>src/lib/stores/</code>"]
                Registry["View Registry & Routerless Nav<br/><code>src/lib/views/</code>"]
                Canvas["GPU-Accelerated Canvas<br/><code>src/lib/canvas/</code>"]
                Async["Async Guards & Debounce<br/><code>src/lib/async/</code>"]
                UI --> Stores
                UI --> Canvas
                Stores --> Async
                Registry --> UI
            end

            subgraph IPC["Tauri 2 IPC Seam (snake_case ↔ camelCase)"]
                direction TB
                Invoke["<code>invoke('cmd_*', args)</code>"]
                ContractCheck["Contract Enforced by <code>check:ipc</code>"]
                Invoke -.-> ContractCheck
            end

            subgraph Backend["Rust Backend (Tauri 2 / Rayon)"]
                direction TB
                CmdRegistry["Command Registry (132 Handlers)<br/><code>src-tauri/src/commands/</code>"]
                subgraph Subsystems["Core Subsystems"]
                    GitEngine["Git Engine & Sandbox<br/><code>src-tauri/src/engine/</code>"]
                    GraphSolver["Graph Solver & Nogap Bounds<br/><code>src-tauri/src/graph/</code>"]
                    Analyzers["Analyzers (LOC, Coverage, Health)<br/><code>src-tauri/src/analyzer/</code>"]
                    StorageAuditor["Storage Auditor & History<br/><code>src-tauri/src/storage/</code>"]
                    OpsPlanner["Ops Planner & Releases<br/><code>src-tauri/src/ops.rs</code>"]
                    PtyTerminal["PTY Lifecycle & Terminal<br/><code>src-tauri/src/terminal/</code>"]
                end
                CmdRegistry --> Subsystems
            end

            subgraph External["Local System & Sidecars"]
                direction TB
                LocalGit["<code>git</code> CLI"]
                LocalGh["<code>gh</code> CLI (GitHub)"]
                LocalLLM["Local LLMs (Ollama / LM Studio)"]
                ManviSidecar["MANVI Harness Sidecar<br/>(<code>manvi serve</code> via stdio)"]
            end

            Async --> Invoke
            Invoke --> CmdRegistry
            GitEngine --> LocalGit
            Analyzers --> LocalGit
            Analyzers --> LocalGh
            Analyzers --> LocalLLM
            OpsPlanner --> LocalGh
            OpsPlanner --> ManviSidecar
            Subsystems --> ManviSidecar
        """

    func testTheArchitectureMapParsesWithNestedSubgraphsAndNoHTML() throws {
        let graph = try MermaidRenderer.parse(MermaidHTML.sanitized(architecture))
        guard case .flowchart(let model) = graph.typedPayload else {
            return XCTFail("expected a flowchart")
        }
        XCTAssertGreaterThanOrEqual(model.nodesInOrder.count, 16)
        XCTAssertEqual(model.subgraphs.count, 4, "Frontend, IPC, Backend, External")
        XCTAssertEqual(
            model.subgraphs.first(where: { $0.id == "Backend" })?.children.count, 1,
            "Subsystems nests inside Backend")
        for (_, node) in model.nodesInOrder {
            XCTAssertFalse(node.label.contains("<"), node.label)
            XCTAssertFalse(node.label.isEmpty, node.id)
        }
    }

    func testAnEdgeToASubgraphStillRenders() {
        let source = """
            flowchart TB
              subgraph Outer["Outer"]
                A[A]
                subgraph Inner["Inner"]
                  B[B]
                end
                A --> Inner
              end
              Inner --> C[C]
            """
        switch RichContentRenderer().diagram(source, maxWidth: 700, dark: false) {
        case .success(let content):
            XCTAssertGreaterThan(content.size.width, 40)
            XCTAssertGreaterThan(content.size.height, 40)
        case .failure(let failure):
            XCTFail("an edge that names a subgraph should still draw: \(failure.reason)")
        }
    }

    func testTheArchitectureMapRendersAsATallStack() {
        switch RichContentRenderer().diagram(architecture, maxWidth: 900, dark: false) {
        case .success(let content):
            XCTAssertGreaterThan(content.size.width, 120)
            XCTAssertGreaterThan(content.size.height, 200)
            XCTAssertGreaterThan(
                content.size.height, content.size.width * 0.5,
                "flowchart TB should read as a stack, not a single row")
        case .failure(let failure):
            XCTFail("the architecture map should render: \(failure.reason)")
        }
    }

    func testATaggedLabelDoesNotWidenTheNodeByItsMarkup() throws {
        // The library sizes nodes from the label string. Leaving `<b></b>` in
        // the source makes the box as wide as the tags, which is how a README
        // map looked padded and wrong even when it parsed.
        let tagged = try MermaidRenderer.layout(
            MermaidHTML.sanitized("flowchart LR\n  A[\"<b>XXXX</b>\"]\n"))
        let plain = try MermaidRenderer.layout("flowchart LR\n  A[\"XXXX\"]\n")
        guard case .flowchart(let taggedNodes, _, _) = tagged.content,
            case .flowchart(let plainNodes, _, _) = plain.content,
            let taggedNode = taggedNodes.first,
            let plainNode = plainNodes.first
        else { return XCTFail("expected a node in each graph") }
        XCTAssertEqual(taggedNode.width, plainNode.width, accuracy: 2)
    }
}
