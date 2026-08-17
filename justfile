# MarkDev build orchestration.
#
# The Rust staticlib must be built before the Swift targets link against it,
# and in the *matching* configuration — a debug Swift build linking a release
# .a (or vice versa) is the classic stale-artifact trap.

set shell := ["zsh", "-cu"]

# xcode-select on this machine points at CommandLineTools, whose SDK cannot
# build a macOS app. Setting DEVELOPER_DIR per-invocation fixes that without
# needing sudo.
export DEVELOPER_DIR := "/Applications/Xcode.app/Contents/Developer"
# C-backed tree-sitter grammars inherit the host SDK version unless this is
# explicit, producing objects that cannot actually run on the app's 26.0
# deployment target.
export MACOSX_DEPLOYMENT_TARGET := "26.0"

default: build

# --- Rust core -------------------------------------------------------------

build-core:
    cd core && cargo build --release

build-core-debug:
    cd core && cargo build

test-core:
    cd core && cargo test

lint-core:
    cd core && cargo clippy --all-targets -- -D warnings

fmt:
    cd core && cargo fmt

fmt-check:
    cd core && cargo fmt --check

# Regenerate include/markdev.h from the FFI surface.
header:
    cd core && touch build.rs && cargo build

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
    sources=(tools/icongen/main.swift app/MarkDevKit/Brand/MarkDevLogo.swift)
    if [[ -f $document ]]; then
        stale=0
        for source in $sources; do
            if [[ $source -nt $document ]]; then stale=1; fi
        done
        if (( ! stale )); then
            echo "icons: up to date"
            exit 0
        fi
    fi
    mkdir -p build/tools $resources
    xcrun swiftc -O $sources -o build/tools/icongen
    build/tools/icongen $catalog build/DocumentIcon.iconset
    xcrun iconutil -c icns build/DocumentIcon.iconset -o $document

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
    xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Debug build

build-release: build-core generate
    xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Release build

test: test-core test-app

test-app: build-core-debug generate
    xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Debug test

run: build
    open "$(xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/MarkDev.app"

# --- Quick Look ------------------------------------------------------------

# Preview a file through the built extension. Requires `just run` at least
# once so Launch Services has registered the .appex.
preview FILE: build
    qlmanage -p {{FILE}}

# What macOS thinks will handle Markdown previews right now.
#
# `qlmanage -m plugins` lists only the *legacy* .qlgenerator plugins and never
# mentions a modern .appex, so it reported "nothing registered" even for the
# extension that was in fact serving previews. pluginkit is the register that
# actually decides.
preview-status:
    #!/usr/bin/env zsh
    echo "Quick Look preview extensions claiming Markdown:"
    pluginkit -mAD -p com.apple.quicklook.preview -v 2>/dev/null \
        | grep -iE "markdev|markdown" || echo "  (none)"
    echo
    echo "Type resolution:"
    for ext in md markdown mdx mkd; do
        probe=$(mktemp -d)/probe.$ext
        touch $probe
        printf "  .%-9s %s\n" $ext "$(mdls -name kMDItemContentType -raw $probe)"
        rm -rf $(dirname $probe)
    done

# --- Housekeeping ----------------------------------------------------------

clean:
    cd core && cargo clean
    rm -rf MarkDev.xcodeproj build/ app/MarkDev/Assets.xcassets app/MarkDev/Resources ~/Library/Developer/Xcode/DerivedData/MarkDev-*

check: fmt-check lint-core test
