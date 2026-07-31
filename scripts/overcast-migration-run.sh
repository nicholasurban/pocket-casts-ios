#!/usr/bin/env bash
#
# One entry point for the Overcast to Pocket Casts migration.
#
#   scripts/overcast-migration-run.sh probe        # small proof that sync works
#   scripts/overcast-migration-run.sh production   # the real thing
#
# Both modes: confirm the Overcast database has settled, export a fresh bundle,
# install the migration build on a simulator, sign that simulator into the real
# Pocket Casts account, run the importer, then read the sync server back to
# prove the data actually left the device.
#
# Credentials are read from ~/.claude/.env and passed to the simulator through
# the environment. They are never written into this repository.

set -euo pipefail

MODE="${1:-}"
if [[ "$MODE" != "probe" && "$MODE" != "production" ]]; then
    echo "usage: $0 {probe|production} [--bundle DIR] [--skip-stability] [--skip-build]" >&2
    exit 2
fi
shift || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_DIR=""
SKIP_STABILITY=0
SKIP_BUILD=0
STABILITY_SAMPLES="${STABILITY_SAMPLES:-3}"
STABILITY_INTERVAL="${STABILITY_INTERVAL:-60}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle) BUNDLE_DIR="$2"; shift 2 ;;
        --skip-stability) SKIP_STABILITY=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

OVERCAST_DB="${OVERCAST_DB:-/Users/urbs/Library/Containers/4CCCADE0-33F2-45A3-8E1B-B96EF6247C5C/Data/Documents/db.sqlite}"
SIMULATOR_NAME="${SIMULATOR_NAME:-PocketCasts-Overcast-Migration-Run}"
DEVICE_TYPE="${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max}"
# Derived data must live OUTSIDE the repository. Xcode puts Swift package
# checkouts inside it, and the SwiftLint build phase lints everything under the
# repo root, so an in-repo path makes the build fail on lint violations inside
# third-party package tests.
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/overcast-migration}"
STAMP="$(date +%Y%m%d-%H%M%S)"
EVIDENCE_ROOT="${EVIDENCE_ROOT:-$HOME/Documents/Overcast Migration Runs}"
RUN_DIR="$EVIDENCE_ROOT/$MODE-$STAMP"
mkdir -p "$RUN_DIR"

log() { printf '\n=== %s ===\n' "$*"; }

log "Run directory"
echo "$RUN_DIR"

# ---------------------------------------------------------------- credentials
read_env_value() {
    python3 - "$1" <<'PY'
import os, re, sys
from pathlib import Path
name = sys.argv[1]
value = os.environ.get(name)
if not value:
    text = Path(Path.home() / ".claude" / ".env").read_text()
    match = re.search(rf"^{name}='(.*)'$", text, re.M) or re.search(rf'^{name}="(.*)"$', text, re.M)
    value = match.group(1) if match else ""
print(value)
PY
}

PC_EMAIL="$(read_env_value POCKETCASTS_EMAIL)"
PC_PASSWORD="$(read_env_value POCKETCASTS_PASSWORD)"
if [[ -z "$PC_EMAIL" || -z "$PC_PASSWORD" ]]; then
    echo "Pocket Casts credentials not found in ~/.claude/.env" >&2
    exit 1
fi
echo "Account: $PC_EMAIL"

# ------------------------------------------------------------------ stability
if [[ "$SKIP_STABILITY" -eq 0 ]]; then
    log "Checking the Overcast database has settled"
    # A source still in motion means Nick is mid-deletion or Overcast is still
    # syncing, which is a reason to wait rather than to abandon a scheduled
    # run. Retry until it settles; only give up after the whole window.
    STABILITY_ATTEMPT=1
    until python3 scripts/overcast-source-stability.py "$OVERCAST_DB" \
        --samples "$STABILITY_SAMPLES" --interval "$STABILITY_INTERVAL" \
        --json "$RUN_DIR/source-stability.json"; do
        if (( STABILITY_ATTEMPT >= ${STABILITY_RETRIES:-12} )); then
            echo "source still changing after ${STABILITY_RETRIES:-12} attempts; not exporting" >&2
            exit 1
        fi
        echo "  still changing; waiting ${STABILITY_RETRY_WAIT:-300}s (attempt $STABILITY_ATTEMPT)"
        sleep "${STABILITY_RETRY_WAIT:-300}"
        STABILITY_ATTEMPT=$(( STABILITY_ATTEMPT + 1 ))
    done
else
    echo "(stability check skipped)"
fi

