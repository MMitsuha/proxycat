# MITM HTTPS Rewriting

ProxyCat supports mihomo's `mitm` configuration block for HTTP and HTTPS rewrite rules. MITM is disabled by default and only runs for the active profile when both conditions are true:

- `mitm.enable` is `true`.
- The intercepted TCP destination port is listed in `mitm.ports`.

UDP traffic, inner MITM upstream legs, and traffic on unlisted ports bypass MITM.

## Certificate Setup

HTTPS rewriting requires iOS to trust ProxyCat's local MITM root CA.

1. Open ProxyCat Settings.
2. In `MITM Certificate`, tap `Install Certificate`.
3. iOS opens the generated `mitm_ca.crt`.
4. Install the downloaded profile in iOS Settings > General > VPN & Device Management.
5. Enable full trust in iOS Settings > General > About > Certificate Trust Settings.
6. Return to ProxyCat Settings and tap `Refresh Status`.

ProxyCat stores the generated files in the shared App Group working directory:

- `Working/mitm_ca.crt`
- `Working/mitm_ca.key`

Keep `mitm_ca.key` private. If the certificate or key is deleted, ProxyCat creates a new local root CA the next time `Install Certificate` is used, and any previously installed root CA should be removed from iOS.

## YAML Shape

Add a `mitm` block to a profile that needs rewrite behavior:

```yaml
mitm:
  enable: true
  ports:
    - 80
    - 443
  rules:
    - url: '^https?://ads\.example\.com/.*'
      action: reject

    - url: '^https?://api\.example\.com/v1/(.*)'
      action: '302'
      new: 'https://api.example.com/v2/$1'

    - url: '^https?://example\.com/.*'
      action: request-header
      old: 'User-Agent: .*'
      new: 'User-Agent: mihomo-mitm'

    - url: '^https?://example\.com/score'
      action: response-body
      old: '"score":\d+'
      new: '"score":999'
```

`url` is a regular expression matched against the request URL. Request rules and response rules are evaluated in profile order, and the first matching rule in each phase is used.

## Actions

Request-side actions:

- `reject`: return `404`.
- `reject-200`: return an empty `200` HTML response.
- `reject-img`: return a 1x1 PNG.
- `reject-dict`: return `{}` with JSON content type.
- `reject-array`: return `[]` with JSON content type.
- `302`: return a `302` redirect to `new`.
- `307`: return a `307` redirect to `new`.
- `request-header`: rewrite request headers with `old` and `new`.
- `request-body`: rewrite request body with `old` and `new`.

Response-side actions:

- `response-header`: rewrite response headers with `old` and `new`.
- `response-body`: rewrite response body with `old` and `new`.

For `302` and `307`, `new` may reference URL capture groups as `$1`, `$2`, and so on. For header and body rewrites, `old` is the regular expression to replace and `new` may also reference capture groups. If `old` is omitted for a header or body rewrite, it defaults to `.*`.

Body rewrites are intentionally limited to text-like payloads with a known `Content-Length`, including `text/*`, `application/json`, XML, Atom, XHTML, and form-encoded content. Gzip response bodies are decompressed before replacement, and the rewritten response is sent without `Content-Encoding`.

## iOS Notes

For ProxyCat profiles, keep `tun.enable: true`; the Network Extension still owns the TUN file descriptor and route setup. Do not add `tun.file-descriptor` manually.

MITM only changes traffic that matches the `mitm` block. Normal routing, proxy selection, rules, DNS behavior, and the native Proxies / Connections views continue to use the rest of the active mihomo profile.
