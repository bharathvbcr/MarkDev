#!/bin/zsh
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

if (( $# != 1 )); then
    echo "usage: $0 /absolute/path/to/MarkDev.app" >&2
    exit 2
fi

source_app=$1
destination=/Applications/MarkDev.app
script_path=${0:A}
script_dir=${script_path:h}
repo_root=${script_dir:h:h}
python=/usr/bin/python3
atomic_helper=$script_dir/atomic_install.py
signing_helper=$script_dir/signing_identity.py
quicklook_helper=$script_dir/quicklook_registration.py
lock_file=/Applications/.MarkDev-install.lock
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

if [[ "$source_app" != /* || "$source_app" == "$destination" || -L "$source_app" || ! -d "$source_app" ]]; then
    echo "install source must be a distinct absolute, real application directory" >&2
    exit 1
fi

# A Python lifecycle owner retains the actual advisory lock while this worker
# runs. Only a one-shot pipe proof reaches the worker; the lock descriptor never
# reaches this shell or any codesign, ditto, registration, or daemon descendant.
if [[ -z ${MARKDEV_INSTALL_GUARD_FD:-} && -z ${MARKDEV_INSTALL_GUARD_TOKEN:-} ]]; then
    exec "$python" "$atomic_helper" lock-run "$lock_file" -- "$script_path" "$source_app"
fi
if [[ -z ${MARKDEV_INSTALL_GUARD_FD:-} || -z ${MARKDEV_INSTALL_GUARD_TOKEN:-} \
    || "$MARKDEV_INSTALL_GUARD_FD" != <-> \
    || ! "$MARKDEV_INSTALL_GUARD_TOKEN" =~ '^[0-9a-f]{64}$' ]]; then
    echo "installer lock session is incomplete or malformed" >&2
    exit 1
fi
guard_fd=$MARKDEV_INSTALL_GUARD_FD
"$python" "$atomic_helper" assert-lock-session \
    "$lock_file" "$guard_fd" "$MARKDEV_INSTALL_GUARD_TOKEN"
exec {guard_fd}<&-
unset MARKDEV_INSTALL_GUARD_FD MARKDEV_INSTALL_GUARD_TOKEN guard_fd

cd "$repo_root"

run_bounded() {
    local timeout=$1
    shift
    "$python" "$atomic_helper" run-bounded "$timeout" -- "$@"
}

verify_commitment() {
    local path=$1
    local expected=$2
    local owner=$3
    if [[ "$expected" == "-" || ! "$expected" =~ '^[0-9a-f]{64}$' ]]; then
        echo "$owner has no valid recorded content commitment" >&2
        return 1
    fi
    local actual
    actual=$("$python" "$signing_helper" verify-restorable "$path")
    if [[ "$actual" != "$expected" ]]; then
        echo "$owner content changed after it was committed; preserving transaction state" >&2
        return 1
    fi
}

register_app() {
    local app=$1
    local appex=$app/Contents/PlugIns/MarkDevQuickLook.appex
    run_bounded 30 "$lsregister" -f -R -trusted "$app"
    if [[ -e "$appex" || -L "$appex" ]]; then
        if [[ ! -d "$appex" || -L "$appex" ]]; then
            echo "app has an unsafe Quick Look extension path: $appex" >&2
            return 1
        fi
        run_bounded 15 /usr/bin/pluginkit -a "$appex"
        "$python" "$quicklook_helper" wait "$appex"
    fi
}

unregister_extension() {
    local bundle_with_extension=$1
    local retired_app_path=$2
    local appex=$bundle_with_extension/Contents/PlugIns/MarkDevQuickLook.appex
    local retired_appex=$retired_app_path/Contents/PlugIns/MarkDevQuickLook.appex
    if [[ ! -d "$appex" || -L "$appex" ]]; then
        echo "cannot retire an unsafe or missing Quick Look extension: $appex" >&2
        return 1
    fi
    # Removal is idempotent only when the independent exact-path query agrees.
    # A nonzero remove command is tolerated solely if `absent` proves the
    # retired registration is already gone.
    run_bounded 15 /usr/bin/pluginkit -r "$appex" || true
    "$python" "$quicklook_helper" absent "$retired_appex"
}

recover_transaction() {
    local staging=$1
    if [[ ! "$staging" =~ '^/Applications/\.MarkDev-install\.[A-Za-z0-9]+$' || ! -d "$staging" || -L "$staging" ]]; then
        echo "refusing ambiguous installer recovery root: $staging" >&2
        return 1
    fi
    local candidate=$staging/candidate.app
    local transaction=$staging/transaction.json
    local action
    action=$("$python" "$atomic_helper" recovery-action \
        "$transaction" "$candidate" "$destination")

    local incoming previous preserve_incoming
    case "$action" in
        cleanup-empty)
            "$python" "$atomic_helper" cleanup-empty-staging "$staging"
            ;;
        cleanup-allocating)
            "$python" "$atomic_helper" cleanup-transaction \
                "$transaction" "$candidate" "$destination"
            ;;
        rollback-installed|rollback-swapped)
            incoming=$("$python" "$atomic_helper" commitment \
                "$transaction" "$candidate" "$destination" incoming)
            preserve_incoming=0
            if [[ "$action" == rollback-swapped ]]; then
                previous=$("$python" "$atomic_helper" commitment \
                    "$transaction" "$candidate" "$destination" previous)
                verify_commitment "$candidate" "$previous" "held previous app"
            fi
            if ! verify_commitment "$destination" "$incoming" "pending installed app"; then
                preserve_incoming=1
                echo "pending incoming app was mutated; withdrawing its exact recorded inode and preserving it" >&2
            fi
            if ! unregister_extension "$destination" "$destination"; then
                echo "incoming Quick Look cleanup failed; continuing filesystem rollback" >&2
            fi
            typeset -a rollback_arguments
            rollback_arguments=(
                rollback-transaction "$transaction" "$candidate" "$destination"
            )
            if (( preserve_incoming )); then
                rollback_arguments+=(--preserve-candidate)
            fi
            "$python" "$atomic_helper" "${rollback_arguments[@]}" >/dev/null
            if [[ "$action" == rollback-swapped ]]; then
                verify_commitment "$destination" "$previous" "restored previous app"
                register_app "$destination"
                verify_commitment "$destination" "$previous" "registered previous app"
            else
                if ! "$python" "$quicklook_helper" absent \
                    "$destination/Contents/PlugIns/MarkDevQuickLook.appex"; then
                    echo "withdrawn Quick Look registration could not be proven absent" >&2
                fi
            fi
            if (( preserve_incoming )); then
                echo "mutated incoming app is quarantined at $candidate; manual inspection is required" >&2
                return 1
            fi
            verify_commitment "$candidate" "$incoming" "rolled-back incoming app"
            "$python" "$atomic_helper" cleanup-transaction \
                "$transaction" "$candidate" "$destination"
            ;;
        rollback-preserve-installed|rollback-preserve-swapped)
            incoming=$("$python" "$atomic_helper" commitment \
                "$transaction" "$candidate" "$destination" incoming)
            if [[ "$action" == rollback-preserve-swapped ]]; then
                previous=$("$python" "$atomic_helper" commitment \
                    "$transaction" "$candidate" "$destination" previous)
                verify_commitment "$candidate" "$previous" "held previous app"
            fi
            if ! unregister_extension "$destination" "$destination"; then
                echo "quarantined incoming Quick Look cleanup failed; continuing filesystem rollback" >&2
            fi
            "$python" "$atomic_helper" rollback-transaction \
                "$transaction" "$candidate" "$destination" \
                --preserve-candidate >/dev/null
            if [[ "$action" == rollback-preserve-swapped ]]; then
                verify_commitment "$destination" "$previous" "restored previous app"
                register_app "$destination"
                verify_commitment "$destination" "$previous" "registered previous app"
            fi
            echo "mutated incoming app remains quarantined at $candidate; manual inspection is required" >&2
            return 1
            ;;
        preserve-installed|preserve-swapped)
            if [[ "$action" == preserve-swapped ]]; then
                previous=$("$python" "$atomic_helper" commitment \
                    "$transaction" "$candidate" "$destination" previous)
                verify_commitment "$destination" "$previous" "restored previous app"
                register_app "$destination"
                verify_commitment "$destination" "$previous" "registered previous app"
            else
                if [[ -e "$destination" || -L "$destination" ]]; then
                    echo "quarantined first install unexpectedly remains active" >&2
                    return 1
                fi
                if ! "$python" "$quicklook_helper" absent \
                    "$destination/Contents/PlugIns/MarkDevQuickLook.appex"; then
                    echo "withdrawn Quick Look registration could not be proven absent" >&2
                fi
            fi
            echo "preserving quarantined incoming app at $candidate for manual inspection" >&2
            return 1
            ;;
        cleanup-installed)
            incoming=$("$python" "$atomic_helper" commitment \
                "$transaction" "$candidate" "$destination" incoming)
            verify_commitment "$candidate" "$incoming" "rolled-back incoming app"
            unregister_extension "$candidate" "$destination"
            "$python" "$atomic_helper" cleanup-transaction \
                "$transaction" "$candidate" "$destination"
            ;;
        cleanup-swapped)
            incoming=$("$python" "$atomic_helper" commitment \
                "$transaction" "$candidate" "$destination" incoming)
            previous=$("$python" "$atomic_helper" commitment \
                "$transaction" "$candidate" "$destination" previous)
            verify_commitment "$candidate" "$incoming" "rolled-back incoming app"
            verify_commitment "$destination" "$previous" "restored previous app"
            register_app "$destination"
            verify_commitment "$destination" "$previous" "registered previous app"
            "$python" "$atomic_helper" cleanup-transaction \
                "$transaction" "$candidate" "$destination"
            ;;
        resume-cleanup-allocating)
            "$python" "$atomic_helper" cleanup-transaction \
                "$transaction" "$candidate" "$destination"
            ;;
        resume-cleanup-finalized-installed|resume-cleanup-finalized-swapped)
            incoming=$("$python" "$atomic_helper" commitment \
                "$transaction" "$candidate" "$destination" incoming)
            verify_commitment "$destination" "$incoming" "activated app"
            if [[ "$action" == resume-cleanup-finalized-swapped \
                && ( -e "$candidate" || -L "$candidate" ) ]]; then
                previous=$("$python" "$atomic_helper" commitment \
                    "$transaction" "$candidate" "$destination" previous)
                verify_commitment "$candidate" "$previous" "held previous app"
            fi
            "$python" "$atomic_helper" cleanup-transaction \
                "$transaction" "$candidate" "$destination"
            ;;
        resume-cleanup-rolledback-installed|resume-cleanup-rolledback-swapped)
            if [[ "$action" == resume-cleanup-rolledback-swapped ]]; then
                previous=$("$python" "$atomic_helper" commitment \
                    "$transaction" "$candidate" "$destination" previous)
                verify_commitment "$destination" "$previous" "restored previous app"
            elif [[ -e "$destination" || -L "$destination" ]]; then
                echo "rolled-back first install unexpectedly has a destination" >&2
                return 1
            fi
            if [[ -e "$candidate" || -L "$candidate" ]]; then
                incoming=$("$python" "$atomic_helper" commitment \
                    "$transaction" "$candidate" "$destination" incoming)
                verify_commitment "$candidate" "$incoming" "rolled-back incoming app"
            fi
            "$python" "$atomic_helper" cleanup-transaction \
                "$transaction" "$candidate" "$destination"
            ;;
        finalize-installed|finalize-swapped)
            incoming=$("$python" "$atomic_helper" commitment \
                "$transaction" "$candidate" "$destination" incoming)
            verify_commitment "$destination" "$incoming" "activated app"
            if [[ "$action" == finalize-swapped ]]; then
                previous=$("$python" "$atomic_helper" commitment \
                    "$transaction" "$candidate" "$destination" previous)
                verify_commitment "$candidate" "$previous" "held previous app"
            fi
            register_app "$destination"
            verify_commitment "$destination" "$incoming" "registered activated app"
            if [[ "$action" == finalize-swapped ]]; then
                verify_commitment "$candidate" "$previous" "held previous app"
            fi
            "$python" "$atomic_helper" cleanup-transaction \
                "$transaction" "$candidate" "$destination"
            ;;
        *)
            echo "unknown recovery action; preserving $staging: $action" >&2
            return 1
            ;;
    esac
}

# Recovery happens under the installer-wide lock and before a new staging root
# is created. Multiple or malformed roots are ambiguous and are all preserved.
discovered=$("$python" "$atomic_helper" discover /Applications)
typeset -a abandoned
abandoned=( ${(f)discovered} )
if (( ${#abandoned} > 1 )); then
    echo "multiple abandoned MarkDev transactions require manual recovery:" >&2
    for path in "${abandoned[@]}"; do
        echo "  $path" >&2
    done
    exit 1
elif (( ${#abandoned} == 1 )); then
    echo "recovering abandoned MarkDev transaction: $abandoned[1]" >&2
    recover_transaction "$abandoned[1]"
fi

if [[ -L "$destination" ]]; then
    echo "refusing to replace a symlink at $destination" >&2
    exit 1
fi

"$python" "$signing_helper" verify-installable "$source_app"

# Same-filesystem staging lets renameatx_np exchange an existing install without
# a missing-destination window. The journal is durable before the copy begins.
staging=$(/usr/bin/mktemp -d /Applications/.MarkDev-install.XXXXXX)
if [[ ! "$staging" =~ '^/Applications/\.MarkDev-install\.[A-Za-z0-9]+$' || -L "$staging" ]]; then
    echo "mktemp returned an unexpected installation staging path" >&2
    exit 1
fi
candidate=$staging/candidate.app
transaction=$staging/transaction.json

recover_on_exit() {
    local status=$?
    trap - EXIT HUP INT TERM
    if (( status != 0 )) && [[ -d "$staging" && ! -L "$staging" ]]; then
        echo "installation did not activate; recovering from its durable journal" >&2
        if ! recover_transaction "$staging"; then
            echo "automatic recovery was not provably safe; preserving $staging" >&2
        fi
    fi
    exit $status
}
trap recover_on_exit EXIT
trap 'exit 130' HUP INT TERM

"$python" "$atomic_helper" initialize \
    "$candidate" "$destination" --state-file "$transaction"
run_bounded 300 /usr/bin/ditto "$source_app" "$candidate"
"$python" "$signing_helper" verify-installable "$candidate"
incoming_commitment=$("$python" "$signing_helper" verify-restorable "$candidate")

previous_commitment=
if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ ! -d "$destination" || -L "$destination" ]]; then
        echo "existing destination is not a real application directory" >&2
        exit 1
    fi
    previous_commitment=$("$python" "$signing_helper" verify-restorable "$destination")
fi

typeset -a install_arguments
install_arguments=(
    install "$candidate" "$destination"
    --state-file "$transaction"
    --candidate-commitment "$incoming_commitment"
)
if [[ -n "$previous_commitment" ]]; then
    install_arguments+=(--destination-commitment "$previous_commitment")
fi
"$python" "$atomic_helper" "${install_arguments[@]}" >/dev/null

verify_commitment "$destination" "$incoming_commitment" "installed app"
if [[ -n "$previous_commitment" ]]; then
    verify_commitment "$candidate" "$previous_commitment" "held previous app"
fi
"$python" "$atomic_helper" mark-phase "$transaction" "$candidate" "$destination" verified

appex=$destination/Contents/PlugIns/MarkDevQuickLook.appex
if [[ ! -d "$appex" || -L "$appex" ]]; then
    echo "installed app is missing its real Quick Look extension: $appex" >&2
    exit 1
fi

/usr/bin/killall -9 iconservicesagent 2>/dev/null || true
register_app "$destination"
verify_commitment "$destination" "$incoming_commitment" "registered installed app"
if [[ -n "$previous_commitment" ]]; then
    verify_commitment "$candidate" "$previous_commitment" "held previous app"
fi
"$python" "$atomic_helper" mark-phase "$transaction" "$candidate" "$destination" activated
"$python" "$atomic_helper" cleanup-transaction \
    "$transaction" "$candidate" "$destination"

staging=
transaction=
trap - EXIT HUP INT TERM
/usr/bin/killall Dock 2>/dev/null || true
echo "installed $destination"
echo "verified Quick Look registration: $appex"
