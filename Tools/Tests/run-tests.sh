#!/bin/zsh
# Runs the macOS unit tests (OfflineKitTests, Swift Testing) and prints a short summary.
#
# usage: Tools/Tests/run-tests.sh [extra xcodebuild arguments, e.g. -only-testing:OfflineKitTests/WebServerTests]
#
# Regenerates the Xcode project, builds into a derived-data folder under $TMPDIR (never ./build), and runs the
# tests with a fresh stand-in home (OFFLINEKIT_HOME) under /tmp, so settings, caches and test keys never touch
# ~/OfflineKit, this Mac's preferences or the Keychain. The full log is kept for a failed run.
set -u
cd "$(dirname "$0")/../.."

command -v xcodegen >/dev/null || { echo "XcodeGen is needed: brew install xcodegen"; exit 1; }
xcodegen generate --quiet || exit 1

derived="${TMPDIR:-/tmp}/OfflineKitTests-DerivedData"
home=$(mktemp -d /tmp/OfflineKitTests-home.XXXXXX)
log=$(mktemp "${TMPDIR:-/tmp}/OfflineKitTests-log.XXXXXX")
trap 'rm -rf "$home"' EXIT

started=$SECONDS
# xcodebuild hands TEST_RUNNER_-prefixed variables to the test process without the prefix.
TEST_RUNNER_OFFLINEKIT_HOME="$home" xcodebuild test \
    -project OfflineKit.xcodeproj -scheme OfflineKitTests -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO "$@" > "$log" 2>&1
code=$?
elapsed=$(( SECONDS - started ))

echo "== Offline Kit unit tests =="
# XCTest lists every Objective-C class in the process (objc_copyClassList) to find test cases. That sets up the Swift
# classes in ContactsUICore, loaded with the system frameworks, and CNContactStore's +initialize then checks Contacts
# access, which fails in the unhosted test process and logs CoreData errors about contactsd and AddressBook. App code
# never calls Contacts (no such errors or TCC requests in app runs), so those lines are left out here.
grep -E '^.{0,4}(error:|.*: error:)' "$log" | grep -v '^warning' | grep -vE 'contactsd|AddressBook' | head -20
grep -E 'recorded an issue' "$log" | grep -v 'known issue' | sed -E 's/^[^A-Za-z]*//' | head -40
known=$(grep -cE 'recorded a known issue' "$log")
grep -E 'Test run with [0-9]+ tests' "$log" | sed -E 's/^[^A-Za-z]*//' | tail -1
[[ $known -gt 0 ]] && echo "Known issues recorded: $known (listed with withKnownIssue in the tests)"
echo "Build and test time: ${elapsed}s"
if [[ $code -eq 0 ]]; then
    echo "PASSED"
    rm -f "$log"
else
    echo "FAILED (xcodebuild exit $code). Full log: $log"
fi
exit $code
