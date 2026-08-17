# Contributing to MarkDev

Thank you for your interest in contributing to MarkDev! 

MarkDev is a high-performance, native macOS Markdown editor and knowledge vault built with **Swift + Rust**. We care deeply about native Mac app polish, sub-frame editing performance, and rock-solid reliability.

---

## Code of Conduct

All contributors and participants agree to abide by the [Contributor Covenant Code of Conduct](./CODE_OF_CONDUCT.md). Please read it before participating.

---

## Architectural Invariants

Before proposing or implementing changes, you must understand MarkDev's core design rules and invariants:

1. **Zero Web Stack**: MarkDev is strictly native. We do not use WebViews, Electron, or browser-based rendering for any core feature (Markdown, Math, Diagrams, or Terminal).
2. **UTF-16 Offsets Across FFI**: All string offsets crossing the Rust/Swift FFI boundary are **UTF-16 code units**, converted on the Rust side via `Utf16Mapper`. `NSTextStorage` indexes by UTF-16; passing byte offsets will cause subtle corruption with non-ASCII text and emojis.
3. **Derived Syntax Markers**: Syntax markers are derived structurally (any part of a construct's range not covered by its children). Never hand-code ad-hoc string search for markers without checking if the structural gap rule already covers it.
4. **Markers Shrink; Never Erased from Buffer**: Syntax markers (`**`, `*`, `#`, etc.) are styled with `EditorTheme.hiddenMarkerFontSize` (0.01pt) when collapsed. They must never be deleted from `NSTextStorage`. This guarantees native ⌘C copy, find, undo, and selection always operate on raw Markdown.
5. **Pure Value-Type Layouts**: Geometries such as `SplitLayout` are pure value types with 100% deterministic unit tests. Clamping and divider logic lives in the model, never scattered inside SwiftUI view gestures.
6. **Rebuild Over Patching for Vault Graph**: Vault link updates rebuild the local graph rather than applying partial delta patches. At personal vault scale (~10k notes), a complete Rust rebuild takes microseconds and eliminates stale edge bugs.
7. **No Remote Image Loads**: Opening a note must never trigger arbitrary network requests. All image resolution is strictly local to the vault filesystem.
8. **Code-Defined Brand Geometry**: The app and document icons are rendered directly from `MarkDevLogo.swift` via `tools/icongen`. Never check in manual PNG or `.imageset` files.

---

## Development Setup

### Prerequisites

1. **macOS 15.0+**
2. **Xcode 16.0+**
3. **Rust 1.80+** (`rustup default stable`)
4. **Command Tools**:
   ```bash
   brew install just xcodegen
   ```

### Building the Project

We use `just` recipes to ensure that the Rust static library is compiled before Xcode targets link against it:

```bash
# Debug build (generates project and compiles Rust + Swift)
just build

# Launch the app locally
just run

# Re-generate Xcode project from project.yml
just generate
```

> [!WARNING]
> Never edit `MarkDev.xcodeproj` directly in Xcode. It is generated from `project.yml` by `xcodegen`. Any manual project edits will be overwritten on the next `just generate`.

---

## Testing & Quality Assurance

Every contribution must pass our automated quality and performance gates.

```bash
# Run all tests (Rust + Swift)
just test

# Run Rust formatting, clippy, and all tests
just check
```

### Running Test Suites Individually

- **Rust Unit & Integration Tests**:
  ```bash
  cd core && cargo test
  ```
- **Rust Property Tests (Incremental Parser)**:
  ```bash
  cd core && cargo test --test incremental
  ```
- **Rust Performance Benchmarks**:
  ```bash
  cd core && cargo test --release --test performance
  ```
- **Swift Unit & UI Tests**:
  ```bash
  xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Debug test
  ```

### Performance Regression Policy

MarkDev enforces strict frame budgets. All changes affecting parsing, text layout, or typing must be measured against the benchmarks:

- **Parser Release Gate**: 10,000 lines must parse in under 16.6ms (`cargo test --release --test performance`). Current benchmark: **~2.55ms**.
- **Editor Keystroke Gate**: Editor restyling per keystroke must stay under 16.6ms (`EditorPerformanceTests`).

---

## Pull Request Guidelines

1. **Search Existing Issues/PRs**: Before starting non-trivial work, please open an issue or search existing discussions to align on design and approach.
2. **Fix the Class, Not the Case**: Address the root cause at the canonical owner instead of adding special-case branching for single inputs.
3. **Every Fix Ships With a Test**: Include tests that fail on unmodified code and pass with your fix.
4. **Strict Concurrency**: Swift code must build cleanly with Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`).
5. **No Placeholders**: Avoid shipping `TODO`s, fake stub return values, or commented-out code.
6. **No Unapproved Dependencies**: Do not introduce new third-party dependencies (Rust crates or Swift packages) without prior discussion.

---

## Coding Standards

### Rust (`core/`)
- Format code with `cargo fmt`.
- Ensure all lints pass with `cargo clippy --all-targets -- -D warnings`.
- If modifying FFI declarations in `core/src/ffi.rs`, update `cbindgen` bindings via `just header`.

### Swift (`app/`)
- Follow Apple's official Swift API Design Guidelines.
- Keep views light and business logic isolated in models or view models.
- Ensure all public FFI wrappers enforce thread safety and actors appropriately.
