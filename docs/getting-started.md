# Getting Started with MarkDev

This guide explains how to set up your local development environment, build MarkDev from source, run tests, and troubleshoot common environment quirks.

---

## Prerequisites

Before building MarkDev, ensure your development machine has the following tools installed:

1. **macOS**: macOS 26.0 or later (Liquid Glass APIs are required for the full theme stack).
2. **Xcode**: Xcode 26.6, build 17F113 (full installation from the Mac App Store or Apple Developer portal, not just Command Line Tools).
3. **Rust Toolchain**: Rust 1.98.0 (managed via `rustup`):
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   rustup toolchain install 1.98.0 --profile minimal \
     --component rustfmt --component clippy \
     --target aarch64-apple-darwin --target x86_64-apple-darwin
   rustup show active-toolchain
   ```
   Run the final command from MarkDev's repository root. The checked-in
   `rust-toolchain.toml` selects the repository toolchain without mutating your
   global Rust default.
4. **Build Tools**: CI and release validation require `just` 1.58.0 and
   XcodeGen 2.45.4. Release publication additionally requires `gh 2.95.0`.

Install XcodeGen from its official
[2.45.4 release archive](https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip).
Verify its SHA-256 as
`090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef`
before placing the archive's `xcodegen/bin` directory on `PATH`. CI performs
that download, checksum, layout, executable, and version validation itself.

Homebrew formulas are moving inputs rather than versioned lockfiles. The build
therefore verifies exact tool versions and stops if an input has moved. Update
the pins deliberately instead of weakening the check to accept an arbitrary
newer tool.

---

## Building the Project

MarkDev contains both a Rust static library (`core/`) and a native Swift application (`app/`). The Rust core must be compiled first so that Xcode can link against `libmarkdev.a`.

### Debug Build & Run

To build both the Rust core and the macOS application in debug configuration, run:

```bash
just build
```

To launch the app directly:

```bash
just run
```

### Release Build

To produce an optimized universal (`arm64` + `x86_64`) Release build with
Link-Time Optimization (LTO), including `pulldown-cmark`'s runtime-detected
SSSE3 scanner in the `x86_64` slice and its scalar scanner in the `arm64`
slice:

```bash
just build-release
```

---

## Project Structure & XcodeGen

`MarkDev.xcodeproj` is **generated** from [`project.yml`](../project.yml) using `xcodegen`.

> [!IMPORTANT]
> **Do not edit `MarkDev.xcodeproj` directly in Xcode.**
> Any changes made directly to the `.xcodeproj` file will be permanently overwritten when `just generate` runs. Always modify `project.yml` and regenerate the project:
> ```bash
> just generate
> ```

Whenever you add new Swift files, resources, or dependency packages, run `just generate` so Xcode recognizes the updated file list.

### Swift package lock

`project.yml` pins MarkDev's direct Swift packages to exact versions. XcodeGen
preserves an existing
`MarkDev.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`,
but it does not resolve packages or recreate a missing lock. For an approved
dependency change, update `project.yml`, regenerate the project, and explicitly
refresh the lock:

```bash
just generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MarkDev.xcodeproj -scheme MarkDev \
  -resolvePackageDependencies
```

Review the lock diff and commit both authoritative inputs together.
MarkDev-owned build, test, and settings recipes pass
`-onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates`, so ordinary
validation fails on a missing or stale lock instead of silently resolving a
different graph. The explicit resolution command above is an update workflow,
not a validation command.

### CI and release toolchain lock

CI actions are referenced by reviewed commit SHA rather than mutable major or
branch labels. CI selects Rust 1.98.0 explicitly, and `just
verify-core-toolchain` checks the exact Rust, Cargo, and Just builds. `just
verify-toolchain` additionally checks XcodeGen 2.45.4 and Xcode 26.6 build
17F113. Release builds depend on that complete verifier, so a check that could
not run cannot look like an approved release input.

CI downloads checksum-pinned Just and XcodeGen binaries through the canonical
`tools/ci/install-pinned-tools.sh` helper. Local package managers may install
the tools, but the verifier still requires the exact audited versions.
Release CI invokes `tools/ci/install-pinned-tools.sh release`, which also
installs the checksum-pinned `gh` 2.95.0 binary. A local publisher must put
that exact `gh` version on `PATH` and pass `just verify-release-toolchain`.

---

## Running Tests

MarkDev includes a comprehensive suite of unit tests, property-based tests, and performance benchmarks across both languages.

```bash
# Run both Rust and Swift test suites
just test

