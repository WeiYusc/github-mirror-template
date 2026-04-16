# Redirect Whitelist Design

This note describes how to harden redirect-following in:

- `conf.d/archive.example.com.conf`
- `conf.d/download.example.com.conf`

Current template behavior follows `$upstream_http_location` directly. That is acceptable for design-stage templates, but NOT recommended for public deployment.

## Goal

Only allow redirect targets that belong to GitHub-controlled download domains needed by the mirror.

## Recommended allowlist (initial)

Allow HTTPS redirects only to these hosts or suffixes:

- `github.com`
- `codeload.github.com`
- `objects.githubusercontent.com`
- `release-assets.githubusercontent.com`
- `*.githubusercontent.com`

If testing shows additional GitHub-owned hosts are needed, extend the allowlist deliberately.

## Strategy

1. Read redirect target from `$upstream_http_location`
2. Reject empty targets
3. Reject non-HTTPS targets
4. Extract host from target URL
5. Match host against an allowlist map
6. Only then `proxy_pass $redirect_target`

## Suggested map-based pattern

Because `proxy_pass $variable` is involved, prefer a `map` in `http {}` context instead of complex nested `if` chains inside `location`.

Example sketch:

```nginx
map $upstream_http_location $redirect_allowed {
    default 0;

    ~^https://github\.com/ 1;
    ~^https://codeload\.github\.com/ 1;
    ~^https://objects\.githubusercontent\.com/ 1;
    ~^https://release-assets\.githubusercontent\.com/ 1;
    ~^https://[A-Za-z0-9.-]+\.githubusercontent\.com/ 1;
}
```

Then inside `@handle_redirect`:

```nginx
if ($upstream_http_location = "") {
    return 502;
}

if ($redirect_allowed = 0) {
    return 403;
}

proxy_pass $upstream_http_location;
```

## Why this matters

Without a whitelist, the mirror may follow arbitrary upstream redirect targets. That weakens the trust boundary and can cause:

- unintended third-party fetches
- policy bypass
- harder debugging of download flows

## Practical recommendation

Before production deployment:

- add the whitelist map in the main nginx `http {}` scope
- wire `archive` and `download` redirect handlers to it
- test:
  - release downloads
  - source archive downloads
  - large files
  - 302/307 chains

## Deployment note for this project

With your chosen domain plan:

- main: `github.example.com`
- raw: `raw.github.example.com`
- gist: `gist.github.example.com`
- assets: `assets.github.example.com`
- archive: `archive.github.example.com`
- download: `download.github.example.com`

there is no need for redirect handlers to allow your own domains. They should only follow upstream GitHub-owned redirect targets; user-facing domain rewriting is handled earlier at the mirror entry layer.
