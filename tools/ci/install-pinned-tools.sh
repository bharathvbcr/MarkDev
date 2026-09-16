#!/usr/bin/env bash
set -euo pipefail

# GitHub-hosted images and local package managers change independently of this
# repository. Install the exact audited binaries into one deterministic path
# instead of relying on either moving input. GitHub Actions receives the path
# through GITHUB_PATH; a local caller gets a shell command on stdout.

mode=${1:-all}
if [[ "$mode" != "just" && "$mode" != "all" && "$mode" != "release" ]]; then
    echo "usage: $0 [just|all|release]" >&2
    exit 2
fi

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_directory/../.." && pwd -P)
temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
temporary_root=${temporary_root%/}
if [[ ! -d "$temporary_root" ]]; then
    echo "temporary directory does not exist: $temporary_root" >&2
    exit 1
fi
staging=$(mktemp -d "$temporary_root/markdev-pinned-tools.XXXXXX")
xcodegen_install_staging=
xcodegen_transaction_active=0
xcodegen_resources_backed_up=0
xcodegen_resources_installed=0
xcodegen_binary_installed=0
xcodegen_resources=
xcodegen_staged_resources=
xcodegen_resources_backup=
xcodegen_binary_backup=
had_xcodegen_binary=0
cleanup() {
    local rollback_failed=0
    if [[ "$xcodegen_transaction_active" == 1 ]]; then
        set +e
        if [[ "$xcodegen_binary_installed" == 1 ]]; then
            mv "$pinned_bin/xcodegen" \
                "$xcodegen_install_staging/rejected-xcodegen-binary" || rollback_failed=1
            if [[ "$had_xcodegen_binary" == 1 ]]; then
                mv "$xcodegen_binary_backup" "$pinned_bin/xcodegen" || rollback_failed=1
            fi
        fi
        if [[ "$xcodegen_resources_installed" == 1 ]]; then
            mv "$xcodegen_resources" \
                "$xcodegen_install_staging/rejected-xcodegen-resources" || rollback_failed=1
        fi
        if [[ "$xcodegen_resources_backed_up" == 1 ]]; then
            mv "$xcodegen_resources_backup" "$xcodegen_resources" || rollback_failed=1
        fi
        set -e
        if [[ "$rollback_failed" == 1 ]]; then
            echo "pinned XcodeGen rollback needs manual recovery from $xcodegen_install_staging" >&2
        fi
    fi
    rm -rf "$staging"
    if [[ "$rollback_failed" == 0 && -n "$xcodegen_install_staging" \
        && -d "$xcodegen_install_staging" ]]; then
        rm -rf "$xcodegen_install_staging"
    fi
}
trap cleanup EXIT
pinned_bin=${MARKDEV_PINNED_BIN:-}
if [[ -z "$pinned_bin" ]]; then
    if [[ -n "${RUNNER_TEMP:-}" ]]; then
        pinned_bin="$RUNNER_TEMP/markdev-pinned-bin"
    else
        pinned_bin="$repository_root/build/pinned-tools/bin"
    fi