# Run release contracts, Rust formatting/clippy/tests, and Swift tests
just check
```

### Individual Test Suites

- **Rust Core Tests**:
  ```bash
  cd core && cargo test --locked
  ```
- **Rust Property Tests (Incremental Parsing)**:
  ```bash
  cd core && cargo test --locked --test incremental
  ```
- **Rust Release Performance Gate**:
  ```bash
  cd core && cargo test --locked --release --test performance
  ```
- **Swift Application and Framework Tests** (including project boundary checks):
  ```bash
  just test-app
  ```

---

## Common Gotchas & Troubleshooting

### 1. `DEVELOPER_DIR` and Xcode Command Line Tools
If `xcode-select -p` points at `/Library/Developer/CommandLineTools` rather than `/Applications/Xcode.app/Contents/Developer`, `xcodebuild` will fail because the CommandLineTools SDK cannot build full AppKit/SwiftUI applications.

`justfile` handles this automatically by setting:
```bash
export DEVELOPER_DIR := "/Applications/Xcode.app/Contents/Developer"
```
If running `xcodebuild` manually outside `just`, ensure you export `DEVELOPER_DIR` in your shell session.

### 2. Document Icon Caching
macOS caches document-type icon artwork per bundle version. If document icons fail to update in Finder after modifying icon assets:

1. Bump `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Regenerate and compile icons:
   ```bash
   just icons
   just generate
   ```
3. Flush the system icon cache:
   ```bash
   killall -9 iconservicesagent
   lsregister -f -R -trusted MarkDev.app
   killall Dock
   ```

### 3. FFI Header Out of Sync
If you modify functions in `core/src/ffi.rs`, update the C header generated by `cbindgen`:
```bash
just header
```
This updates `core/include/markdev.h` which is imported by Swift's `CMarkDev` module.

### 4. HTML Export and Diagnostics

#### Exporting a note as HTML

Use **Export as HTML…** from the command palette or file menu.

The renderer routes through a bounded Rust path (`md_html_render`), applies strict destination sanitization, and writes atomically so partial exports cannot corrupt a destination file.

#### Diagnostics health and support bundle

Open **Settings → Support** to review:

- current-process recorded/retained/dropped counts and local sink health
- pending writes, delivery drops, rejected sink registrations, and sink failures
- **Export Support Report…** for a bounded current-process in-memory cut
- **Previous Runs** for a separate bounded inspection of inactive, trusted local run files
- **Export Previous Runs…** for sanitized history with exact included/omitted counts and an explicit unknown when a cap prevents a complete count

Support and history exports contain typed event codes, categorical/count metadata, app/build/OS context, and origins. They exclude note text, prompts, commands, environment values, full paths, and URL credentials or queries.

### Permissions and Quick Look

The main app is intentionally unsandboxed to open arbitrary vaults and host an interactive terminal. The Quick Look extension is a separate sandboxed, application-extension-only target with user-selected read-only access; it does not link `MarkDevKit` or `SwiftTerm`. Its privacy manifest declares no tracking and no collected-data categories. See [Architecture](./architecture.md) for the recovery, executable-trust, and residual same-user pathname-race boundaries.

`just install` installs the ad-hoc Release build; `just install-signed` installs
a build signed with the requested identity and hardened runtime. Neither form
of signing proves Finder preview delivery. Installation fails unless
`pluginkit` contains the exact extension identifier at
`/Applications/MarkDev.app/Contents/PlugIns/MarkDevQuickLook.appex`. Run `just
preview-status` to repeat that registration check and inspect filename content
types. `just preview <file>` then opens the system Quick Look UI, but
`qlmanage` does not report which registered provider rendered the result.
