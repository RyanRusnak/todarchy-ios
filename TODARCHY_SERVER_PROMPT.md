# Prompt — Build todarchy-server

Paste this into a fresh Claude Code session against an empty
`todarchy-server` repo. It gives you everything needed to ship a v1 that
complements the Swift + Linux clients without any code changes on their
side yet (integration is a later, separate task).

## Context

todarchy is a keyboard-first GTD app shipping on macOS, iPhone, iPad,
and Linux. It syncs a single Automerge CRDT document between devices
by writing bytes to a file in a sync folder (Dropbox, iCloud Drive,
Syncthing, or any local folder). Per-project sharing adds encrypted
sibling files named `shared_<projectId>.automerge.enc`, each protected
by a symmetric key communicated via share-link URL fragments.

Your job: build an open-source **self-hostable relay server** that
acts as an alternative transport to Dropbox/iCloud. Clients can PUT
ciphertext blobs to it, GET them back, and (in v2) subscribe for push
notifications when a peer updates a blob.

Crucially: **the server never sees plaintext.** The bytes are
pre-encrypted by the client via ChaCha20-Poly1305. The server is a
dumb blob store that happens to be addressable by project id.

## Non-goals (don't build these)

- **No plaintext anything.** Server must not know how to read
  Automerge bytes. Treat everything as opaque.
- **No accounts, no identity.** Knowing the project id is the only
  credential for v1. Auth is v2 (HKDF-derived write tokens).
- **No MCP endpoints.** MCP needs plaintext; that belongs in a
  separate client-side agent, not this server.
- **No Postgres or Redis.** SQLite handles this workload. One file,
  easy to back up, trivial to deploy.

## Stack

- **Go**, current stable. Standard lib only where reasonable; OK to
  pull small dependencies:
  - `modernc.org/sqlite` (pure-Go SQLite driver, no CGO required —
    makes cross-compilation painless)
  - `github.com/gorilla/websocket` for v2 WS
  - `github.com/go-chi/chi/v5` for routing (or plain `http.ServeMux`;
    your call)
- **SQLite** single file, WAL mode.
- **Docker** for deploy. Keep the image under 20MB (distroless or
  scratch base).

## v1 HTTP API

Routes:

```
GET  /doc/:id
       200  body = ciphertext bytes, Content-Type: application/octet-stream
            ETag: "<sha256-of-bytes>"
            Last-Modified: <RFC1123>
       304  if If-None-Match matches
       404  if no such doc
       400  if id is malformed (see validation below)

PUT  /doc/:id
       body = ciphertext bytes (arbitrary, up to MAX_DOC_BYTES)
       If-Match: "<etag>"   (optional; enforces optimistic concurrency)

       204  on success
            ETag: "<new-sha256>"
            Last-Modified: <RFC1123>
       400  malformed id / too-large body
       412  If-Match provided and didn't match current etag
       415  if Content-Type doesn't look like application/octet-stream

DELETE /doc/:id                (optional in v1 — include if easy)
       204  success or already gone
       400  malformed id

GET  /healthz                 200 "ok"
```

### Request/response details

- **id validation**: project ids are opaque strings from the client
  but in practice match `^[A-Za-z0-9_\-]{1,64}$`. Reject anything
  else with 400 to prevent path traversal or DB-key games.
- **MAX_DOC_BYTES**: default 5 MiB. Configurable via
  `TODARCHY_MAX_DOC_BYTES` env var. Automerge docs for a single
  project should never exceed this in practice; the cap protects
  against DoS.
- **ETag computation**: `"` + hex(SHA-256(bytes)) + `"`. Quoted per
  RFC 7232. Include in both response headers and the DB row.
- **Rate limiting (lightweight)**: optional, document but don't
  require. A user running a reverse proxy will add it anyway.

### Error format

JSON error bodies (except body-less 204/304):

```json
{"error": "short code", "message": "human-readable detail"}
```

Short codes: `malformed_id`, `doc_too_large`, `etag_mismatch`,
`not_found`, `internal`.

### CORS

Enable permissive CORS for all origins and methods on the `/doc/*` and
`/healthz` routes so browser-based tools (and future web clients) work
without proxy hassle. No cookies = no credentials needed.

## Storage

SQLite schema:

```sql
CREATE TABLE IF NOT EXISTS docs (
    id           TEXT    PRIMARY KEY,
    blob         BLOB    NOT NULL,
    etag         TEXT    NOT NULL,
    updated_at   INTEGER NOT NULL,   -- unix millis
    created_at   INTEGER NOT NULL    -- unix millis
) STRICT;

CREATE INDEX IF NOT EXISTS docs_updated_at ON docs(updated_at);

PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
```

Keep the store interface small and swappable for testing:

```go
type Store interface {
    Get(ctx context.Context, id string) (*Doc, error)    // (nil, nil) if not found
    Put(ctx context.Context, id string, blob []byte, ifMatch *string) (*Doc, error)
    Delete(ctx context.Context, id string) error
}

type Doc struct {
    ID         string
    Blob       []byte
    ETag       string
    UpdatedAt  time.Time
    CreatedAt  time.Time
}
```

Provide two implementations: `sqlite.Store` and `memory.Store`. Tests
run against the in-memory one for speed; integration tests exercise
SQLite.

## v2 WebSocket subscription (sketch only for v1 README)

Later:

```
GET  /ws
       (WebSocket upgrade)

Client sends:
  {"type":"subscribe","ids":["p_abc","p_def"]}

Server sends (whenever a subscribed doc changes):
  {"type":"changed","id":"p_abc","etag":"<new-etag>"}

Server also sends heartbeats every 30s:
  {"type":"ping","t":1730000000000}
```

