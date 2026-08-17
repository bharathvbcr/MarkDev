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

# A Release signed with a real identity, which is the only kind whose Quick
# Look extension `pkd` will register. Ad-hoc is not enough — `pluginkit -a`
# exits 0 and registers nothing — and this is not a guess: on this machine
# QLMarkdown's extension registers from /Applications with a Developer ID and
# a team identifier, while MarkDev's, in the same directory, does not with
# `Signature=adhoc, TeamIdentifier=not set`.
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
#     just build-release-signed "Developer ID Application: You (TEAMID)"
build-release-signed IDENTITY="Apple Development": build-core generate
    #!/usr/bin/env zsh
    set -euo pipefail
    if ! security find-identity -v -p codesigning | grep -q "{{IDENTITY}}"; then
        echo "no codesigning identity matching {{IDENTITY}}." >&2
        echo "Xcode > Settings > Accounts > (your Apple ID) > Manage Certificates" >&2
        echo "  > + > Apple Development. A free Apple ID is enough." >&2
        exit 1
    fi
    xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Release \
        CODE_SIGN_IDENTITY="{{IDENTITY}}" \
        ENABLE_HARDENED_RUNTIME=YES \
        build

# Copy a built Release into /Applications and make the system notice it.
#
# The registration steps are not optional bookkeeping. Launch Services caches
# document-icon artwork per bundle path and version, and Icon Services caches
# by path, so a bundle that once had no icon keeps showing the placeholder
# grid — which reads as "the icon is broken" — until the caches are dropped.
#
# `install` is the ad-hoc build: the app runs and claims .md, but its Quick
# Look extension will not register. `install-signed` is the one that gets
# Space-bar previews working.
install: build-release install-only
install-signed IDENTITY="Apple Development": (build-release-signed IDENTITY) install-only

install-only:
    #!/usr/bin/env zsh
    set -euo pipefail
    products=$(xcodebuild -project MarkDev.xcodeproj -scheme MarkDev \
        -configuration Release -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')
    app=$products/MarkDev.app
    codesign --verify --deep --strict "$app"
    # Replaced, not merged: ditto over an existing bundle leaves behind files
    # the new build no longer ships.
    rm -rf /Applications/MarkDev.app
    ditto "$app" /Applications/MarkDev.app
    lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
    killall -9 iconservicesagent 2>/dev/null || true
    $lsregister -f -R -trusted /Applications/MarkDev.app
    killall Dock 2>/dev/null || true
    echo "installed /Applications/MarkDev.app"

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
