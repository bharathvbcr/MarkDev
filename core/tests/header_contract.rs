//! Every constant in the generated header must be one Swift can actually see.
//!
//! `cbindgen` turns a `pub const` into a `#define`, and Swift's ClangImporter
//! accepts only a narrow grammar of macro values. Anything outside it is not
//! an error and not a warning: the macro is simply *absent* from the Swift
//! module. The build then fails hundreds of lines away with `cannot find
//! 'MDMAX_DOCUMENT_BYTES' in scope`, which reads like a stale header or a
//! broken module map rather than what it is — a constant written with one
//! pair of parentheses too many.
//!
//! That had already happened here. Five constants were spelled `N * 1024 *
//! 1024`, which Rust parses as `(N * 1024) * 1024` and cbindgen emits as
//! `((N * 1024) * 1024)`. Two of them were referenced from Swift and broke the
//! build; the other three were latent, waiting for their first caller.
//!
//! The accepted grammar below was measured against `swiftc`, not assumed. The
//! compiler's own diagnostic for a rejected macro is
//! `note: macro 'X' unavailable: structure not supported`:
//!
//! | Value                  | Imports |
//! |------------------------|---------|
//! | `16777216`             | yes     |
//! | `(4 * 1024)`           | yes     |
//! | `(1 << 24)`            | yes     |
//! | `UINT32_MAX`           | yes     |
//! | `(16 * 1024 * 1024)`   | **no**  |
//! | `((16 * 1024) * 1024)` | **no**  |
//!
//! So: a literal, a bare identifier, or exactly one binary operation between
//! two literals. Three operands is already too many, flat or not.

use std::fs;
use std::path::PathBuf;

/// Constants deliberately not exposed to Swift.
///
/// `MDTABLE_ALIGNMENT_MASK` is `((1 << MDTABLE_ALIGNMENT_BITS) - 1)`, which
/// cannot be written in the importable grammar at all — it is a derivation,
/// not a value. Swift derives its own from `MDTABLE_ALIGNMENT_BITS`, which is
/// a bare literal and does import; `ParsedDocumentTests` pins the two against
/// each other so the duplication cannot drift.
const NOT_EXPOSED_TO_SWIFT: &[&str] = &["MDTABLE_ALIGNMENT_MASK"];

fn header() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("include")
        .join("markdev.h");
    fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "cannot read the generated header at {}: {e}",
            path.display()
        )
    })
}

/// Whether a token is a literal Swift will evaluate.
fn is_literal(token: &str) -> bool {
    let token = token.trim();
    if token.is_empty() {
        return false;
    }
    if let Some(hex) = token
        .strip_prefix("0x")
        .or_else(|| token.strip_prefix("0X"))
    {
        return !hex.is_empty() && hex.chars().all(|c| c.is_ascii_hexdigit());
    }
    token.chars().all(|c| c.is_ascii_digit())
}

/// Whether a token is a bare identifier, such as `UINT32_MAX`.
fn is_identifier(token: &str) -> bool {
    let token = token.trim();
    !token.is_empty()
        && token.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && !token.starts_with(|c: char| c.is_ascii_digit())
}

/// Whether Swift's ClangImporter will expose a macro with this value.
fn is_swift_importable(value: &str) -> bool {
    let value = value.trim();
    if is_literal(value) || is_identifier(value) {
        return true;
    }

    // Exactly one parenthesised binary operation over two literals.
    let Some(inner) = value.strip_prefix('(').and_then(|v| v.strip_suffix(')')) else {
        return false;
    };
    if inner.contains('(') || inner.contains(')') {
        return false;
    }
    for op in ["<<", ">>", "*", "/", "+", "-", "|", "&"] {
        if let Some((left, right)) = inner.split_once(op) {
            // A second operator means a third operand, which is out of grammar
            // whether or not it is parenthesised.
            if is_literal(left) && is_literal(right) {
                return true;
            }
        }
    }
    false
}

/// Each `#define MD…` in the header, as (name, value).
fn defined_constants(header: &str) -> Vec<(String, String)> {
    header
        .lines()
        .filter_map(|line| {
            let rest = line.strip_prefix("#define MD")?;
            let (name, value) = rest.split_once(char::is_whitespace)?;
            let value = value.trim();
            if value.is_empty() {
                return None;
            }
            Some((format!("MD{name}"), value.to_string()))
        })
        .collect()
}

#[test]
fn the_importable_grammar_matches_what_swiftc_accepts() {
    // Measured against swiftc, and the reason this file can be trusted.
    for accepted in [
        "16777216",
        "0xFF",
        "(4 * 1024)",
        "(1 << 24)",
        "UINT32_MAX",
        "(16 * 1048576)",
    ] {
        assert!(is_swift_importable(accepted), "{accepted} should import");
    }
    for refused in [
        "(16 * 1024 * 1024)",
        "((16 * 1024) * 1024)",
        "((1 << MDTABLE_ALIGNMENT_BITS) - 1)",
        "(1 + 2 + 3)",
    ] {
        assert!(!is_swift_importable(refused), "{refused} should not import");
    }
}

#[test]
fn every_generated_constant_is_visible_to_swift() {
    let header = header();
    let constants = defined_constants(&header);
    assert!(
        constants.len() > 10,
        "only {} constants found — the header parse is wrong, not the header",
        constants.len()
    );

    let broken: Vec<_> = constants
        .iter()
        .filter(|(name, _)| !NOT_EXPOSED_TO_SWIFT.contains(&name.as_str()))
        .filter(|(_, value)| !is_swift_importable(value))
        .collect();

    assert!(
        broken.is_empty(),
        "these constants are invisible to Swift — the app will fail to build with \
         `cannot find '<name>' in scope`, far from the cause:\n{}\n\n\
         Write the value as a literal or a single binary operation between two \
         literals: `16 * 1_048_576`, not `16 * 1024 * 1024`.",
        broken
            .iter()
            .map(|(name, value)| format!("  {name} = {value}"))
            .collect::<Vec<_>>()
            .join("\n")
    );
}

#[test]
fn the_exemption_list_names_only_constants_that_still_exist() {
    let header = header();
    let names: Vec<String> = defined_constants(&header)
        .into_iter()
        .map(|(name, _)| name)
        .collect();
    for exempt in NOT_EXPOSED_TO_SWIFT {
        assert!(
            names.iter().any(|name| name == exempt),
            "{exempt} is exempted but no longer generated; drop it from the list"
        );
    }
}
