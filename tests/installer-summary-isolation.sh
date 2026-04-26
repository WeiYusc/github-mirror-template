#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

make_workspace() {
  local name="$1"
  local dir="$TMP_DIR/$name"
  mkdir -p "$dir/errors" "$dir/logs" "$dir/output" "$dir/snippets" "$dir/conf"
  printf '%s\n' "$dir"
}

capture_new_run_dir() {
  local before="$1"
  local after="$2"
  comm -13 "$before" "$after" | tail -n 1
}

RUNS_ROOT="scripts/generated/runs"
mkdir -p "$RUNS_ROOT"

before1="$TMP_DIR/before1.txt"
after1="$TMP_DIR/after1.txt"
find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort > "$before1"

ws1="$(make_workspace success)"
./install-interactive.sh \
  --deployment-name summary-isolation-success \
  --base-domain smoke.example.com \
  --domain-mode flat-siblings \
  --platform plain-nginx \
  --tls-cert /tmp/fake-cert.pem \
  --tls-key /tmp/fake-key.pem \
  --input-mode advanced \
  --error-root "$ws1/errors" \
  --log-dir "$ws1/logs" \
  --output-dir "$ws1/output" \
  --snippets-target "$ws1/snippets" \
  --vhost-target "$ws1/conf" \
  --yes >/dev/null 2>"$TMP_DIR/run1.stderr"
find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort > "$after1"
run1="$(capture_new_run_dir "$before1" "$after1")"

before2="$TMP_DIR/before2.txt"
after2="$TMP_DIR/after2.txt"
find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort > "$before2"

ws2="$(make_workspace fail)"
set +e
./install-interactive.sh \
  --deployment-name summary-isolation-fail \
  --base-domain invalidnodot \
  --domain-mode flat-siblings \
  --platform plain-nginx \
  --tls-cert /tmp/fake-cert.pem \
  --tls-key /tmp/fake-key.pem \
  --input-mode advanced \
  --error-root "$ws2/errors" \
  --log-dir "$ws2/logs" \
  --output-dir "$ws2/output" \
  --snippets-target "$ws2/snippets" \
  --vhost-target "$ws2/conf" \
  --yes >/dev/null 2>"$TMP_DIR/run2.stderr"
rc2=$?
set -e
find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort > "$after2"
run2="$(capture_new_run_dir "$before2" "$after2")"

python3 - "$run1/state.json" "$run2/state.json" "$rc2" <<'PY'
import json
import sys
from pathlib import Path

state1 = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
state2 = json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
rc2 = int(sys.argv[3])

sum1 = Path(state1['artifacts']['summary_generated'])
sum2 = Path(state2['artifacts']['summary_generated'])
assert sum1.exists(), sum1
assert sum2.exists(), sum2
assert sum1 != sum2, (sum1, sum2)
assert str(sum1).endswith('/INSTALLER-SUMMARY.generated.json'), sum1
assert str(sum2).endswith('/INSTALLER-SUMMARY.generated.json'), sum2
assert '/runs/' in str(sum1), sum1
assert '/runs/' in str(sum2), sum2

payload1 = json.loads(sum1.read_text(encoding='utf-8'))
payload2 = json.loads(sum2.read_text(encoding='utf-8'))

assert payload1['deployment_name'] == 'summary-isolation-success', payload1
assert payload1['status']['final'] == 'success', payload1
assert payload2['deployment_name'] == 'summary-isolation-fail', payload2
assert payload2['status']['final'] == 'failed', payload2
assert payload2['status']['exit_code'] == rc2, payload2

assert state1['artifacts']['summary_generated'] == str(sum1), state1
assert state2['artifacts']['summary_generated'] == str(sum2), state2
print('[PASS] installer summary isolation regression')
PY