Clients receive `changed`, do a normal GET to fetch the new bytes. No
need to stream ciphertext over the WS — keeps the protocol tiny and
the server stateless about body content.

Write a stub `hub` package with the type signatures but **no
implementation** in v1. Fill it in v2.

## Configuration

Environment variables:

```
TODARCHY_ADDR              default ":8080"
TODARCHY_DB_PATH           default "/data/todarchy.db"
TODARCHY_MAX_DOC_BYTES     default 5242880 (5 MiB)
TODARCHY_CORS_ORIGIN       default "*"
TODARCHY_ADMIN_TOKEN       optional; enables /admin routes when set
TODARCHY_LOG_LEVEL         default "info" (debug | info | warn | error)
```

No config file — env only. Keeps deploy dead-simple.

## Logging

Structured JSON logs via `log/slog`. One line per request:

```json
{"time":"...","level":"info","method":"PUT","path":"/doc/p_abc",
 "status":204,"bytes":12043,"dur_ms":3,"remote":"1.2.3.4"}
```

Never log the body or id unless log level is `debug`. Even the id is
mildly sensitive: if someone sees your server logs, they can request
your blobs (still useless without the key, but unnecessary leakage).

## Admin endpoint (optional v1, nice-to-have)

When `TODARCHY_ADMIN_TOKEN` is set:

```
POST /admin/purge
     Authorization: Bearer <token>
     body (JSON): {"older_than_days": 30}
     204 with count of deleted docs in a `X-Deleted` header

GET /admin/stats
     Authorization: Bearer <token>
     200 JSON: {"doc_count": 123, "total_bytes": 456789, "oldest": "..."}
```

Useful for self-hosters who want to prune or monitor. Safe to skip in
v1 if you're eager to ship.

## Docker

Multi-stage build, distroless final image:

```dockerfile
FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/todarchy-server ./cmd/server

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/todarchy-server /usr/local/bin/todarchy-server
VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/todarchy-server"]
```

`docker-compose.yml`:

```yaml
services:
  todarchy:
    image: ghcr.io/<your-user>/todarchy-server:latest
    restart: unless-stopped
    ports: ["8080:8080"]
    volumes: ["./data:/data"]
    environment:
      TODARCHY_DB_PATH: /data/todarchy.db
```

## Tests

Aim for ~80% coverage on the API + storage. Must cover:

- Round-trip: PUT then GET returns identical bytes.
- ETag stability: PUTting the same bytes twice produces the same
  ETag.
- If-Match: PUT with stale ETag returns 412; PUT with matching ETag
  succeeds; PUT without If-Match always succeeds (latest-writer-wins).
- If-None-Match: GET with matching ETag returns 304.
- 404 on missing docs.
- 400 on malformed id (path traversal attempts, over-long ids,
  special chars).
- 413 / body-size limit on oversized PUTs.
- Concurrent PUTs to the same id: exactly-one succeeds with
  If-Match; both succeed without it (and we keep the later one).
- CORS preflight returns expected headers.

Integration tests spin up an in-process server pointed at a temp-dir
SQLite, exercise the real HTTP handlers.

## README shape

```markdown
# todarchy-server

Self-hostable sync relay for [todarchy](https://github.com/<user>/todarchy).

Stores opaque encrypted blobs. Clients read and write via simple HTTP.
Zero knowledge of contents — your tasks never leave your device in
readable form.

## Deploy

### Docker one-liner
docker run -d -p 8080:8080 -v $PWD/data:/data ghcr.io/<user>/todarchy-server

### docker-compose (recommended)
...

### Fly.io
fly launch --image ghcr.io/<user>/todarchy-server
...

### Bare metal / systemd
...

## Configure the client

Point your todarchy app at your server:
  Settings → Sync → Use server → https://your.server/

## Protocol

See [docs/PROTOCOL.md](docs/PROTOCOL.md).

## License

MIT
```

Keep the README at the "skim in 30 seconds" tier.

## docs/PROTOCOL.md

Spec the full wire protocol in one place so the Linux and Swift
clients can implement without referring back to Go code. Include:

- Exact envelope format (reference todarchy's CryptoBox — just
  describe that the bytes are opaque to the server).
- Endpoint table with status codes.
- ETag algorithm.
- Error body shape.
- Forward-compatibility notes (clients should ignore unknown fields).

This is the contract. Once the server ships v1, the protocol is
frozen — bump a path prefix (`/v2/doc/...`) for breaking changes.

## docs/THREAT_MODEL.md

Be honest about what the server does and doesn't protect against.
Sample outline:

- **Protects against**: server-side data theft (ciphertext only),
  passive network eavesdropping (use TLS), operator access to your
  tasks.
- **Does NOT protect against**: someone stealing a share link (=
  full access to that project), operator deleting or corrupting
  blobs (backups are on you), operator correlating request patterns
  across time.
- **Recommended deploy**: TLS via Caddy/Cloudflare, limited disk
  quotas, offsite backups of `/data`, run on dedicated VPS not
  shared with untrusted workloads.

Helps self-hosters understand what they're buying.

## Checklist

Ship v1 when:

- [ ] `GET /doc/:id`, `PUT /doc/:id`, `GET /healthz` all pass tests.
- [ ] ETag + If-Match + If-None-Match behave per HTTP spec.
- [ ] SQLite persistence survives a restart.
- [ ] Structured JSON logs per request.
- [ ] Docker image < 20MB, runs on Apple Silicon and amd64.
- [ ] README includes three deploy recipes.
- [ ] PROTOCOL.md fully specifies the wire format.
- [ ] THREAT_MODEL.md documents the privacy boundary honestly.

v2 adds WebSocket subscriptions and a Swift/Linux client integration.
Don't build that yet. Ship v1, stand it up, verify you can PUT and
GET from `curl`, then come back to this repo for the subscription
work.
