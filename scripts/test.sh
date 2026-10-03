#!/bin/bash
# One test command for every suite (STEP_237). Usage: scripts/test.sh [Suite]
#
#   Suites: KvotarCore ClaudeAdapter CodexAdapter KvotarUI KvotarCLI KvotarTests (the app tests)
#
# - Every inherited KVOTAR_* variable is removed, so opt-in live, replay and snapshot tests skip.
# - Build output goes to $KVOTAR_BUILD_DIR (default ${TMPDIR:-/tmp}/kvotar-build), never into the
#   source tree; the generated Kvotar.xcodeproj (gitignored) is the one exception.
# - Every suite runs even after one fails; full logs land in $BUILD/logs/<suite>.log.
# - A skipped test must be listed in scripts/expected-skips.tsv. An unlisted skip, a listed test
#   that was not discovered, a suite with zero tests, and output that cannot be parsed or that
#   disagrees with XCTest's own summary line all fail the run.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp="${TMPDIR:-/tmp}"
BUILD="${KVOTAR_BUILD_DIR:-${tmp%/}/kvotar-build}"
SKIPS="scripts/expected-skips.tsv"

for v in $(compgen -e); do
    case "$v" in KVOTAR_*) unset "$v" ;; esac
done

ALL="KvotarCore ClaudeAdapter CodexAdapter KvotarUI KvotarCLI KvotarTests"
if [ $# -gt 1 ]; then
    echo "usage: scripts/test.sh [Suite]   (one of: $ALL)" >&2
    exit 2
elif [ $# -eq 1 ]; then
    case " $ALL " in
        *" $1 "*) SUITES="$1" ;;
        *) echo "unknown suite '$1' (one of: $ALL)" >&2; exit 2 ;;
    esac
else
    SUITES="$ALL"
fi
[ -f "$SKIPS" ] || { echo "missing $SKIPS" >&2; exit 2; }

mkdir -p "$BUILD/logs"
REPORT="$BUILD/logs/report.txt"
: > "$REPORT"

run_suite() {
    local suite="$1" log="$BUILD/logs/$1.log"
    echo "==> $suite (log: $log)"
    if [ "$suite" = KvotarTests ]; then
        if (xcodegen generate &&
            xcodebuild test -project Kvotar.xcodeproj -scheme KvotarTests \
                -destination platform=macOS -derivedDataPath "$BUILD/xcode" \
                CODE_SIGNING_ALLOWED=NO) > "$log" 2>&1; then
            RC=0
        else
            RC=$?
        fi
    else
        if swift test --package-path "Packages/$suite" --scratch-path "$BUILD/$suite" \
            > "$log" 2>&1; then
            RC=0
        else
            RC=$?
        fi
    fi
}

# Reads the list and one suite's log; appends ROW / PROBLEM / NOTE lines to the report.
check_suite() {
    local suite="$1" rc="$2" log="$BUILD/logs/$1.log"
    awk -v suite="$suite" -v rc="$rc" '
        FNR == NR {
            if (FNR > 1 && $0 != "") {
                split($0, c, "\t")
                if (c[1] == suite) { expected[c[2]] = 1; nexp++ }
            }
            next
        }
        /^Test Case .-\[[^ ]+ [^ ]+\]. (passed|failed|skipped) / {
            s = $0
            sub(/^Test Case .-\[/, "", s)
            i = index(s, "]")
            split(substr(s, 1, i - 1), p, " ")
            rest = substr(s, i + 3)
            split(rest, q, " ")
            name = p[1] "/" p[2]
            if (!(name in status)) order[++n] = name
            status[name] = q[1]
            next
        }
        /^Test Suite .(All|Selected) tests. (passed|failed) / { want = 1; next }
        # XCTest drops the "N tests skipped and" clause when nothing skipped.
        want && /Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures?/ {
            summary = $0; want = 0
        }
        END {
            passed = failed = skipped = unexpected = expectedSkips = 0
            for (k = 1; k <= n; k++) {
                name = order[k]; st = status[name]
                if (st == "passed") passed++
                else if (st == "failed") { failed++; print "PROBLEM\t" suite ": test failed: " name }
                else if (st == "skipped") {
                    skipped++
                    if (name in expected) expectedSkips++
                    else { unexpected++; print "PROBLEM\t" suite ": unexpected skip (not in expected-skips.tsv): " name }
                }
            }
            for (name in expected) {
                if (!(name in status)) print "PROBLEM\t" suite ": stale expected-skips.tsv entry, test not discovered: " name
                else if (status[name] != "skipped") print "NOTE\t" suite ": listed test ran instead of skipping (" status[name] "): " name
            }
            if (rc != 0) print "PROBLEM\t" suite ": exit code " rc
            if (n == 0) print "PROBLEM\t" suite ": zero tests discovered (or no parseable test results)"
            if (summary == "") {
                print "PROBLEM\t" suite ": no XCTest summary line found — results cannot be trusted"
            } else {
                e = summary; sub(/.*Executed /, "", e); e += 0
                s = 0
                if (summary ~ / skipped and /) { s = summary; sub(/.* with /, "", s); s += 0 }
                f = summary; sub(/.* with ([0-9]+ tests? skipped and )?/, "", f); f += 0
                if (e != n || s != skipped || (f > 0) != (failed > 0))
                    print "PROBLEM\t" suite ": parsed " n " tests / " skipped " skipped / " failed " failed, XCTest says: " summary
            }
            printf "ROW\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", suite, n, passed, expectedSkips, unexpected, failed, rc
        }
    ' "$SKIPS" "$log" >> "$REPORT"
}

for suite in $SUITES; do
    run_suite "$suite"
    check_suite "$suite" "$RC"
done

echo
printf '%-14s %10s %7s %20s %7s %5s\n' suite discovered passed "skipped (exp/unexp)" failed exit
awk -F'\t' '$1 == "ROW" {
    printf "%-14s %10d %7d %20s %7d %5d\n", $2, $3, $4, $5 " / " $6, $7, $8
}' "$REPORT"
echo
grep '^NOTE' "$REPORT" | cut -f2- | sed 's/^/note: /' || true
if grep -q '^PROBLEM' "$REPORT"; then
    grep '^PROBLEM' "$REPORT" | cut -f2- | sed 's/^/FAIL: /'
    echo
    echo FAIL
    exit 1
fi
echo PASS
