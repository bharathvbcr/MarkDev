//! The vault graph: what it includes, and where it puts it.

use markdev::vault::{Graph, GraphQuery, Note, Vault};
use std::path::PathBuf;

fn vault(notes: &[(&str, &str)]) -> Vault {
    Vault::build(
        PathBuf::from("/vault"),
        notes
            .iter()
            .map(|(path, source)| Note::parse((*path).to_string(), source))
            .collect(),
    )
}

fn whole(vault: &Vault) -> Graph {
    Graph::build(vault, &GraphQuery::default())
}

fn paths(graph: &Graph) -> Vec<&str> {
    graph.nodes.iter().map(|node| node.path.as_str()).collect()
}

/// Whether the graph has an edge between two paths, in either direction.
fn linked(graph: &Graph, a: &str, b: &str) -> bool {
    let index = |path: &str| {
        graph
            .nodes
            .iter()
            .position(|node| node.path == path)
            .map(|i| i as u32)
    };
    let (Some(a), Some(b)) = (index(a), index(b)) else {
        return false;
    };
    graph
        .edges
        .iter()
        .any(|edge| (edge.source, edge.target) == (a, b) || (edge.source, edge.target) == (b, a))
}

// ---------------------------------------------------------------------------
// Structure
// ---------------------------------------------------------------------------

#[test]
fn resolved_links_become_edges() {
    let vault = vault(&[
        ("A.md", "# A\n\nSee [[B]].\n"),
        ("B.md", "# B\n\nBack to [[A]].\n"),
    ]);
    let graph = whole(&vault);

    assert_eq!(paths(&graph), vec!["A.md", "B.md"]);
    assert!(linked(&graph, "A.md", "B.md"));
    // One edge, not two: a mutual link is one relationship, and drawing it
    // twice doubles the attraction force between the pair.
    assert_eq!(graph.edges.len(), 1);
}

#[test]
fn broken_links_do_not_produce_edges() {
    // There is no node to point at. The link is not lost — `broken_links`
    // still reports it — but an edge to a note that does not exist would have
    // to be drawn somewhere, and any answer is wrong.
    let vault = vault(&[("A.md", "[[Nowhere]]\n")]);
    let graph = whole(&vault);

    assert_eq!(paths(&graph), vec!["A.md"]);
    assert!(graph.edges.is_empty());
    assert_eq!(graph.nodes[0].degree, 0);
}

#[test]
fn a_note_linking_to_itself_is_not_an_edge() {
    // A self-loop has zero length, so the layout divides by its own distance.
    let vault = vault(&[("A.md", "# A\n\n[[A]]\n")]);
    let graph = whole(&vault);

    assert!(graph.edges.is_empty());
    assert!(graph.nodes[0].x.is_finite());
}

#[test]
fn degree_counts_both_directions() {
    let vault = vault(&[
        ("Hub.md", "[[One]] [[Two]]\n"),
        ("One.md", "x\n"),
        ("Two.md", "[[Hub]]\n"),
    ]);
    let graph = whole(&vault);

    let hub = graph.nodes.iter().find(|n| n.path == "Hub.md").unwrap();
    let one = graph.nodes.iter().find(|n| n.path == "One.md").unwrap();
    assert_eq!(hub.degree, 2, "a hub must read as a hub");
    assert_eq!(one.degree, 1, "an inbound link counts too");
}

#[test]
fn an_isolated_note_still_appears() {
    // Dropping unlinked notes would make a fresh vault look empty, which is
    // exactly when someone opens the graph to see what they have.
    let vault = vault(&[("Alone.md", "Nothing here.\n")]);
    let graph = whole(&vault);

    assert_eq!(paths(&graph), vec!["Alone.md"]);
    assert!(graph.nodes[0].x.is_finite() && graph.nodes[0].y.is_finite());
}

#[test]
fn an_empty_vault_lays_out_without_panicking() {
    let graph = whole(&vault(&[]));
    assert!(graph.nodes.is_empty());
    assert!(graph.edges.is_empty());
    assert_eq!(graph.total_notes, 0);
}

// ---------------------------------------------------------------------------
// Local view
// ---------------------------------------------------------------------------

#[test]
fn a_local_graph_walks_the_requested_number_of_hops() {
    let vault = vault(&[
        ("A.md", "[[B]]\n"),
        ("B.md", "[[C]]\n"),
        ("C.md", "[[D]]\n"),
        ("D.md", "end\n"),
    ]);

    let one = Graph::build(
        &vault,
        &GraphQuery {
            focus: Some("A.md"),
            depth: 1,
            ..Default::default()
        },
    );
    assert_eq!(paths(&one), vec!["A.md", "B.md"]);

    let two = Graph::build(
        &vault,
        &GraphQuery {
            focus: Some("A.md"),
            depth: 2,
            ..Default::default()
        },
    );
    assert_eq!(paths(&two), vec!["A.md", "B.md", "C.md"]);
}

