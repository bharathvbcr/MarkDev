# Contributing to MarkDev

Thank you for your interest in contributing to MarkDev! 

MarkDev is a high-performance, native macOS Markdown editor and knowledge vault built with **Swift + Rust**. We care deeply about native Mac app polish, sub-frame editing performance, and rock-solid reliability.

**Product stack.** DevCouncil is components and modules. Manvi wraps them. GitPulse uses Manvi and selected DevCouncil components for their respective jobs. MarkDev is a selectable-module host of the same kind: Cargo features on `core/`, and Manvi from Assist without the rest of DevCouncil.

---

## Code of Conduct

All contributors and participants agree to abide by the [Contributor Covenant Code of Conduct](./CODE_OF_CONDUCT.md). Please read it before participating.

---

## Architectural Invariants

Before proposing or implementing changes, you must understand MarkDev's core design rules and invariants:

1. **Native app runtime**: MarkDev.app is strictly native. We do not use WebViews, Electron, or browser-based rendering for any core feature (Markdown, Math, Diagrams, or Terminal). The standalone product website is outside the app runtime.
2. **UTF-16 Offsets Across FFI**: All string offsets crossing the Rust/Swift FFI boundary are **UTF-16 code units**, converted on the Rust side via `Utf16Mapper`. `NSTextStorage` indexes by UTF-16; passing byte offsets will cause subtle corruption with non-ASCII text and emojis.
3. **Derived Syntax Markers**: Syntax markers are derived structurally (any part of a construct's range not covered by its children). Never hand-code ad-hoc string search for markers without checking if the structural gap rule already covers it.
4. **Markers Shrink; Never Erased from Buffer**: Syntax markers (`**`, `*`, `#`, etc.) are styled with `EditorTheme.hiddenMarkerFontSize` (0.01pt) when collapsed. They must never be deleted from `NSTextStorage`. This guarantees native ⌘C copy, find, undo, and selection always operate on raw Markdown.
5. **Pure Value-Type Layouts**: Geometries such as `SplitLayout` are pure value types with deterministic unit tests. Clamping and divider logic lives in the model, never scattered inside SwiftUI view gestures.
6. **Rebuild Over Patching for Vault Graph**: Vault link updates rebuild the local graph rather than applying partial delta patches. Rebuilding derived indexes prevents separately maintained edge state from drifting; do not state a fixed rebuild duration without a reproducible measurement.
7. **No Remote Image Loads**: Opening a note must never trigger arbitrary network requests. All image resolution is strictly local to the vault filesystem.
8. **Code-Defined Brand Geometry**: The app and document icons are rendered directly from `MarkDevLogo.swift` via `tools/icongen`. Never check in manual PNG or `.imageset` files.
9. **Bounded and typed diagnostics first**: emit only through `DiagnosticsEmitter`, with bounded queues and typed event metadata. Do not use diagnostics as control flow.
10. **Assisted edit safety**: any model-assisted replacement must validate source identity and document generation before mutating text.

---

## Development Setup

### Prerequisites

1. **macOS 26.0+**
2. **Xcode 27.0 (build 27A266a)**: the repository verifies this exact release
   for release builds rather than accepting any Xcode 26 installation. The
   pull-request CI job temporarily pins Xcode 26.6 (build 17F113) through
   `MARKDEV_CI_XCODE_VERSION`/`MARKDEV_CI_XCODE_BUILD`, because GitHub's
   `macos-26` runners do not carry Xcode 27.0 yet.
3. **Rust 1.98.0**: the root `rust-toolchain.toml` selects the exact toolchain,
   components, and universal macOS targets without changing your global Rust
   default.
4. **Command Tools**: Just 1.58.0 and XcodeGen 2.45.4 are required. Release
   publication additionally requires `gh 2.95.0`. CI obtains the audited
   binaries with `tools/ci/install-pinned-tools.sh release`; local contributors
   must put those exact versions on `PATH` and run `just verify-toolchain` (or
   `just verify-release-toolchain` before publishing).

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
  cd core && cargo test --locked
  ```
- **Rust Property Tests (Incremental Parser)**:
  ```bash
  cd core && cargo test --locked --test incremental
  ```
- **Rust Performance Benchmarks**:
  ```bash
  cd core && cargo test --locked --release --test performance
  ```
- **Swift Application and Framework Unit Tests**:
  ```bash
  just test-app
  ```

### Performance Regression Policy

MarkDev distinguishes interaction targets from the thresholds enforced in CI. All changes affecting parsing, text layout, or typing must be measured against the benchmarks:

- **Parser Release Gate**: 10,000 lines must parse in under 16.6ms (`cargo test --locked --release --test performance`). Historical local sample: **~2.55ms**, not a measurement from the current checkout.
- **Editor Keystroke Target**: One 60fps frame is 16.6ms; the current Debug test gate is `< 50ms` (`EditorPerformanceTests`).

---

## Pull Request Guidelines

1. **Search Existing Issues/PRs**: Before starting non-trivial work, please open an issue or search existing discussions to align on design and approach.
2. **Fix the Class, Not the Case**: Address the root cause at the canonical owner instead of adding special-case branching for single inputs.
3. **Every Fix Ships With a Test**: Include tests that fail on unmodified code and pass with your fix.
4. **Strict Concurrency**: Honor the language settings in `project.yml`: `SWIFT_VERSION: "5.0"` and `SWIFT_STRICT_CONCURRENCY: complete`.
5. **No Placeholders**: Avoid shipping `TODO`s, fake stub return values, or commented-out code.
6. **No Unapproved Dependencies**: Do not introduce new third-party dependencies (Rust crates or Swift packages) without prior discussion.

---

## Coding Standards

### Rust (`core/`)
- Format code with `cargo fmt`.
- Ensure all lints pass with `cargo clippy --locked --all-targets -- -D warnings`.
- If modifying FFI declarations in `core/src/ffi.rs`, update `cbindgen` bindings via `just header`.

### Swift (`app/`)
- Follow Apple's official Swift API Design Guidelines.
- Keep views light and business logic isolated in models or view models.
- Ensure all public FFI wrappers enforce thread safety and actors appropriately.

## Documentation and website changes

Use the [documentation index](docs/README.md) to find the canonical guide for
each behavior. Keep the README concise and link to detailed contracts. Verify
menu names, supported syntax, settings, and release claims against source and
actual artifacts. Preserve historical release context.

Run `just check-docs` for prose/site edits. Preview the website at desktop and
mobile widths; exercise its controls with keyboard input and with JavaScript
disabled. App suites are required when app behavior changes; a documentation-only
pass should report that those suites were not run. See [website maintenance](website/README.md).