fi
if [[ "$pinned_bin" != /* ]]; then
    echo "MARKDEV_PINNED_BIN must be an absolute path: $pinned_bin" >&2
    exit 2
fi
mkdir -p "$pinned_bin"
if [[ -L "$pinned_bin" || ! -d "$pinned_bin" ]]; then
    echo "MARKDEV_PINNED_BIN must be a real directory: $pinned_bin" >&2
    exit 2
fi
pinned_bin_name=$(basename -- "$pinned_bin")
pinned_prefix=$(cd -- "$(dirname -- "$pinned_bin")" && pwd -P)
pinned_bin="$pinned_prefix/$pinned_bin_name"

download() {
    local url=$1
    local destination=$2
    local expected_size=$3
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 180 --retry 5 --retry-all-errors \
        --retry-max-time 180 --max-filesize "$expected_size" \
        --output "$destination" "$url"
    if [[ -L "$destination" || ! -f "$destination" ]]; then
        echo "pinned download is not a regular file: $destination" >&2
        exit 1
    fi
    actual_size=$(stat -f %z "$destination")
    if [[ "$actual_size" != "$expected_size" ]]; then
        echo "pinned download size mismatch: expected $expected_size, got $actual_size" >&2
        exit 1
    fi
}

case "$(uname -m)" in
    arm64)
        just_target=aarch64-apple-darwin
        just_sha=50ae3e996c974a0bf32ea7d10f495070df33f1b43e0616b2769e3d4821ed8f48
        just_size=2146038
        gh_target=arm64
        gh_sha=3677f9c27965825f9c7d50395473c134edaea4b484373ef6b25de653570a0489
        gh_size=13944744
        ;;
    x86_64)
        just_target=x86_64-apple-darwin
        just_sha=9a09cfef66aaa79da58203970103a0684307716caaabd3e9844cacc4dc0f4023
        just_size=2330963
        gh_target=amd64
        gh_sha=985707e9ac60c95ed51cddd808c338b481abe69fffa77e9d6547c3750045f77e
        gh_size=15285963
        ;;
    *)
        echo "unsupported macOS runner architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

just_archive="$staging/just.tar.gz"
download \
    "https://github.com/casey/just/releases/download/1.58.0/just-1.58.0-${just_target}.tar.gz" \
    "$just_archive" "$just_size"
echo "$just_sha  $just_archive" | shasum -a 256 --check
just_entries=$(tar -tzf "$just_archive" | grep -Fxc just || true)
if [[ "$just_entries" != 1 ]]; then
    echo "pinned Just archive does not contain one top-level executable" >&2
    exit 1
fi
tar -xzf "$just_archive" -C "$pinned_bin" just
just_version=$("$pinned_bin/just" --version)
[[ "$just_version" == "just 1.58.0" ]] || {
    echo "pinned Just binary reported an unexpected version" >&2
    exit 1
}

if [[ "$mode" == "all" || "$mode" == "release" ]]; then
    xcodegen_archive="$staging/xcodegen.zip"
    xcodegen_extract_root="$staging/xcodegen-extracted"
    download \
        "https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip" \
        "$xcodegen_archive" 4319508
    echo "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef  $xcodegen_archive" \
        | shasum -a 256 --check

    # The executable loads SettingPresets relative to its installed prefix.
    # The zip checksum binds bytes, while this independently binds the audited
    # path inventory so an extraction-tool regression cannot silently install
    # only the Mach-O and leave a project with no platform/product defaults.
    xcodegen_archive_entry_count=44
    xcodegen_archive_inventory="$staging/xcodegen-archive-inventory"
    if ! unzip -Z -1 "$xcodegen_archive" | LC_ALL=C sort > "$xcodegen_archive_inventory"; then
        echo "could not enumerate the pinned XcodeGen archive" >&2
        exit 1
    fi
    actual_xcodegen_entry_count=$(wc -l < "$xcodegen_archive_inventory" | tr -d ' ')
    if [[ "$actual_xcodegen_entry_count" != "$xcodegen_archive_entry_count" ]]; then
        echo "pinned XcodeGen archive entry-count mismatch: expected $xcodegen_archive_entry_count, got $actual_xcodegen_entry_count" >&2
        exit 1
    fi
    echo "f54b3b8571f9309605e44c358a98e3fdf4b27066ce4633d08b86889130e28928  $xcodegen_archive_inventory" \
        | shasum -a 256 --check

    mkdir -p "$xcodegen_extract_root"
    ditto -x -k "$xcodegen_archive" "$xcodegen_extract_root"
    extracted_xcodegen_entry_count=$(find "$xcodegen_extract_root" -mindepth 1 -print \
        | wc -l | tr -d ' ')
    if [[ "$extracted_xcodegen_entry_count" != "$xcodegen_archive_entry_count" ]]; then
        echo "extracted XcodeGen entry-count mismatch: expected $xcodegen_archive_entry_count, got $extracted_xcodegen_entry_count" >&2
        exit 1
    fi
    unexpected_xcodegen_entries="$staging/xcodegen-unexpected-entry-types"
    find "$xcodegen_extract_root" -mindepth 1 \
        ! \( -type d -o -type f \) -print > "$unexpected_xcodegen_entries"
    if [[ -s "$unexpected_xcodegen_entries" ]]; then
        echo "pinned XcodeGen archive extracted links or special files" >&2
        sed -n '1,10p' "$unexpected_xcodegen_entries" >&2
        exit 1
    fi

    xcodegen_payload="$xcodegen_extract_root/xcodegen"
    xcodegen_binary="$xcodegen_payload/bin/xcodegen"
    xcodegen_presets="$xcodegen_payload/share/xcodegen/SettingPresets"
    for required_path in \
        "$xcodegen_binary" \
        "$xcodegen_presets/base.yml" \
        "$xcodegen_presets/Configs/debug.yml" \
        "$xcodegen_presets/Configs/release.yml" \
        "$xcodegen_presets/Platforms/macOS.yml" \
        "$xcodegen_presets/Products/framework.yml" \
        "$xcodegen_presets/Products/bundle.unit-test.yml" \
        "$xcodegen_presets/Product_Platform/application_macOS.yml" \
        "$xcodegen_presets/Product_Platform/bundle.unit-test_macOS.yml"; do
        if [[ -L "$required_path" || ! -f "$required_path" ]]; then
            echo "pinned XcodeGen archive is missing a regular runtime file: $required_path" >&2
            exit 1
        fi
    done
    if [[ ! -x "$xcodegen_binary" ]]; then
        echo "pinned XcodeGen executable is not executable" >&2
        exit 1
    fi
    lipo "$xcodegen_binary" -verify_arch arm64 && lipo "$xcodegen_binary" -verify_arch x86_64
    xcodegen_version=$("$xcodegen_binary" --version)
    [[ "$xcodegen_version" == "Version: 2.45.4" ]] || {
        echo "pinned XcodeGen binary reported an unexpected version" >&2
        exit 1
    }

    # Copy the complete prefix into a same-filesystem staging directory. The
    # generated-project smoke test runs before either destination path changes.
    xcodegen_install_staging=$(mktemp -d "$pinned_prefix/.xcodegen-install.XXXXXX")
    ditto "$xcodegen_payload/bin" "$xcodegen_install_staging/bin"
    ditto "$xcodegen_payload/share" "$xcodegen_install_staging/share"

    xcodegen_smoke_root="$staging/xcodegen-smoke"
    mkdir -p "$xcodegen_smoke_root"
    xcodegen_smoke_spec="$xcodegen_smoke_root/project.yml"
    {
        printf '%s\n' \
            'name: MarkDev' \
            'targets:' \
            '  MarkDevKit:' \
            '    type: framework' \
            '    platform: macOS' \
            '  MarkDev:' \
            '    type: application' \
            '    platform: macOS' \
            '  MarkDevKitTests:' \
            '    type: bundle.unit-test' \
            '    platform: macOS'
    } > "$xcodegen_smoke_spec"

    exercise_xcodegen_layout() {
        local executable=$1
        local label=$2
        local output_root="$xcodegen_smoke_root/$label"
        local output_log="$xcodegen_smoke_root/$label.log"
        mkdir -p "$output_root"
        if ! "$executable" generate \
            --spec "$xcodegen_smoke_spec" \
            --project "$output_root" \
            --project-root "$output_root" > "$output_log" 2>&1; then
            echo "pinned XcodeGen $label layout failed its generation smoke test" >&2
            sed -n '1,80p' "$output_log" >&2
            return 1
        fi
        for missing_preset_warning in \
            'No "base" settings found' \
            'No "debug config" settings found' \
            'No "release config" settings found' \
            'No "macOS" settings found'; do
            if grep -Fq "$missing_preset_warning" "$output_log"; then
                echo "pinned XcodeGen $label layout could not load its SettingPresets" >&2
                sed -n '1,80p' "$output_log" >&2
                return 1
            fi
        done
        local generated_project="$output_root/MarkDev.xcodeproj/project.pbxproj"
        if [[ -L "$generated_project" || ! -f "$generated_project" ]]; then
            echo "pinned XcodeGen $label layout did not generate a regular project" >&2
            return 1
        fi
        for expected_product in \
            'productName = MarkDev;' \
            'productName = MarkDevKit;' \
            'productName = MarkDevKitTests;'; do
            if ! grep -Fq "$expected_product" "$generated_project"; then
                echo "pinned XcodeGen $label layout omitted expected product settings" >&2
                return 1
            fi
        done
    }

    if ! exercise_xcodegen_layout "$xcodegen_install_staging/bin/xcodegen" staged; then
        exit 1
    fi

    # Commit resources first and the executable last. Each path crosses its
    # boundary through rename(2) on one filesystem; a failed executable move
    # restores the previous resources instead of exposing a partial runtime.
    mkdir -p "$pinned_prefix/share"
    if [[ -L "$pinned_prefix/share" || ! -d "$pinned_prefix/share" ]]; then
        echo "pinned XcodeGen share destination must be a real directory" >&2
        exit 1
    fi
    xcodegen_staging_device=$(stat -f %d "$xcodegen_install_staging")
    for destination_directory in "$pinned_bin" "$pinned_prefix/share"; do
        destination_device=$(stat -f %d "$destination_directory")
        if [[ "$destination_device" != "$xcodegen_staging_device" ]]; then
            echo "pinned XcodeGen staging and destination must share a filesystem" >&2
            exit 1
        fi
    done
    xcodegen_staged_resources="$xcodegen_install_staging/share/xcodegen"
    xcodegen_resources="$pinned_prefix/share/xcodegen"
    xcodegen_resources_backup="$xcodegen_install_staging/previous-xcodegen-resources"
    xcodegen_binary_backup="$xcodegen_install_staging/previous-xcodegen-binary"
    if [[ ( -e "$pinned_bin/xcodegen" || -L "$pinned_bin/xcodegen" ) \
        && ( -L "$pinned_bin/xcodegen" || ! -f "$pinned_bin/xcodegen" ) ]]; then
        echo "refusing to replace a non-regular XcodeGen destination: $pinned_bin/xcodegen" >&2
        exit 1
    fi
    if [[ -f "$pinned_bin/xcodegen" ]]; then
        ditto "$pinned_bin/xcodegen" "$xcodegen_binary_backup"
        had_xcodegen_binary=1
    fi
    xcodegen_transaction_active=1
    if [[ -e "$xcodegen_resources" || -L "$xcodegen_resources" ]]; then
        mv "$xcodegen_resources" "$xcodegen_resources_backup"
        xcodegen_resources_backed_up=1
    fi
    if ! mv "$xcodegen_staged_resources" "$xcodegen_resources"; then
        echo "could not atomically install pinned XcodeGen resources" >&2
        exit 1
    fi
    xcodegen_resources_installed=1
    if ! mv -f "$xcodegen_install_staging/bin/xcodegen" "$pinned_bin/xcodegen"; then
        echo "could not atomically install the pinned XcodeGen executable" >&2
        exit 1
    fi
    xcodegen_binary_installed=1

    if ! exercise_xcodegen_layout "$pinned_bin/xcodegen" installed; then
        exit 1
    fi
    xcodegen_transaction_active=0
fi

if [[ "$mode" == "release" ]]; then
    gh_version=2.95.0
    gh_archive="$staging/gh.zip"
    gh_root="$staging/gh"
    download \
        "https://github.com/cli/cli/releases/download/v${gh_version}/gh_${gh_version}_macOS_${gh_target}.zip" \
        "$gh_archive" "$gh_size"
    echo "$gh_sha  $gh_archive" | shasum -a 256 --check
    mkdir -p "$gh_root"
    ditto -x -k "$gh_archive" "$gh_root"
    gh_candidate_list="$staging/gh-candidates"
    find "$gh_root" -type f -path '*/bin/gh' -perm -111 > "$gh_candidate_list"
    gh_candidate_count=$(wc -l < "$gh_candidate_list" | tr -d ' ')
    if [[ "$gh_candidate_count" != 1 ]]; then
        echo "pinned GitHub CLI archive did not contain one executable" >&2
        exit 1
    fi
    gh_binary=$(sed -n '1p' "$gh_candidate_list")
    ditto "$gh_binary" "$pinned_bin/gh"
    reported_gh_version=$("$pinned_bin/gh" --version | sed -n '1p')
    case "$reported_gh_version" in
        "gh version ${gh_version} "*) ;;
        *)
            echo "pinned GitHub CLI binary reported an unexpected version" >&2
            exit 1
            ;;
    esac
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$pinned_bin" >> "$GITHUB_PATH"
else
    printf 'Pinned tools installed in %s\n' "$pinned_bin"
    printf "Add them to this shell with:\n  export PATH=%q:\$PATH\n" "$pinned_bin"
fi