#[test]
fn hops_are_counted_breadth_first() {
    // A note reachable both directly and by a longer path must record the
    // short distance, or a depth-1 view would miss it.
    let vault = vault(&[
        ("A.md", "[[B]] [[C]]\n"),
        ("B.md", "[[C]]\n"),
        ("C.md", "end\n"),
    ]);
    let graph = Graph::build(
        &vault,
        &GraphQuery {
            focus: Some("A.md"),
            depth: 1,
            ..Default::default()
        },
    );

    let c = graph.nodes.iter().find(|n| n.path == "C.md").unwrap();
    assert_eq!(c.depth, 1);
}

#[test]
fn a_local_graph_follows_links_in_both_directions() {
    // "Notes near this one" means neighbours, not descendants — a note that
    // links *to* the focus is as related as one it links out to.
    let vault = vault(&[("A.md", "no links\n"), ("B.md", "[[A]]\n")]);
    let graph = Graph::build(
        &vault,
        &GraphQuery {
            focus: Some("A.md"),
            depth: 1,
            ..Default::default()
        },
    );

    assert_eq!(paths(&graph), vec!["A.md", "B.md"]);
}

#[test]
fn a_focus_that_does_not_exist_yields_an_empty_graph() {
    let vault = vault(&[("A.md", "x\n")]);
    let graph = Graph::build(
        &vault,
        &GraphQuery {
            focus: Some("Gone.md"),
            depth: 2,
            ..Default::default()
        },
    );

    assert!(graph.nodes.is_empty());
    // The count is still honest about the vault behind the empty view.
    assert_eq!(graph.total_notes, 1);
}

