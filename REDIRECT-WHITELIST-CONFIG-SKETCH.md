# Nginx Redirect Whitelist Config Sketch

This file contains a near-config sketch for hardening redirect following in the GitHub mirror.

## 1) Put these `map` blocks in nginx `http {}` scope

These maps should NOT be placed inside a `server {}` block.

```nginx
# Accept only HTTPS upstream redirect targets
map $upstream_http_location $gh_redirect_https_ok {
    default 0;
    ~^https:// 1;
}

# Accept only known GitHub-controlled redirect destinations needed by archive/download
map $upstream_http_location $gh_redirect_allowed {
    default 0;

    ~^https://github\.com/ 1;
    ~^https://codeload\.github\.com/ 1;
    ~^https://objects\.githubusercontent\.com/ 1;
    ~^https://release-assets\.githubusercontent\.com/ 1;
    ~^https://[A-Za-z0-9.-]+\.githubusercontent\.com/ 1;
}
```

## 2) Use in `archive` and `download` redirect handlers

### Archive example

```nginx
location @handle_redirect {
    resolver 8.8.8.8 1.1.1.1 valid=300s ipv6=off;

    set $redirect_target $upstream_http_location;

    if ($redirect_target = "") {
        return 502;
    }

    if ($gh_redirect_https_ok = 0) {
        return 403;
    }

    if ($gh_redirect_allowed = 0) {
        return 403;
    }

    proxy_pass $redirect_target;

    proxy_intercept_errors on;
    error_page 301 302 307 = @handle_redirect;
}
```

### Download example

```nginx
location @handle_redirect {
    resolver 8.8.8.8 1.1.1.1 valid=300s ipv6=off;

    set $redirect_target $upstream_http_location;

    if ($redirect_target = "") {
        return 502;
    }

    if ($gh_redirect_https_ok = 0) {
        return 403;
    }

    if ($gh_redirect_allowed = 0) {
        return 403;
    }

    proxy_pass $redirect_target;

    proxy_intercept_errors on;
    error_page 301 302 307 = @handle_redirect;
}
```

## 3) Why split into two maps

Using two maps keeps the intent clear:

- `gh_redirect_https_ok`: reject plain HTTP or malformed redirect targets
- `gh_redirect_allowed`: reject non-GitHub or unexpected redirect targets

This makes troubleshooting easier when a download fails.

## 4) Recommended first-pass test set

After enabling the whitelist, test:

1. public release download
2. source archive zip download
3. source archive tar.gz download
4. at least one large release file
5. at least one redirect chain that ends on `*.githubusercontent.com`

If something legitimate breaks, add only the exact needed GitHub-owned host pattern.

## 5) Operational note

Do NOT widen the allowlist casually. If a redirect target is missing, inspect logs first and confirm it is a GitHub-owned host used for public downloads.

## 6) Suggested log hint during rollout

Temporarily increase error log detail for `archive` and `download` servers during rollout so blocked redirect targets are easy to identify.
```
error_log /var/log/nginx/archive.github.example.com.error.log notice;
error_log /var/log/nginx/download.github.example.com.error.log notice;
```
