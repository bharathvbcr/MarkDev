# MarkDev build orchestration.
#
# The Rust staticlib must be built before the Swift targets link against it,
# and in the *matching* configuration — a debug Swift build linking a release
# .a (or vice versa) is the classic stale-artifact trap.

set shell := ["zsh", "-cu"]

# xcode-select on this machine points at CommandLineTools, whose SDK cannot
# build a macOS app. Setting DEVELOPER_DIR per-invocation fixes that without
# needing sudo.
export DEVELOPER_DIR := env_var_or_default("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
# C-backed tree-sitter grammars inherit the host SDK version unless this is
# explicit, producing objects that cannot actually run on the app's 26.0
# deployment target.
export MACOSX_DEPLOYMENT_TARGET := "26.0"

# Every Xcode entry point consumes the checked-in transitive lock and refuses
# to rewrite it as a side effect of building, testing, or locating products.
locked_package_flags := "-onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates"

default: build

# --- Rust core -------------------------------------------------------------

build-core:
    #!/usr/bin/env zsh
    set -euo pipefail
    targets=(aarch64-apple-darwin x86_64-apple-darwin)
    for target in $targets; do
        cargo build --locked --manifest-path core/Cargo.toml --release --target "$target"
    done

    output=core/target/release/libmarkdev.a
    mkdir -p "${output:h}"
    staging=$(mktemp -d "${output:h}/.universal-core.XXXXXX")
    trap 'rm -rf "$staging"' EXIT
    staged=$staging/libmarkdev.a
    lipo -create \
        core/target/aarch64-apple-darwin/release/libmarkdev.a \
        core/target/x86_64-apple-darwin/release/libmarkdev.a \
        -output "$staged"
    lipo "$staged" -verify_arch arm64 && lipo "$staged" -verify_arch x86_64
    actual_arches=$(lipo -archs "$staged")
    if ! print -r -- "$actual_arches" | awk '
        {
            if (NF != 2) exit 1
            for (field = 1; field <= NF; field += 1) seen[$field] += 1
            exit !(seen["arm64"] == 1 && seen["x86_64"] == 1)
        }
    '; then
        echo "universal Rust archive has unexpected slices: $actual_arches" >&2
        exit 1
    fi
    mv -f "$staged" "$output"
    rmdir "$staging"
    trap - EXIT
    echo "universal Rust archive: $output ($actual_arches)"

build-core-debug:
    cd core && cargo build --locked

test-core:
    cd core && cargo test --locked

# Exercise every optional-library configuration used by embedding hosts.
# Default ffi+highlight is covered by test-core; these cover the other three.
test-core-features:
    cd core && cargo test --locked --no-default-features
    cd core && cargo test --locked --no-default-features --features highlight
    cd core && cargo test --locked --no-default-features --features ffi

lint-core:
    cd core && cargo clippy --locked --all-targets -- -D warnings

fmt:
    cd core && cargo fmt

fmt-check:
    cd core && cargo fmt --check

# Regenerate include/markdev.h from the FFI surface.
header:
    cd core && touch build.rs && cargo build --locked

# --- Brand -----------------------------------------------------------------

# Render the app icon and the Markdown document icon from MarkDevLogo.
#
# Neither is checked in: both are compiled from the same geometry the app
# draws, so there is nothing for a stale PNG to disagree with. Rebuilds only
# when the geometry or the renderer changes, since this sits in front of every
# build.
#
# The app icon goes into the asset catalog; the document icon has to be a real
# .icns in Resources, because `CFBundleTypeIconFile` resolves against a file
# and actool only emits an .icns for the app icon.
icons:
    #!/usr/bin/env zsh
    set -euo pipefail
    catalog=app/MarkDev/Assets.xcassets
    resources=app/MarkDev/Resources
    document=$resources/DocumentIcon.icns
    validator=tools/icongen/validate.py
    sources=(tools/icongen/main.swift app/MarkDevKit/Brand/MarkDevLogo.swift)
    freshness_sources=($sources $validator)
    if python3 "$validator" "$catalog" "$document" $freshness_sources; then
        echo "icons: up to date"
        exit 0
    fi
    mkdir -p build/tools $resources
    xcrun swiftc -O $sources -o build/tools/icongen
    build/tools/icongen $catalog build/DocumentIcon.iconset
    xcrun iconutil -c icns build/DocumentIcon.iconset -o $document
    python3 "$validator" "$catalog" "$document" $freshness_sources

# --- Xcode project ---------------------------------------------------------

# Regenerate MarkDev.xcodeproj from project.yml. Run after changing targets,
# settings, or adding a new source directory.
#
# Depends on `icons` because xcodegen snapshots the file list: a catalog that
# does not exist yet is simply absent from the project.
generate: icons
    xcodegen generate

# --- App -------------------------------------------------------------------

build: build-core-debug generate
    xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Debug {{ locked_package_flags }} -skipPackagePluginValidation -derivedDataPath build/DerivedData/Debug build

build-release: verify-toolchain build-core generate
    python3 tools/release/project_contract.py -v
    xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Release MARKDEV_SOURCE_COMMIT="$(git rev-parse HEAD)" {{ locked_package_flags }} -skipPackagePluginValidation -derivedDataPath build/DerivedData/Release clean build

# A Release signed with a real identity.
#
# A real identity is what allows hardened runtime, which an ad-hoc build
# cannot have. It does not by itself prove that another Mac will accept the
# app or that Quick Look registered the embedded extension: Developer ID signing
# and notarisation are separate distribution gates, and `install-only` checks
# the local plug-in registry after installation rather than inferring success
# from the signature.
#
# Hardened runtime is turned back on here and *only* here. It travels with the
# identity: a hardened-runtime process cannot load an ad-hoc signed framework,
# so enabling it on the unsigned path produces an app that dies in dyld before
# `main` — which is exactly what shipped until it was caught by launching one.
#
# Overridden on the command line rather than in project.yml so that a clone
# with no certificate still builds and runs.
#
#     just build-release-signed                      # Apple Development
# just build-release-signed "Developer ID Application: You (TEAMID)"
build-release-signed IDENTITY="Apple Development": verify-toolchain build-core generate
    #!/usr/bin/env zsh
    set -euo pipefail
    identity={{ quote(IDENTITY) }}
    identity_info=$(python3 tools/release/signing_identity.py resolve "$identity")
    IFS=$'\t' read -r fingerprint team <<< "$identity_info"
    python3 tools/release/project_contract.py -v
    echo "signing with exact certificate $fingerprint (team $team)"
    # Manual signing: a Mac app with no team-restricted entitlements needs no
    # provisioning profile, and automatic signing would insist on fetching one.
    xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Release \
        MARKDEV_SOURCE_COMMIT="$(git rev-parse HEAD)" \
        CODE_SIGN_IDENTITY="$fingerprint" \
        DEVELOPMENT_TEAM="$team" \
        CODE_SIGN_STYLE=Manual \
        ENABLE_HARDENED_RUNTIME=YES \
        {{ locked_package_flags }} \
        -skipPackagePluginValidation \
        -derivedDataPath build/DerivedData/Release \
        clean build
    app=build/DerivedData/Release/Build/Products/Release/MarkDev.app
    python3 tools/release/signing_identity.py verify "$app" "$fingerprint" "$team"

# Copy a built Release into /Applications and make the system notice it.
#
# The registration steps are not optional bookkeeping. Launch Services caches
# document-icon artwork per bundle path and version, and Icon Services caches
# by path, so a bundle that once had no icon keeps showing the placeholder
# grid — which reads as "the icon is broken" — until the caches are dropped.
#
# `install` installs the ad-hoc build. `install-signed` installs a build with
# the requested identity and hardened runtime. Neither signature choice is
# treated as proof that Finder can use the extension; `install-only` requires
# the registry to contain this exact installed bundle before it reports success.
install: build-release install-only
install-signed IDENTITY="Apple Development": (build-release-signed IDENTITY) install-only

install-only:
    #!/usr/bin/env zsh
    set -euo pipefail
    products=$(xcodebuild -project MarkDev.xcodeproj -scheme MarkDev \
        -configuration Release {{ locked_package_flags }} -showBuildSettings 2>/dev/null \
        -derivedDataPath build/DerivedData/Release \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')
    app=$products/MarkDev.app
    tools/release/install-app.sh "$app"

test: test-core test-app

test-app $TEST_FILTER="": build-core-debug generate
    python3 tools/release/project_contract.py -v
    xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Debug {{ locked_package_flags }} -skipPackagePluginValidation -derivedDataPath build/DerivedData/Debug test ${TEST_FILTER:+"-only-testing:$TEST_FILTER"}

run: build
    open "$(xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Debug {{ locked_package_flags }} -derivedDataPath build/DerivedData/Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/MarkDev.app"

# --- Quick Look ------------------------------------------------------------

# Ask the system Quick Look service to preview a file. Building MarkDev does
# not prove which provider macOS will use, so first require at least one
# existing extension whose bundle identifier is exactly MarkDev's. `qlmanage`
# opens the system preview UI but cannot attribute the rendered preview to a
# provider; `just preview-status` checks the /Applications registration.
preview FILE: build
    #!/usr/bin/env zsh
    set -euo pipefail
    target={{ quote(FILE) }}
    bundle_id=dev.markdev.MarkDev.QuickLook
    registrations=$(pluginkit -mAD -p com.apple.quicklook.preview \
        -i "$bundle_id" -v 2>/dev/null || true)
    found=0
    while IFS= read -r appex; do
        [[ -d "$appex" ]] || continue
        actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$appex/Contents/Info.plist" 2>/dev/null || true)
        if [[ "$actual_bundle_id" == "$bundle_id" ]]; then
            echo "registered MarkDev Quick Look candidate: $appex"
            found=1
        fi
    done < <(print -r -- "$registrations" | awk -F '\t' -v id="$bundle_id" '
        {
            candidate = $1
            sub(/^[[:space:]]+/, "", candidate)
            if (index(candidate, id "(") == 1) print $NF
        }
    ')
    if (( ! found )); then
        echo "no existing Quick Look extension with bundle identifier $bundle_id is registered" >&2
        exit 1
    fi
    echo "qlmanage is opening the system preview; it does not report which provider rendered it."
    qlmanage -p "$target"

# Verify the registration for the installed MarkDev extension and show
# the content types macOS assigns to representative filename extensions.
#
# `qlmanage -m plugins` lists only the *legacy* .qlgenerator plugins and never
# mentions a modern .appex. `pluginkit -mAD` is queried by exact bundle ID and
# a record must resolve to the exact /Applications path; another
# checkout or a competing Markdown extension is not accepted as success.
preview-status:
    #!/usr/bin/env zsh
    set -euo pipefail
    appex=/Applications/MarkDev.app/Contents/PlugIns/MarkDevQuickLook.appex
    python3 tools/release/quicklook_registration.py check "$appex"

# --- Release ---------------------------------------------------------------

# Release arguments are environment values, never interpolated shell source.
verify-tag $TAG:
    python3 tools/release/release.py verify-tag "$TAG"

release-preflight $TAG:
    python3 tools/release/release.py preflight "$TAG"

# Build first with `just build-release`. Staging verifies all owned bundles,
# architecture, the extracted archive, source/tag identity, and checksums.
release-stage $TAG:
    python3 tools/release/release.py stage "$TAG"

release-verify $TAG:
    python3 tools/release/release.py verify-assets "$TAG"

# Retry missing uploads without replacing an asset. The command refuses a
# release observed as published; publication must not race this remote workflow.
release-draft $TAG: verify-github-cli
    python3 tools/release/release.py draft "$TAG"

test-release:
    python3 -m unittest discover -s tools/release -p 'test_*.py' -v

# --- Housekeeping ----------------------------------------------------------

clean:
    cd core && cargo clean
    rm -rf build/ app/MarkDev/Assets.xcassets app/MarkDev/Resources

check: check-site test-release fmt-check lint-core test

# Run full CI suite locally (matches GitHub Actions CI workflow)
ci-core: verify-core-toolchain check-site test-release fmt-check lint-core test-core test-core-features build-core
    host_target=$(rustc -vV | awk -F': ' '/^host:/ {print $2}') && cd core && cargo test --locked --release --target "$host_target" --test performance

verify-core-toolchain:
    #!/usr/bin/env zsh
    set -euo pipefail
    expected_rust='rustc 1.98.0 (88d9e12ae 2026-08-18)'
    expected_cargo='cargo 1.98.0 (797e8a9bc 2026-08-05)'
    expected_just='just 1.58.0'
    actual_rust=$(rustc --version)
    actual_cargo=$(cargo --version)
    actual_just=$(just --version)
    [[ "$actual_rust" == "$expected_rust" ]] || {
        echo "Rust toolchain mismatch: expected $expected_rust, got $actual_rust" >&2
        exit 1
    }
    [[ "$actual_cargo" == "$expected_cargo" ]] || {
        echo "Cargo toolchain mismatch: expected $expected_cargo, got $actual_cargo" >&2
        exit 1
    }
    [[ "$actual_just" == "$expected_just" ]] || {
        echo "just mismatch: expected $expected_just, got $actual_just" >&2
        exit 1
    }
    installed_targets=$(rustup target list --installed)
    for required_target in aarch64-apple-darwin x86_64-apple-darwin; do
        if ! print -r -- "$installed_targets" | grep -Fxq "$required_target"; then
            echo "missing Rust release target: $required_target" >&2
            exit 1
        fi
    done
    echo "$actual_rust"
    echo "$actual_cargo"
    echo "$actual_just"

verify-github-cli:
    #!/usr/bin/env zsh
    set -euo pipefail
    expected='gh version 2.95.0 '
    actual=$(gh --version | sed -n '1p')
    if [[ "$actual" != "$expected"* ]]; then
        echo "GitHub CLI mismatch: expected ${expected}..., got $actual" >&2
        exit 1
    fi
    echo "$actual"

verify-release-toolchain: verify-toolchain verify-github-cli

verify-toolchain: verify-core-toolchain
    #!/usr/bin/env zsh
    set -euo pipefail
    expected_xcodegen='Version: 2.45.4'
    actual_xcodegen=$(xcodegen --version)
    if [[ "$actual_xcodegen" != "$expected_xcodegen" ]]; then
        echo "XcodeGen mismatch: expected $expected_xcodegen, got $actual_xcodegen" >&2
        exit 1
    fi
    version=$(xcodebuild -version)
    expected_version=$'Xcode 27.0\nBuild version 27A266a'
    if [[ "$version" != "$expected_version" ]]; then
        echo "Xcode toolchain mismatch; expected:" >&2
        echo "$expected_version" >&2
        echo "selected toolchain reports:" >&2
        echo "$version" >&2
        exit 1
    fi
    echo "$actual_xcodegen"
    echo "$version"

ci-local: verify-toolchain ci-core test-app build-release

ci: ci-local

# --- Documentation and product website -------------------------------------

check-site:
    python3 tools/docs/check_site.py

check-docs: check-site
    cd core && cargo test --locked --test docs_contract

# Static preview: no build or package installation, loopback only.
website $PORT="8000":
    python3 -m http.server "$PORT" --bind 127.0.0.1 --directory website