# --------------------------------------------------------------------- export
if [[ -z "$BUNDLE_DIR" ]]; then
    BUNDLE_DIR="$RUN_DIR/bundle"
    log "Exporting a fresh bundle from Overcast"
    # Probe and production export identically. The bundle loader requires
    # downloaded-audio-inventory.json, which only --include-downloaded-audio
    # writes, and the audio copy uses APFS clones so it costs almost nothing.
    # The two modes differ at import time instead: rehearsal imports a single
    # proof-of-path audio file, production imports them all.
    python3 scripts/overcast-migration-export.py "$OVERCAST_DB" \
        --output "$BUNDLE_DIR" --include-downloaded-audio
else
    log "Reusing bundle"
    echo "$BUNDLE_DIR"
fi
python3 -c "
import json,sys
manifest=json.load(open('$BUNDLE_DIR/manifest.json'))
print('bundle counts:',json.dumps(manifest['counts'],sort_keys=True))
print('test_only:',manifest['test_only'])
"

# ---------------------------------------------------------------------- build
# The Debug configuration, NOT StagingDebug. `podcasts/ServerSyncManager.swift`
# returns production() == false under `#if STAGING`, which points every server
# URL at pocketcasts.net — a separate staging backend where the real account
# does not exist. Debug keeps the `#if DEBUG` migration hooks while talking to
# the production API.
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/podcasts.app"
if [[ "$SKIP_BUILD" -eq 0 || ! -d "$APP_PATH" ]]; then
    log "Building the migration app"
    xcodebuild -project podcasts.xcodeproj \
        -scheme "pocketcasts" \
        -configuration Debug \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED_DATA" \
        build > "$RUN_DIR/build.log" 2>&1 || {
            echo "build failed; see $RUN_DIR/build.log" >&2
            tail -30 "$RUN_DIR/build.log" >&2
            exit 1
        }
