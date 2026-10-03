# outbound-proxy-private-ca

End-to-end check of the 0.25.5 outbound HTTPS rules: `HTTPS_PROXY`,
`ALL_PROXY`, `NO_PROXY` and `SSL_CERT_FILE`, through a real `CONNECT` proxy
to an origin signed by a private CA, plus the daemon TLS listener queried
over `https://localhost`. Docker and the local binary only, no cluster,
a few seconds.

```
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel ./scenarios/outbound-proxy-private-ca/verify.sh
```

## Setup

- `openssl` mints a throwaway CA and a server certificate with SAN
  `DNS:tls-origin`, `DNS:localhost`, `IP:127.0.0.1`, in a `mktemp` directory
  (`fixtures/openssl.cnf`).
- One user-defined docker network holds `tls-origin`, nginx on `:443`
  (`fixtures/nginx.conf`, nginx 1.29 alpine-slim, about 22 MB), serving `/r/report.json` (the G2 fixture of `verify-hash-roundtrip`,
  hash-baked by the binary under test), `/r/redirect` (302) and `/r/big`
  (11 MiB, above the 10 MiB cap).
- tinyproxy 1.11.3, published on a free `127.0.0.1` port, logs one
  `CONNECT host:port` line per tunnel. The host cannot resolve
  `tls-origin`, so a fetch that succeeds went through the tunnel.

Both images are pinned by digest.

## What it checks

`verify-hash --url https://tls-origin/r/<path>`:

| Leg | Environment | Expected |
| --- | --- | --- |
| V1 | `HTTPS_PROXY` + `SSL_CERT_FILE` | exit 2, `[OK] Content hash`, new `CONNECT tls-origin:443` |
| V2 | `HTTPS_PROXY` only | exit 4, certificate error, after a `CONNECT` |
| V3 | nothing | exit 4 on DNS, no `CONNECT` |
| V4 | `HTTPS_PROXY` + `NO_PROXY=tls-origin` | exit 4 on DNS, no `CONNECT` |
| V5 | `ALL_PROXY` + `SSL_CERT_FILE` | exit 2, `[OK] Content hash`, new `CONNECT` |
| V6 | `HTTPS_PROXY=socks5://127.0.0.1:1` | "only http:// proxy URLs are supported" warning, direct DNS failure, exit 4 |
| V7 | `/r/redirect` | exit 4, `http status 302` |
| V8 | `/r/big` | exit 4, `exceeds 10485760 byte cap` |

Exit 2 is PARTIAL: the content hash matches and the report carries no
signature, which is the most `--url` can reach without a cosign bundle.

`watch` with `[daemon] tls_cert_path` / `tls_key_path` on the private-CA
certificate, then `query --daemon https://localhost:<port> status`:

| Leg | Environment | Expected |
| --- | --- | --- |
| T1 | `SSL_CERT_FILE`, then nothing | exit 0, then non-zero |
| T2 | `HTTPS_PROXY` + `NO_PROXY=localhost` + `SSL_CERT_FILE` | exit 0, no `CONNECT localhost` |
| T3 | `HTTPS_PROXY` + `SSL_CERT_FILE` | non-zero, the proxy logs `CONNECT localhost:<port>` |

With 0.25.4 the scenario fails: V1, V5, V7 and V8 stop on
`UnknownIssuer` (ureq ignored `SSL_CERT_FILE`), V6 has no warning, T1 and T2
fail without the CA, and T3 sees no `CONNECT` (the daemon client had no
proxy). V2, V3 and V4 pass on both versions.

## Watch out

- `query` prints `HTTP transport error` without the TLS cause, so T1 proves
  the trust failure by the pair of calls that differ only by
  `SSL_CERT_FILE`, not by the message.
- T3 is the documented trap: an inherited `HTTPS_PROXY` also tunnels
  `https://localhost`, loopback is only exempt when `NO_PROXY` lists it.
- V3, V4 and V6 rely on the host failing to resolve `tls-origin`. The
  pre-flight stops the run when the host resolves it (search domain,
  `/etc/hosts`), so it never reads as a product failure.
- Every leg and readiness probe runs under `env -u` for all proxy and trust
  variables (the daemon probe also passes `--noproxy '*'`), so a proxy set
  in the operator's shell does not leak in.
- Each leg counts `CONNECT` lines from its own baseline, and a failing
  `docker logs` stops the run instead of counting as zero.
- The trap removes both containers, the network, the daemon, its socket and
  the temp directory (with the 11 MiB file). Only the two images (about
  22 MB and 24 MB) stay, for the next run.
