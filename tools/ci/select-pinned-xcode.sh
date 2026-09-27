#!/usr/bin/env bash
set -euo pipefail

# GitHub-hosted macOS images carry several Xcode versions and change which one
# is the default independently of this repository. Select the one whose build
# matches the pin `just verify-toolchain` enforces, found by build number
# rather than by application name, so a renamed bundle still matches and a
# missing one fails here with the list of what the image does have.

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_directory/../.." && pwd -P)

expected_build=$(
    sed -n "s/^[[:space:]]*expected_version=\\$'Xcode [0-9.]*\\\\nBuild version \\([0-9A-Za-z]*\\)'.*/\\1/p" \
        "$repository_root/justfile" | head -n 1
)
if [[ -z "$expected_build" ]]; then
    echo "could not read the pinned Xcode build from justfile" >&2
    exit 1
fi

for application in /Applications/Xcode*.app; do
    developer="$application/Contents/Developer"
    [[ -x "$developer/usr/bin/xcodebuild" ]] || continue
    build=$(DEVELOPER_DIR="$developer" "$developer/usr/bin/xcodebuild" -version 2>/dev/null \
        | sed -n 's/^Build version //p')
    if [[ "$build" == "$expected_build" ]]; then
        sudo xcode-select --switch "$developer"
        echo "Selected $application (build $build)"
        xcodebuild -version
        exit 0
    fi
done

echo "::error::No installed Xcode has the pinned build $expected_build. Installed:" >&2
for application in /Applications/Xcode*.app; do
    developer="$application/Contents/Developer"
    [[ -x "$developer/usr/bin/xcodebuild" ]] || continue
    echo "  $application: $(DEVELOPER_DIR="$developer" "$developer/usr/bin/xcodebuild" -version 2>/dev/null | tr '\n' ' ')" >&2
done
exit 1
