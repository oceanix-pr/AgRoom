#!/bin/bash
set -eo pipefail

log="$RUNNER_TEMP/package-tests.log"
touch "$log"
(
    while sleep 60; do
        if (( $(date +%s) - $(stat -f %m "$log") < 120 )); then
            continue
        fi
        echo "No test output for two minutes. Sampling the test process."
        ps -ax -o pid=,comm= |
            awk '$NF ~ /\/(swiftpm-testing-helper|swift-testing-helper|AgRoomPackageTests|xctest)$/ {print $1}' |
        while read -r pid; do
            stack="$RUNNER_TEMP/package-tests-$pid.sample"
            /usr/bin/sample "$pid" 2 12 -file "$stack" >/dev/null 2>&1 || continue
            # Show test call sites and their callees without dumping binary paths.
            awk '/Binary Images:/ {exit} /Tests\.swift:[0-9]+/ {context=12}
                 context>0 {print; context--; if (++lines>=140) exit}' "$stack"
        done
        break
    done
) &
observer=$!
trap 'kill "$observer" 2>/dev/null || true' EXIT

# A pseudo-terminal flushes each Swift Testing event to Actions. On macOS
# script returns the test command's status, including assertion failures.
/usr/bin/script -q /dev/null swift test --skip-build --build-system native \
    --force-resolved-versions --no-parallel "$1" ProductTaskCenterHostTests | tee "$log"
if ! grep -Eq 'Test run with [1-9][0-9]* tests? (in [1-9][0-9]* suites? )?passed after' "$log"; then
    echo "::error::Swift Testing exited without reporting a completed suite."
    exit 1
fi
