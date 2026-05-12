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
run1_id="$(basename "$run1")"

before3="$TMP_DIR/before3.txt"
after3="$TMP_DIR/after3.txt"
find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort > "$before3"
./install-interactive.sh --resume "$run1_id" --yes >/dev/null 2>"$TMP_DIR/run3.stderr"
find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort > "$after3"
run3="$(capture_new_run_dir "$before3" "$after3")"

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

python3 - "$run1/state.json" "$run3/state.json" "$run2/state.json" "$rc2" <<'PY'
import json
import sys
from pathlib import Path

state1 = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
state3 = json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
state2 = json.loads(Path(sys.argv[3]).read_text(encoding='utf-8'))
rc2 = int(sys.argv[4])

sum1 = Path(state1['artifacts']['summary_generated'])
sum3 = Path(state3['artifacts']['summary_generated'])
sum2 = Path(state2['artifacts']['summary_generated'])
pre1_md = Path(state1['artifacts']['preflight_markdown'])
pre1_json = Path(state1['artifacts']['preflight_json'])
pre3_md = Path(state3['artifacts']['preflight_markdown'])
pre3_json = Path(state3['artifacts']['preflight_json'])
pre2_md = Path(state2['artifacts']['preflight_markdown'])
pre2_json = Path(state2['artifacts']['preflight_json'])
cfg1 = Path(state1['artifacts']['config'])
cfg3 = Path(state3['artifacts']['config'])
cfg2 = Path(state2['artifacts']['config'])

assert sum1.exists(), sum1
assert sum3.exists(), sum3
assert sum2.exists(), sum2
assert pre1_md.exists(), pre1_md
assert pre1_json.exists(), pre1_json
assert pre3_md.exists(), pre3_md
assert pre3_json.exists(), pre3_json
assert pre2_md.exists(), pre2_md
assert pre2_json.exists(), pre2_json
assert cfg1.exists(), cfg1
assert cfg3.exists(), cfg3
assert cfg2.exists(), cfg2

assert sum1 != sum3, (sum1, sum3)
assert sum1 != sum2, (sum1, sum2)
assert sum3 != sum2, (sum3, sum2)
assert pre1_md != pre3_md, (pre1_md, pre3_md)
assert pre1_json != pre3_json, (pre1_json, pre3_json)
assert cfg1 != cfg3, (cfg1, cfg3)
assert pre1_md != pre2_md, (pre1_md, pre2_md)
assert pre1_json != pre2_json, (pre1_json, pre2_json)
assert cfg1 != cfg2, (cfg1, cfg2)

assert pre3_md.read_text(encoding='utf-8') == pre1_md.read_text(encoding='utf-8')
assert pre3_json.read_text(encoding='utf-8') == pre1_json.read_text(encoding='utf-8')
assert cfg3.read_text(encoding='utf-8') == cfg1.read_text(encoding='utf-8')

for path in (sum1, sum3, sum2, pre1_md, pre1_json, pre3_md, pre3_json, pre2_md, pre2_json, cfg1, cfg3, cfg2):
    assert '/runs/' in str(path), path

assert str(sum1).endswith('/INSTALLER-SUMMARY.generated.json'), sum1
assert str(sum3).endswith('/INSTALLER-SUMMARY.generated.json'), sum3
assert str(sum2).endswith('/INSTALLER-SUMMARY.generated.json'), sum2
assert str(pre1_md).endswith('/preflight.generated.md'), pre1_md
assert str(pre3_md).endswith('/preflight.generated.md'), pre3_md
assert str(pre1_json).endswith('/preflight.generated.json'), pre1_json
assert str(pre3_json).endswith('/preflight.generated.json'), pre3_json
assert str(cfg1).endswith('/deploy.generated.yaml'), cfg1
assert str(cfg3).endswith('/deploy.generated.yaml'), cfg3

payload1 = json.loads(sum1.read_text(encoding='utf-8'))
payload3 = json.loads(sum3.read_text(encoding='utf-8'))
payload2 = json.loads(sum2.read_text(encoding='utf-8'))
pre1 = json.loads(pre1_json.read_text(encoding='utf-8'))
pre3 = json.loads(pre3_json.read_text(encoding='utf-8'))
pre2 = json.loads(pre2_json.read_text(encoding='utf-8'))
cfg1_text = cfg1.read_text(encoding='utf-8')
cfg2_text = cfg2.read_text(encoding='utf-8')

assert payload1['deployment_name'] == 'summary-isolation-success', payload1
assert payload1['status']['final'] == 'success', payload1
assert payload3['deployment_name'] == 'summary-isolation-success', payload3
assert payload3['status']['final'] == 'success', payload3
assert payload2['deployment_name'] == 'summary-isolation-fail', payload2
assert payload2['status']['final'] == 'failed', payload2
assert payload2['status']['exit_code'] == rc2, payload2

assert state1['lineage']['mode'] == 'new', state1
assert state3['lineage']['mode'] == 'resume', state3
assert state3['resumed_from'] == state1['run_id'], state3
assert state3['lineage']['resume_strategy'] in {'reuse-apply-plan', 'reuse-generated-output', 'reuse-preflight'}, state3

assert pre1['context']['deployment_name'] == 'summary-isolation-success', pre1
assert pre3['context']['deployment_name'] == 'summary-isolation-success', pre3
assert pre2['context']['deployment_name'] == 'summary-isolation-fail', pre2
assert pre1['status'] in {'ok', 'warn', 'blocked'}, pre1
assert pre3['status'] in {'ok', 'warn', 'blocked'}, pre3
assert pre2['status'] in {'warn', 'blocked', 'ok'}, pre2
assert pre1['context']['base_domain'] == 'smoke.example.com', pre1
assert pre3['context']['base_domain'] == 'smoke.example.com', pre3
assert pre2['context']['base_domain'] == 'invalidnodot', pre2
assert 'deployment_name: summary-isolation-success' in cfg1_text, cfg1_text
assert 'deployment_name: summary-isolation-success' in cfg3.read_text(encoding='utf-8'), cfg3
assert 'deployment_name: summary-isolation-fail' in cfg2_text, cfg2_text

assert state1['artifacts']['summary_generated'] == str(sum1), state1
assert state3['artifacts']['summary_generated'] == str(sum3), state3
assert state2['artifacts']['summary_generated'] == str(sum2), state2
assert state1['artifacts']['preflight_markdown'] == str(pre1_md), state1
assert state1['artifacts']['preflight_json'] == str(pre1_json), state1
assert state3['artifacts']['preflight_markdown'] == str(pre3_md), state3
assert state3['artifacts']['preflight_json'] == str(pre3_json), state3
assert state2['artifacts']['preflight_markdown'] == str(pre2_md), state2
assert state2['artifacts']['preflight_json'] == str(pre2_json), state2
assert state1['artifacts']['config'] == str(cfg1), state1
assert state3['artifacts']['config'] == str(cfg3), state3
assert state2['artifacts']['config'] == str(cfg2), state2
print('[PASS] installer summary isolation regression')
PY