fi
[[ -d "$APP_PATH" ]] || { echo "app not found at $APP_PATH" >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
echo "App: $APP_PATH"
echo "Bundle id: $BUNDLE_ID"

# ------------------------------------------------------------------ simulator
log "Preparing a clean simulator"
EXISTING="$(xcrun simctl list devices | awk -v n="$SIMULATOR_NAME" '$0 ~ n {match($0,/\(([-0-9A-F]{36})\)/,m); print m[1]; exit}' 2>/dev/null || true)"
if [[ -z "$EXISTING" ]]; then
    EXISTING="$(xcrun simctl list devices | grep -F "$SIMULATOR_NAME (" | head -1 | sed -E 's/.*\(([-0-9A-F]{36})\).*/\1/' || true)"
fi
if [[ -n "$EXISTING" ]]; then
    echo "Erasing existing simulator $EXISTING"
    xcrun simctl shutdown "$EXISTING" >/dev/null 2>&1 || true
    xcrun simctl erase "$EXISTING"
    UDID="$EXISTING"
else
    RUNTIME="$(xcrun simctl list runtimes | grep -E '^iOS' | tail -1 | sed -E 's/.*(com\.apple\.CoreSimulator\.SimRuntime\.iOS[^ ]*).*/\1/')"
    UDID="$(xcrun simctl create "$SIMULATOR_NAME" "$DEVICE_TYPE" "$RUNTIME")"
    echo "Created simulator $UDID"
fi
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP_PATH"

# Launch once so the data container exists, then stage the bundle inside it.
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
sleep 5
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
echo "Container: $CONTAINER"
rm -rf "$CONTAINER/Documents/OvercastMigrationQA"
mkdir -p "$CONTAINER/Documents"
cp -R "$BUNDLE_DIR" "$CONTAINER/Documents/OvercastMigrationQA"

# ------------------------------------------------------------------------ run
if [[ "$MODE" == "production" ]]; then
    LAUNCH_ARG="--overcast-migration-full-production"
else
    LAUNCH_ARG="--overcast-migration-full-qa"
fi

log "Running the migration ($MODE)"
echo "Server state before:"
python3 scripts/pocketcasts-account-audit.py --json "$RUN_DIR/server-before.json" | sed 's/^/  /'

SIMCTL_CHILD_OVERCAST_MIGRATION_PC_EMAIL="$PC_EMAIL" \
SIMCTL_CHILD_OVERCAST_MIGRATION_PC_PASSWORD="$PC_PASSWORD" \
    xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" "$LAUNCH_ARG" \
    > "$RUN_DIR/app-console.log" 2>&1 &
LAUNCH_PID=$!

# Memory ceiling. On 2026-07-30 the importer held every episode of every show
# in memory at once, reached 16 GB, and took the whole machine down with it.
# The leak is fixed, but no migration run should ever again be able to do that,
# whatever the cause — so watch the simulated app's resident size and kill the
# run if it crosses the limit.
MEMORY_LIMIT_MB="${MEMORY_LIMIT_MB:-4096}"
(
    while sleep 20; do
        APP_PID="$(pgrep -f 'podcasts.app/podcasts' | head -1)"
        [[ -z "$APP_PID" ]] && continue
        RSS_MB=$(( $(ps -o rss= -p "$APP_PID" 2>/dev/null || echo 0) / 1024 ))
        if (( RSS_MB > MEMORY_LIMIT_MB )); then
            echo "[memory-guard] podcasts reached ${RSS_MB}MB (limit ${MEMORY_LIMIT_MB}MB); killing the run" \
                | tee -a "$RUN_DIR/memory-guard.log" >&2
            kill -9 "$APP_PID" 2>/dev/null
            kill "$LAUNCH_PID" 2>/dev/null
            exit 1
        fi
        echo "$(date -u +%H:%M:%S) ${RSS_MB}MB" >> "$RUN_DIR/memory.log"
    done
) &
MEMORY_GUARD_PID=$!
trap 'kill "$MEMORY_GUARD_PID" 2>/dev/null || true' EXIT

REPORT="$CONTAINER/Documents/OvercastMigrationQACompleteReport.txt"
log "Waiting for the reconciliation report"
DEADLINE=$(( SECONDS + ${RUN_TIMEOUT:-5400} ))
while (( SECONDS < DEADLINE )); do
    if [[ -f "$REPORT" ]]; then
        # The runner writes the report last; give it a moment to finish.
        sleep 20
        break
    fi
    if grep -qE "ABORTED|\[overcast-migration\] FAILED" "$RUN_DIR/app-console.log" 2>/dev/null; then
        echo "migration failed:" >&2
        grep -E "ABORTED|\[overcast-migration\] FAILED" "$RUN_DIR/app-console.log" >&2
        echo "--- last status transitions ---" >&2
        grep "\[overcast-migration\]" "$RUN_DIR/app-console.log" | tail -10 >&2
        exit 1
    fi
    sleep 15
done
if [[ ! -f "$REPORT" ]]; then
    kill "$LAUNCH_PID" >/dev/null 2>&1 || true
    echo "no reconciliation report after $(( ${RUN_TIMEOUT:-5400} / 60 )) minutes; see $RUN_DIR/app-console.log" >&2
    exit 1
fi

# The report only means the local writes finished. Pocket Casts uploads that
# state in the background afterwards, and draining ten thousand episode rows
# takes far longer than writing them. Killing the app here would upload a
# fraction of the migration while every local number looked perfect, so wait
# for the queue to drain with the app still running.
APP_DB="$CONTAINER/Library/Application Support/Pocket Casts/podcast_newDB.sqlite3"
log "Waiting for the upload queue to drain"
DRAIN_DEADLINE=$(( SECONDS + ${DRAIN_TIMEOUT:-7200} ))
LAST_PENDING=""
STALLED_POLLS=0
while (( SECONDS < DRAIN_DEADLINE )); do
    if PENDING_LINE=$(python3 scripts/pocketcasts-pending-sync.py "$APP_DB" 2>/dev/null); then
        echo "  $PENDING_LINE — drained"
        break
    fi
    echo "  $PENDING_LINE"
    if [[ "$PENDING_LINE" == "$LAST_PENDING" ]]; then
        STALLED_POLLS=$(( STALLED_POLLS + 1 ))
    else
        STALLED_POLLS=0
    fi
    LAST_PENDING="$PENDING_LINE"
    # Pocket Casts syncs on its own cadence; a genuinely stuck queue stops
    # moving entirely rather than slowing down.
    if (( STALLED_POLLS >= ${DRAIN_STALL_POLLS:-20} )); then
        echo "  upload queue stopped moving; leaving the app running for inspection" >&2
        break
    fi
    sleep 30
done
python3 scripts/pocketcasts-pending-sync.py "$APP_DB" --json "$RUN_DIR/pending-sync-final.json" || true

kill "$LAUNCH_PID" >/dev/null 2>&1 || true

cp "$REPORT" "$RUN_DIR/OvercastMigrationReport.txt"
cp -R "$CONTAINER/Documents/OvercastMigrationBackups" "$RUN_DIR/" 2>/dev/null || true

# --------------------------------------------------------------- verification
log "Reading the sync server back"
sleep 45
python3 scripts/pocketcasts-account-audit.py --json "$RUN_DIR/server-after.json" | sed 's/^/  /'

log "Local reconciliation summary"
sed -n '/Post-refresh destination audit/,$p' "$RUN_DIR/OvercastMigrationReport.txt" | head -30

log "Done"
echo "Evidence: $RUN_DIR"
echo "Simulator left booted as $UDID for inspection."
