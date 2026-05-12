#!/usr/bin/env python3
"""BaoTa / BT Panel site automation helper.

Current capabilities:
- Login through the real BT Panel login flow
- Check whether a site already exists in local BT state
- Create a static site through /site?action=AddSite
- Optionally write a default index.html after creation
- Delete a site through /site?action=DeleteSite
- Verify create/delete results from local BT state

Examples:
  # Create a static site
  python3 scripts/bt_create_site.py \
    --panel https://panel.example.com:37913 \
    --entry /bt-entry \
    --username <panel_user> \
    --password '***' \
    --domain demo.example.com \
    --insecure

  # Create only if missing, and write a default homepage
  python3 scripts/bt_create_site.py \
    --panel https://panel.example.com:37913 \
    --entry /bt-entry \
    --username <panel_user> \
    --password '***' \
    --domain demo.example.com \
    --if-not-exists \
    --write-default-index \
    --insecure

  # Delete a site and also remove its root directory
  python3 scripts/bt_create_site.py \
    --panel https://panel.example.com:37913 \
    --entry /bt-entry \
    --username <panel_user> \
    --password '***' \
    --domain demo.example.com \
    --delete \
    --delete-path \
    --insecure
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any

import requests
from Crypto.Cipher import PKCS1_v1_5
from Crypto.PublicKey import RSA

SITE_DB = Path("/www/server/panel/data/db/site.db")
VHOST_ROOT = Path("/www/server/panel/vhost")
WWWROOT = Path("/www/wwwroot")

DEFAULT_INDEX_TEMPLATE = """<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>{domain}</title>
  <style>
    body {{ font-family: system-ui, sans-serif; margin: 3rem; color: #222; }}
    .card {{ max-width: 720px; padding: 1.5rem; border: 1px solid #ddd; border-radius: 12px; }}
    code {{ background: #f5f5f5; padding: .15rem .35rem; border-radius: 6px; }}
  </style>
</head>
<body>
  <div class=\"card\">
    <h1>{domain}</h1>
    <p>This site was created by Hermes via BaoTa / BT Panel automation.</p>
    <p>Root path: <code>{root_path}</code></p>
  </div>
</body>
</html>
"""


class BtPanelError(RuntimeError):
    pass


class BtPanelClient:
    def __init__(
        self,
        panel_base: str,
        entry_path: str,
        username: str,
        password: str,
        *,
        timeout: int = 20,
        verify_tls: bool = True,
    ) -> None:
        self.panel_base = panel_base.rstrip("/")
        self.entry_path = entry_path if entry_path.startswith("/") else f"/{entry_path}"
        self.username = username
        self.password = password
        self.timeout = timeout
        self.verify_tls = verify_tls
        self.session = requests.Session()
        self.session.headers.update(
            {
                "User-Agent": (
                    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"
                ),
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            }
        )
        self.csrf_token: str | None = None

    @property
    def entry_url(self) -> str:
        return f"{self.panel_base}{self.entry_path}"

    def _md5(self, text: str) -> str:
        return hashlib.md5(text.encode("utf-8")).hexdigest()

    def _extract_login_bootstrap(self, html: str) -> tuple[str, str, bool]:
        token_match = re.search(r"vite_public_login_token\s*=\s*'([^']+)'", html)
        pubkey_match = re.search(r"vite_public_encryption\s*=\s*'([^']+)'", html)
        code_match = re.search(r"vite_public_login_check\s*=\s*'([^']+)'\s*===\s*'True'", html)
        if not token_match or not pubkey_match:
            raise BtPanelError("Failed to extract login token or RSA public key from login page")
        compact_key = pubkey_match.group(1).replace("\\n", "").strip()
        pem_key = compact_key
        if "BEGIN PUBLIC KEY" in compact_key and "\n" not in compact_key:
            body = compact_key.replace("-----BEGIN PUBLIC KEY-----", "").replace("-----END PUBLIC KEY-----", "")
            pem_key = "-----BEGIN PUBLIC KEY-----\n" + body + "\n-----END PUBLIC KEY-----"
        code_required = bool(code_match and code_match.group(1) == "True")
        return token_match.group(1), pem_key, code_required

    def _rsa_encrypt(self, plaintext: str, public_key_pem: str) -> str:
        key = RSA.import_key(public_key_pem)
        cipher = PKCS1_v1_5.new(key)
        chunk_size = key.size_in_bytes() - 11
        data = plaintext.encode("utf-8")
        encoded: list[str] = []
        for i in range(0, len(data), chunk_size):
            chunk = data[i : i + chunk_size]
            encoded.append(base64.b64encode(cipher.encrypt(chunk)).decode("ascii"))
        return "\n".join(encoded)

    def _candidate_endpoint_paths(self, suffix: str) -> list[str]:
        suffix = suffix if suffix.startswith("/") else f"/{suffix}"
        candidates = [suffix]
        if self.entry_path not in ("", "/"):
            candidates.append(f"{self.entry_path}{suffix}")
        ordered: list[str] = []
        seen = set()
        for item in candidates:
            if item not in seen:
                seen.add(item)
                ordered.append(item)
        return ordered

    def _get_first_ok(self, suffix: str) -> requests.Response:
        last_exc: Exception | None = None
        for path in self._candidate_endpoint_paths(suffix):
            try:
                resp = self.session.get(
                    f"{self.panel_base}{path}",
                    timeout=self.timeout,
                    verify=self.verify_tls,
                    headers={"Referer": self.entry_url},
                )
                if resp.ok and "vite_public_request_token" in resp.text:
                    return resp
            except requests.RequestException as exc:
                last_exc = exc
        if last_exc:
            raise BtPanelError(f"GET {suffix} failed: {last_exc}")
        raise BtPanelError(f"GET {suffix} failed with non-usable responses")

    def _post_first_ok(self, suffix: str, *, data: dict[str, str], headers: dict[str, str]) -> requests.Response:
        last_exc: Exception | None = None
        responses: list[str] = []
        for path in self._candidate_endpoint_paths(suffix):
            try:
                resp = self.session.post(
                    f"{self.panel_base}{path}",
                    data=data,
                    timeout=self.timeout,
                    verify=self.verify_tls,
                    headers={**headers, "Referer": self.entry_url},
                )
                if resp.ok:
                    return resp
                responses.append(f"{path}:{resp.status_code}")
            except requests.RequestException as exc:
                last_exc = exc
        if last_exc:
            raise BtPanelError(f"POST {suffix} failed: {last_exc}")
        raise BtPanelError(f"POST {suffix} failed with responses {responses}")

    def _ajax_headers(self) -> dict[str, str]:
        if not self.csrf_token:
            raise BtPanelError("Not logged in")
        return {
            "x-http-token": self.csrf_token,
            "X-Requested-With": "XMLHttpRequest",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        }

    def _post_json(self, suffix: str, *, data: dict[str, str]) -> dict[str, Any]:
        resp = self._post_first_ok(suffix, data=data, headers=self._ajax_headers())
        try:
            payload = resp.json()
        except Exception as exc:
            raise BtPanelError(f"{suffix} did not return JSON: {resp.text[:300]}") from exc
        if not isinstance(payload, dict):
            raise BtPanelError(f"{suffix} returned unexpected payload: {payload!r}")
        return payload

    def login(self) -> dict[str, Any]:
        try:
            response = self.session.get(self.entry_url, timeout=self.timeout, verify=self.verify_tls)
            response.raise_for_status()
        except requests.RequestException as exc:
            raise BtPanelError(f"Failed to load login page: {exc}") from exc

        last_login_token, public_key, code_required = self._extract_login_bootstrap(response.text)
        if code_required:
            raise BtPanelError("Login requires image captcha; this script currently does not solve captcha")

        username_hash = self._md5(self._md5(self.username + last_login_token))
        password_hash = self._md5(self._md5(self.password) + "_bt.cn")
        form = {
            "username": self._rsa_encrypt(username_hash, public_key),
            "password": self._rsa_encrypt(password_hash, public_key),
            "safe_mode": "1",
        }

        try:
            login_resp = self.session.post(
                self.entry_url,
                data=form,
                timeout=self.timeout,
                verify=self.verify_tls,
                headers={"X-Requested-With": "XMLHttpRequest", "Referer": self.entry_url},
            )
            login_resp.raise_for_status()
        except requests.RequestException as exc:
            raise BtPanelError(f"Login request failed: {exc}") from exc

        try:
            payload = login_resp.json()
        except Exception as exc:
            raise BtPanelError(f"Login did not return JSON: {login_resp.text[:300]}") from exc

        if payload == 1:
            raise BtPanelError("Login requires second-factor vcode; unsupported in this script")
        if not isinstance(payload, dict) or not payload.get("status"):
            raise BtPanelError(f"Login failed: {payload}")

        index_resp = self._get_first_ok("/site/php")
        token_match = re.search(r"vite_public_request_token\s*=\s*'([^']+)'", index_resp.text)
        if not token_match:
            raise BtPanelError("Failed to extract x-http-token / CSRF token after login")
        self.csrf_token = token_match.group(1)
        return payload

    def create_static_site(
        self,
        domain: str,
        *,
        path: str | None = None,
        remark: str = "",
        port: int = 80,
    ) -> dict[str, Any]:
        path = path or str(WWWROOT / domain)
        form = {
            "webname": json.dumps({"domain": domain, "domainlist": [], "count": 0}, ensure_ascii=False),
            "path": path,
            "port": str(port),
            "version": "00",
            "ps": remark,
            "ftp": "false",
            "sql": "false",
        }
        payload = self._post_json("/site?action=AddSite", data=form)
        if not isinstance(payload, dict) or not payload.get("siteStatus"):
            raise BtPanelError(f"AddSite failed: {payload}")
        return payload

    def list_sites(self) -> dict[str, Any]:
        return self._post_json("/data?action=getData&table=sites", data={})

    def get_site_record_http(self, domain: str) -> dict[str, Any] | None:
        payload = self.list_sites()
        for row in extract_site_rows(payload):
            if _http_site_matches_domain(row, domain):
                return compact_site_summary(row)
        return None

    def delete_site(
        self,
        *,
        site_id: int,
        webname: str,
        delete_path: bool = False,
        delete_database: bool = False,
        delete_ftp: bool = False,
    ) -> dict[str, Any]:
        form = {
            "id": str(site_id),
            "webname": webname,
            "path": "1" if delete_path else "0",
            "database": "1" if delete_database else "0",
            "ftp": "1" if delete_ftp else "0",
        }
        payload = self._post_json("/site?action=DeleteSite", data=form)
        if not isinstance(payload, dict) or not payload.get("status"):
            raise BtPanelError(f"DeleteSite failed: {payload}")
        return payload


def get_site_record(domain: str) -> dict[str, Any]:
    if not SITE_DB.exists():
        raise BtPanelError(f"site.db not found: {SITE_DB}")
    try:
        with sqlite3.connect(SITE_DB) as conn:
            cur = conn.cursor()
            row = cur.execute(
                "select id,name,path,project_type,status from sites where name=?", (domain,)
            ).fetchone()
            drow = cur.execute(
                "select id,pid,name,port from domain where name=?", (domain,)
            ).fetchone()
    except sqlite3.Error as exc:
        raise BtPanelError(f"Failed to read site.db: {exc}") from exc
    return {
        "exists": bool(row),
        "site_row": row,
        "domain_row": drow,
    }


def extract_site_rows(payload: dict[str, Any]) -> list[dict[str, Any]]:
    for key in ("data", "dataList", "list", "sites"):
        value = payload.get(key)
        if isinstance(value, list):
            return [row for row in value if isinstance(row, dict)]
    return []


def _split_http_site_tokens(value: Any) -> list[str]:
    if isinstance(value, str):
        return [token for token in re.split(r"[\s,;]+", value) if token]
    if isinstance(value, list):
        tokens: list[str] = []
        for item in value:
            if isinstance(item, str):
                tokens.extend(_split_http_site_tokens(item))
            elif isinstance(item, dict):
                for key in ("name", "domain", "siteName"):
                    nested = item.get(key)
                    if isinstance(nested, str):
                        tokens.extend(_split_http_site_tokens(nested))
        return tokens
    return []


def _http_site_matches_domain(row: dict[str, Any], domain: str) -> bool:
    needle = domain.strip().lower()
    candidates: list[str] = []
    for key in ("name", "siteName", "domain", "domains", "domainlist"):
        candidates.extend(_split_http_site_tokens(row.get(key)))
    return any(candidate.strip().lower() == needle for candidate in candidates)


def compact_site_summary(row: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for source_key, target_key in (("id", "id"), ("name", "name"), ("siteName", "name"), ("path", "path")):
        value = row.get(source_key)
        if value not in (None, "") and target_key not in result:
            result[target_key] = value
    return result


def compact_site_list(payload: dict[str, Any], *, search: str | None = None, limit: int | None = None) -> list[dict[str, Any]]:
    rows = extract_site_rows(payload)
    search_text = search.strip().lower() if search else None
    sites: list[dict[str, Any]] = []
    for row in rows:
        summary = compact_site_summary(row)
        if search_text:
            haystack = " ".join(str(value).lower() for value in row.values() if value is not None)
            if search_text not in haystack:
                continue
        sites.append(summary)
        if limit is not None and limit >= 0 and len(sites) >= limit:
            break
    return sites


def format_site_row(row: tuple[Any, ...] | None) -> dict[str, Any] | None:
    if not row:
        return None
    return {
        "id": row[0],
        "name": row[1],
        "path": row[2],
        "project_type": row[3],
        "status": row[4],
    }


def format_domain_row(row: tuple[Any, ...] | None) -> dict[str, Any] | None:
    if not row:
        return None
    return {
        "id": row[0],
        "site_id": row[1],
        "name": row[2],
        "port": row[3],
    }


def build_compact_get_result(
    domain: str,
    *,
    expected_path: str | None = None,
    expected_port: int = 80,
    http_site: dict[str, Any] | None = None,
) -> dict[str, Any]:
    record = get_site_record(domain)
    verify_payload = (
        verify_site(domain, expected_path=expected_path, expected_port=expected_port)
        if record["exists"]
        else verify_site_absent(domain, expected_path=expected_path)
    )
    return {
        "domain": domain,
        "exists": record["exists"],
        "http": http_site,
        "site": format_site_row(record["site_row"]),
        "domain_binding": format_domain_row(record["domain_row"]),
        "verify": verify_payload,
    }


def verify_site(domain: str, *, expected_path: str | None = None, expected_port: int = 80) -> dict[str, Any]:
    result: dict[str, Any] = {"domain": domain}
    record = get_site_record(domain)
    row = record["site_row"]
    drow = record["domain_row"]
    result.update(record)

    conf = VHOST_ROOT / "nginx" / f"{domain}.conf"
    rewrite = VHOST_ROOT / "rewrite" / f"{domain}.conf"
    well_known = VHOST_ROOT / "nginx" / "well-known" / f"{domain}.conf"
    ext_dir = VHOST_ROOT / "nginx" / "extension" / domain
    expected_path = expected_path or str(WWWROOT / domain)
    root_dir = Path(expected_path)

    result["paths"] = {
        "conf": str(conf),
        "rewrite": str(rewrite),
        "well_known": str(well_known),
        "extension_dir": str(ext_dir),
        "root_dir": str(root_dir),
    }
    result["exists_map"] = {
        "conf": conf.exists(),
        "rewrite": rewrite.exists(),
        "well_known": well_known.exists(),
        "extension_dir": ext_dir.exists(),
        "root_dir": root_dir.exists(),
    }

    conf_text = conf.read_text(encoding="utf-8", errors="ignore") if conf.exists() else ""
    result["checks"] = {
        "site_path_matches": bool(row and row[2] == expected_path),
        "project_type_is_php": bool(row and row[3] == "PHP"),
        "domain_port_matches": bool(drow and int(drow[3]) == int(expected_port)),
        "conf_has_server_name": f"server_name {domain};" in conf_text,
        "conf_has_root": f"root {expected_path};" in conf_text,
        "conf_has_static_php_include": "include enable-php-00.conf;" in conf_text,
    }
    result["valid"] = bool(
        row
        and drow
        and result["exists_map"]["conf"]
        and result["exists_map"]["rewrite"]
        and result["exists_map"]["well_known"]
        and result["exists_map"]["root_dir"]
        and all(result["checks"].values())
    )
    return result


def verify_site_absent(domain: str, *, expected_path: str | None = None) -> dict[str, Any]:
    record = get_site_record(domain)
    expected_path = expected_path or str(WWWROOT / domain)
    conf = VHOST_ROOT / "nginx" / f"{domain}.conf"
    rewrite = VHOST_ROOT / "rewrite" / f"{domain}.conf"
    well_known = VHOST_ROOT / "nginx" / "well-known" / f"{domain}.conf"
    root_dir = Path(expected_path)
    result = {
        "domain": domain,
        "exists": record["exists"],
        "site_row": record["site_row"],
        "domain_row": record["domain_row"],
        "paths": {
            "conf": str(conf),
            "rewrite": str(rewrite),
            "well_known": str(well_known),
            "root_dir": str(root_dir),
        },
        "remaining": {
            "conf": conf.exists(),
            "rewrite": rewrite.exists(),
            "well_known": well_known.exists(),
            "root_dir": root_dir.exists(),
        },
    }
    result["valid"] = (not result["exists"]) and (record["domain_row"] is None)
    return result


def write_default_index(root_path: str, domain: str, *, force: bool = False) -> dict[str, Any]:
    root = Path(root_path)
    if not root.exists():
        raise BtPanelError(f"Site root does not exist: {root}")
    index_path = root / "index.html"
    existed = index_path.exists()
    if existed and not force:
        return {
            "path": str(index_path),
            "written": False,
            "skipped": True,
            "reason": "index.html already exists; use --force-index to overwrite",
        }
    content = DEFAULT_INDEX_TEMPLATE.format(domain=domain, root_path=root_path)
    index_path.write_text(content, encoding="utf-8")
    return {
        "path": str(index_path),
        "written": True,
        "skipped": False,
        "bytes": index_path.stat().st_size,
        "overwrote_existing": existed,
    }


def resolve_password(args: argparse.Namespace) -> str:
    direct = args.password
    env_name = args.password_env
    from_stdin = bool(args.password_stdin)

    provided = sum(bool(value) for value in (direct, env_name)) + int(from_stdin)
    if provided != 1:
        raise BtPanelError("Provide exactly one of --password, --password-env, or --password-stdin")

    if direct:
        return direct

    if env_name:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", env_name):
            raise BtPanelError(f"Invalid --password-env name: {env_name}")
        value = os.environ.get(env_name)
        if not value:
            raise BtPanelError(f"Password env var is unset or empty: {env_name}")
        return value

    value = sys.stdin.read()
    if value.endswith("\n"):
        value = value[:-1]
        if value.endswith("\r"):
            value = value[:-1]
    if not value:
        raise BtPanelError("No password data received on stdin")
    return value


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="BaoTa / BT Panel site automation helper")
    parser.add_argument("--panel", required=True, help="Panel base URL, e.g. https://panel.example.com:37913")
    parser.add_argument("--entry", default="/bt", help="Admin entry path, e.g. /bt-entry")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", default=None, help="Panel password passed directly on argv")
    parser.add_argument("--password-env", default=None, help="Environment variable name containing the panel password")
    parser.add_argument("--password-stdin", action="store_true", help="Read the panel password from stdin")
    parser.add_argument("--domain", default=None)
    parser.add_argument("--path", default=None)
    parser.add_argument("--remark", default="")
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--timeout", type=int, default=20)
    parser.add_argument("--insecure", action="store_true", help="Disable TLS certificate verification")

    parser.add_argument("--list", action="store_true", help="List sites through the authenticated BT Panel HTTP API")
    parser.add_argument("--get", action="store_true", help="Get a compact site record using --domain as the lookup key")
    parser.add_argument("--limit", type=int, default=None, help="Optional max sites to include with --list")
    parser.add_argument("--search", default=None, help="Optional substring filter for --list output")
    parser.add_argument("--check", action="store_true", help="Only check whether the site exists in local BT state")
    parser.add_argument("--delete", action="store_true", help="Delete the site instead of creating it")
    parser.add_argument("--if-not-exists", action="store_true", help="Skip create when site already exists")
    parser.add_argument("--write-default-index", action="store_true", help="Write a default index.html after successful create")
    parser.add_argument("--force-index", action="store_true", help="Overwrite existing index.html when used with --write-default-index")
    parser.add_argument("--delete-path", action="store_true", help="When deleting, also remove the site root directory")
    parser.add_argument("--delete-database", action="store_true", help="When deleting, also remove linked database")
    parser.add_argument("--delete-ftp", action="store_true", help="When deleting, also remove linked FTP user")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    expected_path = args.path or (str(WWWROOT / args.domain) if args.domain else None)

    if sum(bool(flag) for flag in (args.list, args.get, args.check, args.delete)) > 1:
        raise BtPanelError("--list, --get, --check, and --delete are mutually exclusive")

    if not args.list and not args.domain:
        raise BtPanelError("--domain is required unless --list is used")

    if args.check:
        result = get_site_record(args.domain)
        result["expected_path"] = expected_path
        print(json.dumps(result, ensure_ascii=False, indent=2, default=str))
        return 0 if result["exists"] else 1

    password = resolve_password(args)
    client = BtPanelClient(
        args.panel,
        args.entry,
        args.username,
        password,
        timeout=args.timeout,
        verify_tls=not args.insecure,
    )
    login_payload = client.login()

    if args.list:
        sites = compact_site_list(client.list_sites(), search=args.search, limit=args.limit)
        output = {
            "mode": "list",
            "login": login_payload,
            "list": {
                "count": len(sites),
                "sites": sites,
            },
        }
        print(json.dumps(output, ensure_ascii=False, indent=2, default=str))
        return 0

    if args.get:
        output = {
            "mode": "get",
            "login": login_payload,
            "site": build_compact_get_result(
                args.domain,
                expected_path=expected_path,
                expected_port=args.port,
                http_site=client.get_site_record_http(args.domain),
            ),
        }
        print(json.dumps(output, ensure_ascii=False, indent=2, default=str))
        return 0 if output["site"]["verify"].get("valid") else 1

    before = get_site_record(args.domain)

    if args.delete:
        if not before["exists"] or not before["site_row"]:
            raise BtPanelError(f"Site does not exist: {args.domain}")
        site_row = before["site_row"]
        delete_payload = client.delete_site(
            site_id=int(site_row[0]),
            webname=str(site_row[1]),
            delete_path=args.delete_path,
            delete_database=args.delete_database,
            delete_ftp=args.delete_ftp,
        )
        verify_payload = verify_site_absent(args.domain, expected_path=expected_path)
        output = {
            "mode": "delete",
            "login": login_payload,
            "before": before,
            "delete": delete_payload,
            "verify": verify_payload,
        }
        print(json.dumps(output, ensure_ascii=False, indent=2, default=str))
        return 0 if verify_payload.get("valid") else 1

    if before["exists"]:
        if not args.if_not_exists:
            raise BtPanelError(
                f"Site already exists: {args.domain}. Use --if-not-exists to skip create or --delete to remove it first."
            )
        verify_payload = verify_site(args.domain, expected_path=expected_path, expected_port=args.port)
        output = {
            "mode": "create-skipped-existing",
            "login": login_payload,
            "before": before,
            "verify": verify_payload,
        }
        print(json.dumps(output, ensure_ascii=False, indent=2, default=str))
        return 0 if verify_payload.get("valid") else 1

    create_payload = client.create_static_site(
        args.domain,
        path=args.path,
        remark=args.remark,
        port=args.port,
    )
    verify_payload = verify_site(args.domain, expected_path=args.path, expected_port=args.port)
    index_payload = None
    if args.write_default_index:
        index_payload = write_default_index(expected_path, args.domain, force=args.force_index)

    output = {
        "mode": "create",
        "login": login_payload,
        "before": before,
        "create": create_payload,
        "verify": verify_payload,
        "index": index_payload,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, default=str))
    return 0 if verify_payload.get("valid") else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BtPanelError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
    except Exception as exc:
        print(f"ERROR: unexpected failure: {exc}", file=sys.stderr)
        raise SystemExit(3)
