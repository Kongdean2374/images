# ChaiNet Backend (Go)

Stdlib-only by default; HTTP/3 (quic-go) is optional via the `http3` build tag.

| Endpoint | Description |
| --- | --- |
| `GET /ping` | `pong`, echoes `?seq=` in `X-Seq`; no-store |
| `GET /download?bytes=N` | N random (incompressible) bytes, capped by `-max-download`, bounded by `-max-duration` |
| `POST /upload` | body read and discarded, capped by `-max-upload` (413), returns `{"bytes","duration_ms","truncated"}` |
| `GET /health` | `{"status":"ok"|"saturated","active_sessions",...}` |
| `GET /info` | name, location, client IP + family, HTTP protocol, HTTP/3 support, UDP echo port, limits |
| UDP `:9001` | echoes packets starting with `CHNT` (never larger than received; others dropped) |

Protection: per-IP token-bucket rate limit (`-rps`, `-burst`), concurrent transfer limits per IP and global
(`-sessions-per-ip`, `-sessions-total`), max transfer duration, max payload sizes, UDP per-source rate limit,
`X-Forwarded-For` only with `-trust-proxy`.

IPv4 + IPv6: listeners default to `[::]` (dual stack). HTTP/2: h2c on the plain listener, h2 over TLS.

```sh
go test -race ./...
go run ./cmd/chainet-server -name "Taipei-1" -location "Taipei"
# TLS + HTTP/2 + HTTP/3
go run -tags http3 ./cmd/chainet-server -https '[::]:8443' -cert cert.pem -key key.pem
docker build -t chainet-server . && docker run -p 8080:8080 -p 8443:8443/tcp -p 8443:8443/udp -p 9001:9001/udp chainet-server
```
