#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CONFIG_PATH="$TMP_DIR/deploy.generated.yaml"
BOUNDARY_CONFIG_PATH="$TMP_DIR/deploy.boundary.yaml"
OUTPUT_DIR="$TMP_DIR/output:with#chars"
export DEPLOYMENT_NAME='yaml-smoke:demo#1'
export BASE_DOMAIN='demo.example.com'
export DOMAIN_MODE='flat-siblings'
export TLS_MODE='existing'
export TLS_CERT='/tmp/cert path:demo#1.pem'
export TLS_KEY='/tmp/key path:demo#1.pem'
export ERROR_ROOT="$TMP_DIR/errors:with#chars"
export LOG_DIR="$TMP_DIR/logs with spaces"
export OUTPUT_DIR
export NGINX_SNIPPETS_TARGET_HINT="$TMP_DIR/snippets:with#chars"
export NGINX_VHOST_TARGET_HINT="$TMP_DIR/conf.d with spaces"
export PLATFORM='plain-nginx'

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/config.sh"
write_deploy_config "$CONFIG_PATH"

python3 - "$CONFIG_PATH" <<'PY'
import sys
from pathlib import Path
import yaml

config_path = Path(sys.argv[1])
data = yaml.safe_load(config_path.read_text(encoding='utf-8')) or {}
assert data['deployment_name'] == 'yaml-smoke:demo#1', data
assert data['domain']['base_domain'] == 'demo.example.com', data
assert data['domain']['mode'] == 'flat-siblings', data
assert data['tls']['mode'] == 'existing', data
assert data['tls']['cert'] == '/tmp/cert path:demo#1.pem', data
assert data['tls']['key'] == '/tmp/key path:demo#1.pem', data
assert data['paths']['error_root'].endswith('errors:with#chars'), data
assert data['paths']['log_dir'].endswith('logs with spaces'), data
assert data['paths']['output_dir'].endswith('output:with#chars'), data
assert data['nginx']['snippets_target_hint'].endswith('snippets:with#chars'), data
assert data['nginx']['vhost_target_hint'].endswith('conf.d with spaces'), data
assert data['nginx']['include_redirect_whitelist_map'] is True, data
assert data['deployment']['platform'] == 'plain-nginx', data
assert data['deployment']['dns_provider'] == 'manual', data
assert data['docs']['language'] == 'zh-CN', data
PY

"$ROOT_DIR/generate-from-config.sh" --config "$CONFIG_PATH" >/dev/null
RENDERED_ENV="$OUTPUT_DIR/RENDERED-VALUES.env"
if [[ ! -f "$RENDERED_ENV" ]]; then
  echo "[FAIL] missing rendered env: $RENDERED_ENV" >&2
  exit 1
fi

DEPLOY_RESOLVED="$OUTPUT_DIR/deploy.resolved.yaml"
if [[ ! -f "$DEPLOY_RESOLVED" ]]; then
  echo "[FAIL] missing resolved yaml: $DEPLOY_RESOLVED" >&2
  exit 1
fi

python3 - "$DEPLOY_RESOLVED" "$RENDERED_ENV" <<'PY'
import sys
from pathlib import Path
import shlex
import yaml

resolved_path = Path(sys.argv[1])
rendered_path = Path(sys.argv[2])
resolved = yaml.safe_load(resolved_path.read_text(encoding='utf-8')) or {}
assert resolved['deployment_name'] == 'yaml-smoke:demo#1', resolved
assert resolved['domain']['base_domain'] == 'demo.example.com', resolved
assert resolved['domain']['mode'] == 'flat-siblings', resolved
assert resolved['tls']['mode'] == 'existing', resolved
assert resolved['tls']['cert'] == '/tmp/cert path:demo#1.pem', resolved
assert resolved['tls']['key'] == '/tmp/key path:demo#1.pem', resolved
assert resolved['tls']['render_contract_cert'] == '/tmp/cert path:demo#1.pem', resolved
assert resolved['tls']['render_contract_key'] == '/tmp/key path:demo#1.pem', resolved
assert resolved['tls']['render_contract_uses_placeholder'] is False, resolved
assert resolved['paths']['error_root'].endswith('errors:with#chars'), resolved
assert resolved['paths']['log_dir'].endswith('logs with spaces'), resolved
assert resolved['paths']['output_dir'].endswith('output:with#chars'), resolved
assert resolved['deployment']['platform'] == 'plain-nginx', resolved
assert resolved['docs']['language'] == 'zh-CN', resolved

values = {}
for raw in rendered_path.read_text(encoding='utf-8').splitlines():
    if not raw or '=' not in raw:
        continue
    k, v = raw.split('=', 1)
    values[k] = shlex.split(f'x {v}')[1]

assert values['BASE_DOMAIN'] == 'demo.example.com', values
assert values['DOMAIN_MODE'] == 'flat-siblings', values
assert values['TLS_MODE'] == 'existing', values
assert values['SSL_CERT'] == '/tmp/cert path:demo#1.pem', values
assert values['SSL_KEY'] == '/tmp/key path:demo#1.pem', values
assert values['ERROR_ROOT'].endswith('errors:with#chars'), values
assert values['LOG_DIR'].endswith('logs with spaces'), values
assert values['RAW_DOMAIN'] == 'raw.example.com', values
assert values['GIST_DOMAIN'] == 'gist.example.com', values
assert values['ASSETS_DOMAIN'] == 'assets.example.com', values
assert values['ARCHIVE_DOMAIN'] == 'archive.example.com', values
assert values['DOWNLOAD_DOMAIN'] == 'download.example.com', values
PY

# Writer-only boundary cases: pin YAML serialization semantics on existing fields
# without changing downstream generator validation rules.
export DEPLOYMENT_NAME='true'
export BASE_DOMAIN='null'
export DOMAIN_MODE='  flat-siblings  '
export TLS_MODE='acme-http01'
export TLS_CERT='00123'
export TLS_KEY=$'line1\nline2: # still content'
export ERROR_ROOT='  /tmp/error root with padding  '
export LOG_DIR=''
export NGINX_SNIPPETS_TARGET_HINT=''
export NGINX_VHOST_TARGET_HINT='  /tmp/conf.d padded  '
write_deploy_config "$BOUNDARY_CONFIG_PATH"

python3 - "$BOUNDARY_CONFIG_PATH" <<'PY'
import sys
from pathlib import Path
import yaml

config_path = Path(sys.argv[1])
data = yaml.safe_load(config_path.read_text(encoding='utf-8')) or {}
assert data['deployment_name'] == 'true', data
assert isinstance(data['deployment_name'], str), data
assert data['domain']['base_domain'] == 'null', data
assert isinstance(data['domain']['base_domain'], str), data
assert data['domain']['mode'] == '  flat-siblings  ', data
assert data['tls']['mode'] == 'acme-http01', data
assert data['tls']['cert'] == '00123', data
assert isinstance(data['tls']['cert'], str), data
assert data['tls']['key'] == 'line1\nline2: # still content', data
assert data['paths']['error_root'] == '  /tmp/error root with padding  ', data
assert data['paths']['log_dir'] == '', data
assert data['nginx']['snippets_target_hint'] == '', data
assert data['nginx']['vhost_target_hint'] == '  /tmp/conf.d padded  ', data
PY

echo "[PASS] deploy config yaml serialization regression"
