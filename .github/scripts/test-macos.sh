#!/bin/bash
set -eo pipefail

log="$RUNNER_TEMP/package-tests.log"
host="$RUNNER_TEMP/agroom-window-test-host"
platform_dir=$(xcrun --sdk macosx --show-sdk-platform-path)
frameworks="$platform_dir/Developer/Library/Frameworks"
bin_dir=$(swift build --build-system native --show-bin-path)
export AGROOM_TEST_BUNDLE="$bin_dir/AgRoomPackageTests.xctest"
xcrun --sdk macosx swiftc -parse-as-library -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
    ../.github/scripts/macos-test-host.swift -o "$host"
touch "$log"
belongs_to_this_run() {
    local ancestor=$1
    while (( ancestor > 1 )); do
        if (( ancestor == $$ )); then return 0; fi
        read -r ancestor < <(ps -o ppid= -p "$ancestor") || return 1
    done
    return 1
}
(
    while sleep 60; do
        if (( $(date +%s) - $(stat -f %m "$log") < 120 )); then
            continue
        fi
        echo "No test output for two minutes. Sampling the test process."
        ps -ax -o pid=,comm= |
            awk '$NF ~ /\/agroom-window-test-host$/ {print $1}' |
        while read -r pid; do
            belongs_to_this_run "$pid" || continue
            stack="$RUNNER_TEMP/package-tests-$pid.sample"
            /usr/bin/sample "$pid" 2 12 -file "$stack" >/dev/null 2>&1 || continue
            # Show test call sites and their callees without dumping binary paths.
            awk '/Binary Images:/ {exit} /Tests\.swift:[0-9]+/ {context=12}
                 context>0 {print; context--; if (++lines>=140) exit}' "$stack"
            if grep -Fq 'NSWindow.sendTestClick' "$stack" && grep -Fq 'trackMouse:inRect:ofView:untilMouseUp:' "$stack"; then
                echo "::error::The synthetic click is blocked waiting for a mouse release."
                kill -TERM "$pid" || true
            fi
        done
        break
    done
) &
observer=$!
trap 'kill "$observer" 2>/dev/null || true' EXIT

# A pseudo-terminal flushes each Swift Testing event to Actions. On macOS
# script returns the test command's status, including assertion failures.
/usr/bin/script -q /dev/null /usr/bin/env DYLD_FRAMEWORK_PATH="$frameworks" \
    DYLD_LIBRARY_PATH="$platform_dir/Developer/usr/lib" "$host" --no-parallel "$1" ProductTaskCenterHostTests | tee "$log"
if ! grep -Eq 'Test run with [1-9][0-9]* tests? (in [1-9][0-9]* suites? )?passed after' "$log"; then
    echo "::error::Swift Testing exited without reporting a completed suite."
    exit 1
fi