#[test]
fn a_focus_may_be_named_the_way_a_wikilink_names_it() {
    // The inspector knows a note by the same name a link uses. Requiring a
    // vault-relative path here would mean the graph could not be opened from
    // the place that has the name.
    let vault = vault(&[("folder/Target.md", "# Target\n"), ("A.md", "[[Target]]\n")]);
    let graph = Graph::build(
        &vault,
        &GraphQuery {
            focus: Some("Target"),
            depth: 1,
            ..Default::default()
        },
    );

    assert_eq!(paths(&graph), vec!["A.md", "folder/Target.md"]);
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

#[test]
fn a_tag_filter_keeps_only_tagged_notes() {
    let vault = vault(&[
        ("A.md", "#project\n\n[[B]]\n"),
        ("B.md", "no tag\n"),
        ("C.md", "#Project\n"),
    ]);
    let graph = Graph::build(
        &vault,
        &GraphQuery {
            tag: Some("project"),
            ..Default::default()
        },
    );

    // Case-insensitive, and a leading `#` is optional — the tag browser shows
    // them with one and the filter field is typed without.
    assert_eq!(paths(&graph), vec!["A.md", "C.md"]);
    assert!(
        graph.edges.is_empty(),
        "B is filtered out, so its edge goes"
    );
}

#[test]
fn a_folder_filter_compares_path_components() {
    // `/Notes-copy/x.md` has `Notes` as a string prefix but is not inside it.
    let vault = vault(&[
        ("Notes/One.md", "x\n"),
        ("Notes-copy/Two.md", "x\n"),
        ("Three.md", "x\n"),
    ]);
    let graph = Graph::build(
        &vault,
        &GraphQuery {
            folder: Some("Notes"),
            ..Default::default()
        },
    );

    assert_eq!(paths(&graph), vec!["Notes/One.md"]);
}

#[test]
fn degree_reflects_the_whole_vault_not_the_filtered_view() {
    // A note's importance does not change because the reader narrowed the
    // view; showing it shrunk to a leaf would misrepresent the vault.
    let vault = vault(&[
        ("Hub.md", "#keep\n\n[[One]] [[Two]]\n"),
        ("One.md", "x\n"),
        ("Two.md", "x\n"),
    ]);
    let graph = Graph::build(
        &vault,
        &GraphQuery {
            tag: Some("keep"),
            ..Default::default()
        },
    );

    assert_eq!(paths(&graph), vec!["Hub.md"]);
    assert_eq!(graph.nodes[0].degree, 2);
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

#[test]
fn the_same_vault_always_lays_out_the_same_way() {
    // Random seeding would rearrange the graph every time the panel opened,
    // which reads as the graph being unstable rather than unseeded.
    let notes: Vec<(&str, &str)> = vec![
        ("A.md", "[[B]] [[C]]\n"),
        ("B.md", "[[C]]\n"),
        ("C.md", "[[D]]\n"),
        ("D.md", "x\n"),
    ];
    let first = whole(&vault(&notes));
    let second = whole(&vault(&notes));

    assert_eq!(first, second);
}

#[test]
fn nodes_do_not_land_on_top_of_each_other() {
    let vault = vault(&[
        ("A.md", "[[B]]\n"),
        ("B.md", "[[C]]\n"),
        ("C.md", "[[A]]\n"),
        ("D.md", "unlinked\n"),
        ("E.md", "unlinked\n"),
    ]);
    let graph = whole(&vault);

    for i in 0..graph.nodes.len() {
        for j in (i + 1)..graph.nodes.len() {
            let dx = graph.nodes[i].x - graph.nodes[j].x;
            let dy = graph.nodes[i].y - graph.nodes[j].y;
            let distance = (dx * dx + dy * dy).sqrt();
            assert!(
                distance > 1.0,
                "{} and {} overlap at {distance}",
                graph.nodes[i].path,
                graph.nodes[j].path
            );
        }
    }
}

#[test]
fn linked_notes_settle_closer_than_unlinked_ones() {
    // The entire point of a force-directed layout. If this does not hold, the
    // picture carries no information the file list does not.
    let vault = vault(&[
        ("A.md", "[[B]]\n"),
        ("B.md", "[[A]]\n"),
        ("Far1.md", "x\n"),
        ("Far2.md", "x\n"),
        ("Far3.md", "x\n"),
        ("Far4.md", "x\n"),
    ]);
    let graph = whole(&vault);

    let at = |path: &str| {
        let node = graph.nodes.iter().find(|n| n.path == path).unwrap();
        (node.x, node.y)
    };
    let distance =
        |a: (f32, f32), b: (f32, f32)| ((a.0 - b.0).powi(2) + (a.1 - b.1).powi(2)).sqrt();

    let linked_distance = distance(at("A.md"), at("B.md"));
    let unlinked_distance = distance(at("Far1.md"), at("Far3.md"));
    assert!(
        linked_distance < unlinked_distance,
        "linked {linked_distance} should be closer than unlinked {unlinked_distance}"
    );
}

#[test]
fn every_coordinate_lands_inside_the_canvas() {
    let vault = vault(&[
        ("A.md", "[[B]] [[C]] [[D]]\n"),
        ("B.md", "[[C]]\n"),
        ("C.md", "x\n"),
        ("D.md", "x\n"),
    ]);
    let graph = whole(&vault);

    for node in &graph.nodes {
        assert!(node.x.is_finite() && node.y.is_finite(), "{node:?}");
        assert!((0.0..=1000.0).contains(&node.x), "{node:?}");
        assert!((0.0..=1000.0).contains(&node.y), "{node:?}");
    }
}

#[test]
fn a_single_note_sits_in_the_middle() {
    let graph = whole(&vault(&[("Only.md", "x\n")]));
    assert_eq!((graph.nodes[0].x, graph.nodes[0].y), (500.0, 500.0));
}

#[test]
fn a_chain_is_not_stretched_to_fill_the_canvas() {
    // Scaling each axis independently would smear a line of notes across the
    // whole panel, which reads as a layout bug rather than as a chain.
    let vault = vault(&[
        ("A.md", "[[B]]\n"),
        ("B.md", "[[C]]\n"),
        ("C.md", "[[D]]\n"),
        ("D.md", "x\n"),
    ]);
    let graph = whole(&vault);

    let width = graph.nodes.iter().map(|n| n.x).fold(f32::MIN, f32::max)
        - graph.nodes.iter().map(|n| n.x).fold(f32::MAX, f32::min);
    let height = graph.nodes.iter().map(|n| n.y).fold(f32::MIN, f32::max)
        - graph.nodes.iter().map(|n| n.y).fold(f32::MAX, f32::min);

    // A chain is longer than it is thick; one axis must not have been
    // stretched to match the other.
    assert!(
        (width - height).abs() > 1.0,
        "aspect ratio was not preserved: {width} x {height}"
    );
}

// ---------------------------------------------------------------------------
// Bounds
// ---------------------------------------------------------------------------

#[test]
fn an_oversized_vault_is_capped_and_says_so() {
    // Never present a capped sample as complete coverage: the node count and
    // the vault count are both reported, and `truncated` distinguishes "you
    // filtered this" from "we could not draw it all".
    let sources: Vec<String> = (0..markdev::vault::graph::MAX_NODES + 50)
        .map(|i| format!("# Note {i}\n"))
        .collect();
    let names: Vec<String> = (0..sources.len()).map(|i| format!("N{i}.md")).collect();
    let notes: Vec<(&str, &str)> = names
        .iter()
        .zip(sources.iter())
        .map(|(name, source)| (name.as_str(), source.as_str()))
        .collect();

    let graph = whole(&vault(&notes));

    assert_eq!(graph.nodes.len(), markdev::vault::graph::MAX_NODES);
    assert_eq!(graph.total_notes, notes.len() as u32);
    assert!(graph.truncated);
}

#[test]
fn a_graph_that_fits_is_not_marked_truncated() {
    let graph = whole(&vault(&[("A.md", "x\n")]));
    assert!(!graph.truncated);
    assert_eq!(graph.total_notes, 1);
}

#[test]
fn a_filtered_graph_is_not_marked_truncated() {
    // Filtering is the reader's own choice; flagging it as truncation would
    // cry wolf on every use of the tag filter.
    let vault = vault(&[("A.md", "#keep\n"), ("B.md", "x\n")]);
    let graph = Graph::build(
        &vault,
        &GraphQuery {
            tag: Some("keep"),
            ..Default::default()
        },
    );

    assert_eq!(graph.nodes.len(), 1);
    assert_eq!(graph.total_notes, 2);
    assert!(!graph.truncated);
}
