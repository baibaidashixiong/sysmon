#!/usr/bin/env bash
# Smoke tests for sysmon.sh - run from the repository root.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fails=0
report() {
  if [[ $1 == 0 ]]; then
    printf 'ok   %s\n' "$2"
  else
    printf 'FAIL %s\n' "$2"
    fails=$(( fails + 1 ))
  fi
}

bash -n sysmon.sh
report $? 'syntax check'

./sysmon.sh -h >/dev/null 2>&1
report $? 'help exits 0'

./sysmon.sh -v | grep -q '^sysmon '
report $? 'version output'

./sysmon.sh -Z >/dev/null 2>&1
[[ $? -ne 0 ]]
report $? 'unknown option fails'

out=$(./sysmon.sh -i 1 -n 1 -p 2>&1)
report $? 'system mode runs'
grep -q '^CPU' <<<"$out"
report $? 'system mode reports CPU'
grep -q '^MEM' <<<"$out"
report $? 'system mode reports MEM'
grep -q '^NET' <<<"$out"
report $? 'system mode reports NET'
grep -q '^TOP MEM' <<<"$out"
report $? 'system mode reports TOP MEM'

out=$(./sysmon.sh -i 1 -n 1 -p -m 2>&1)
report $? 'expanded memory mode runs'
grep -q '^MEM   free' <<<"$out"
report $? 'expanded memory shows meminfo breakdown'

out=$(./sysmon.sh -i 1 -n 1 -p "$$" 2>&1)
report $? 'process mode runs'
grep -q '^PROC' <<<"$out"
report $? 'process mode reports PROC'
grep -q '^NET' <<<"$out"
report $? 'process mode reports NET sockets'
grep -q '^MEM' <<<"$out"
report $? 'process mode reports memory detail'
grep -q 'uptime ' <<<"$out"
report $? 'process mode reports uptime'

./sysmon.sh -i 1 -n 1 -p NoSuchProcessXyz >/dev/null 2>&1
[[ $? -ne 0 ]]
report $? 'missing process fails'

if (( fails )); then
  printf '\n%d test(s) failed\n' "$fails"
  exit 1
fi
printf '\nall tests passed\n'
