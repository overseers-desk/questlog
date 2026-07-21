#!/usr/bin/env bash
# Run the whole test suite with the StreamTree and StreamDoc structural audit
# gates on.
#
# Each test is a standalone script that prints PASS/FAILED and exits with its
# failure count. With STREAMTREE_AUDIT / STREAMDOC_AUDIT set, every primitive
# mutation also checks its mark invariant and, on the first desync, latches and
# writes an "INVARIANT @ ..." line to stderr. A test can desync a mark yet still
# print PASS (it never inspects the latch), so a green test is not enough: this
# runner fails the suite on a non-zero test exit OR on any INVARIANT line.
#
# A Tk test runs under wish9.0 on a private Xvfb :99 (never the user's :0, where
# its windows would land over their work). A test with no `package require Tk` is
# a CLI test and runs under tclsh9.0: under wish it would fall off the script end
# into the event loop and hang, since only failing CLI tests call exit.
set -u
cd "$(dirname "$0")/.."

Xvfb :99 -screen 0 1500x1150x24 >/tmp/ql-audit-xvfb.log 2>&1 &
xvfb=$!
sleep 2

export STREAMTREE_AUDIT=1
export STREAMDOC_AUDIT=1
fails=0
for t in test/test-*.tcl; do
    if grep -qE '^[[:space:]]*package require Tk' "$t"; then
        err=$(DISPLAY=:99 timeout 90 wish9.0 "$t" 2>&1 >/dev/null); code=$?
    else
        err=$(timeout 90 tclsh9.0 "$t" 2>&1 >/dev/null); code=$?
    fi
    status="ok"
    if [ "$code" -eq 124 ]; then status="TIMEOUT"; fails=$((fails+1)); fi
    if [ "$code" -ne 0 ] && [ "$code" -ne 124 ]; then status="FAIL(exit $code)"; fails=$((fails+1)); fi
    if printf '%s' "$err" | grep -q 'INVARIANT @'; then
        status="INVARIANT"; fails=$((fails+1))
        printf '%s\n' "$err" | grep 'INVARIANT @'
    fi
    printf '%-44s %s\n' "$t" "$status"
done

kill "$xvfb" 2>/dev/null
echo "----"
[ "$fails" -eq 0 ] && echo "AUDIT SUITE PASS" || echo "AUDIT SUITE FAILED ($fails)"
exit "$fails"
