#!/bin/zsh
# First-run smoke test: a brand-new user walks through setup against a local stand-in for the Kiwix servers.
#
# usage: Tools/Tests/first-run-smoke.sh [--drop] [--keep] [--no-build]
#   --drop      throttles the server and stops it in the middle of the downloads, then brings it back
#   --keep      keeps the temporary folder (screenshots, logs, test home) and prints where it is
#   --no-build  reuses the Debug build from the last run
#
# What it does: builds the Debug app, writes tiny test archives, starts Tools/Tests/first-run-server.py on a free
# loopback port, then launches the app twice in a fresh OFFLINEKIT_HOME with OFFLINEKIT_TEST_SERVER set (Debug and
# test home only, see LocalTestServer in Catalog.swift). Run 1 presses through the setup (-onboardingScript) and
# downloads; run 2 reopens the app and asks a question (-autoAsk). It checks that every archive arrived with the
# right size, the answer index was built for each, and the first answer has a source. Screenshots land in the
# temporary folder. Nothing touches ~/OfflineKit, /Volumes or the Keychain; it stops only what it started.
set -u
cd "$(dirname "$0")/../.."
drop=0; keep=0; build=1
for a in "$@"; do case $a in --drop) drop=1;; --keep) keep=1;; --no-build) build=0;; esac; done

# A sleeping Mac stops the app's timers and the downloads: stay awake for as long as this script runs.
caffeinate -dims -w $$ &

