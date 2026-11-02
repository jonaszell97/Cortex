# Cortex Sync Server

The mailbox between the two Macs (see [Server API](../docs/SYNC.md#server-api)). It stores
end-to-end encrypted records and blobs, orders them by a sequence number and keeps the newest
write per record. It can't read any of it.

```sh
uv sync
uv run pytest
SYNC_TOKEN=$(openssl rand -hex 32) DATA_DIR=./data uv run uvicorn app.main:app --port 8787
```

| Env var | Default | |
| --- | --- | --- |
| `SYNC_TOKEN` | (required) | Bearer token, at least 16 characters |
| `DATA_DIR` | `/data` | Holds `sync.sqlite` |
| `PRUNE_CLIP_DAYS` | `60` | Unpinned clip records older than this are removed from the server |
| `MAX_BLOB_MB` | `32` | Largest blob upload |
| `MAX_JSON_MB` | `32` | Largest JSON body (push, blobs/missing) |
| `MAX_STORAGE_MB` | `2048` | Database size above which pushes and blob uploads get 507 (deletions still go through) |

A record's payload is capped at 4 MB (413), and a page of `/v1/changes` ends early, with
`more: true`, once it holds 8 MB of payloads.

Every response has an `X-Sync-Epoch` header; JSON responses also carry `epoch` in the body.

**After restoring `sync.sqlite` from a backup**, give it a new epoch, so both Macs upload again
instead of skipping `seq` numbers the restored database hands out a second time:

```sh
docker compose -f compose-example.yaml exec sync python -m app.store rotate-epoch /data/sync.sqlite
```

(The server also rotates the epoch by itself when a client asks for changes past the last `seq`
it has handed out, which catches most restores.)

`tests/fixtures/` holds the protocol as request/response pairs, shared with the Swift tests.

How to deploy the server is in [Deployment](../docs/SYNC.md#deployment).