work=$(mktemp -d "${TMPDIR:-/tmp}/okit-first-run.XXXXXX")
derived="${TMPDIR:-/tmp}/OfflineKitFirstRun-DerivedData"
home=$work/home; fix=$work/fixtures; shots=$work/shots; mkdir -p "$home" "$fix" "$shots"
server_pid=""; app_pid=""; fails=0
cleanup() {
    [[ -n $app_pid ]] && kill $app_pid 2>/dev/null
    [[ -n $server_pid ]] && kill $server_pid 2>/dev/null
    if (( keep )); then echo "Kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT
check() { # name, condition result (0 = pass), detail
    if [[ $2 -eq 0 ]]; then echo "PASS  $1"; else echo "FAIL  $1 ${3:-}"; fails=$((fails+1)); fi
}

if (( build )); then
    echo "Building the Debug app..."
    xcodegen generate --quiet || exit 1
    xcodebuild -project OfflineKit.xcodeproj -scheme OfflineKit-macOS -configuration Debug -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO build -quiet > "$work/build.log" 2>&1
fi
app="$derived/Build/Products/Debug/Offline Kit.app/Contents/MacOS/Offline Kit"
[[ -x $app ]] || { echo "No Debug build at $app (see $work/build.log)"; keep=1; exit 1; }

echo "Writing test archives..."
python3 Tools/Tests/make-tiny-zim.py "$fix/tiny.zim" > /dev/null || exit 1
python3 Tools/Tests/make-tiny-zim.py "$fix/tiny-indexed.zim" --index > /dev/null || exit 1
python3 Tools/Tests/make-test-zim/make-test-zim.py "$fix" > /dev/null || exit 1

rate=0; (( drop )) && rate=1200000
start_server() { # optional fixed port
    local extra=(); [[ -n ${1:-} ]] && extra=(--port $1)
    : > "$work/server.out"
    python3 -I Tools/Tests/first-run-server.py "$fix" --rate $rate --log "$work/server.log" $extra > "$work/server.out" 2>&1 &
    server_pid=$!
    for _ in {1..40}; do [[ -s $work/server.out ]] && break; sleep 0.25; done
}
start_server
port=$(head -1 "$work/server.out")
[[ -n $port ]] || { echo "Server did not start"; keep=1; exit 1; }
lsof -nP -iTCP:$port -sTCP:LISTEN > /dev/null || { echo "Port $port is not listening"; exit 1; }
echo "Local server on 127.0.0.1:$port"

launch() { # log name, args...
    local name=$1; shift
    OFFLINEKIT_HOME=$home OFFLINEKIT_TEST_SERVER=http://127.0.0.1:$port "$app" -NSAppSleepDisabled YES "$@" > "$work/$name.log" 2>&1 &
    app_pid=$!
}
lib=$home/OfflineKit/Library
expected=(mdwiki_en_all_maxi_2026-10.zim:practical.zim wikipedia_en_medicine_maxi_2026-10.zim:encyclopedia.zim
          ready.gov_en_all_2026-10.zim:tiny.zim zimgit-water_en_2026-10.zim:tiny-indexed.zim)

echo "Run 1: setup and downloads"
launch run1 -showOnboarding YES -onboardingGap 1.5 \
    -onboardingScript "next,next,areas:emergency+health,next,next,next,download,wait:2,progress" \
    -snapshot "$shots" -snapshotAt "2,4,6,8,10,12,14,17" -snapshotSize 1100x780
if (( drop )); then
    sleep 22; kill $server_pid; server_pid=""; echo "  server stopped mid-download"
    sleep 20; start_server $port; echo "  server back"
fi
done_all=1
for _ in {1..120}; do
    done_all=0
    for pair in $expected; do
        f=$lib/${pair%%:*}; src=$fix/${pair##*:}
        [[ -f $f && $(stat -f %z "$f") -eq $(stat -f %z "$src") ]] || done_all=1
    done
    (( done_all == 0 )) && break
    sleep 1
done
check "all four archives downloaded with the right size" $done_all
for pair in $expected; do
    f=$lib/${pair%%:*}
    [[ -f $f ]] && check "checksum ${pair%%:*}" $([[ $(shasum -a 256 < "$f" | cut -d' ' -f1) == $(shasum -a 256 < "$fix/${pair##*:}" | cut -d' ' -f1) ]] && echo 0 || echo 1)
done
check "unticked large and video packs were not requested" $(grep -qE "armypubs|ted_mul" "$work/server.log" && echo 1 || echo 0)
check "nothing was left half-downloaded" $([[ -z $(ls "$lib" | grep -E '\.(part|okdl)$') ]] && echo 0 || echo 1)
# The answer index builds after the downloads: one database per archive.
idx=1
for _ in {1..60}; do
    [[ $(ls "$home/Library/Caches/OfflineKit/answer-index" 2>/dev/null | grep -c '\.sqlite$') -ge 4 ]] && { idx=0; break; }
    sleep 1
done
check "answer index built for all four archives" $idx
for _ in {1..40}; do ls "$shots" | grep -q '^17s' && break; sleep 1; done   # the last picture is taken
sleep 2
kill $app_pid 2>/dev/null; wait $app_pid 2>/dev/null; app_pid=""
check "setup screens were captured" $([[ $(ls "$shots" | grep -c sheet) -ge 6 ]] && echo 0 || echo 1)

echo "Run 2: reopen and ask"
launch run2 -autoAsk "How do I treat heat stroke?" -snapshot "$shots" -snapshotAt "25" -snapshotSize 1100x780
for _ in {1..90}; do grep -q '^DONE' "$home/asklog.txt" 2>/dev/null && break; sleep 1; done
log=$home/asklog.txt
check "Ask finished" $(grep -q '^DONE' "$log" 2>/dev/null && echo 0 || echo 1)
check "the answer names a source from the downloaded archive" $(grep -E '^sources: .+' "$log" 2>/dev/null | grep -qi 'heat stroke' && echo 0 || echo 1)
if grep -q 'error: none' "$log" 2>/dev/null; then
    check "the answer cites its source" $(grep -q '\[1\]' "$log" && echo 0 || echo 1)
else
    echo "SKIP  answer text: no answer engine was available here ($(grep -m1 -o 'error: .*' "$log" 2>/dev/null))"
fi
sleep 2
echo
if (( fails == 0 )); then echo "First-run smoke test PASSED"; else echo "First-run smoke test FAILED ($fails)"; keep=1; fi
echo "Screenshots: $shots"
exit $(( fails > 0 ))
