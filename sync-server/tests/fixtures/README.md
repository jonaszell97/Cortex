# Protocol fixtures

Request/response pairs that describe the sync protocol (docs/SYNC.md, "Server API").
`tests/test_fixtures.py` replays them against the real server; the Swift tests replay them against
`InMemorySyncServer`, so both implement the same semantics.

Each file is one scenario against a fresh, empty database:

```json
{
  "description": "what the scenario shows",
  "steps": [
    {
      "request": {
        "method": "POST",
        "path": "/v1/push",
        "auth": true,
        "json": {},
        "bodyBase64": ""
      },
      "response": {
        "status": 200,
        "json": {},
        "bodyBase64": ""
      }
    }
  ]
}
```

- `auth` defaults to `true` (send `Authorization: Bearer <token>`); `false` sends no header.
- A request has `json` (a JSON body), `bodyBase64` (raw bytes, for blobs) or neither.
- A response is compared exactly: `json` must equal the response body, `bodyBase64` its bytes.
  In expected values, `"<epoch>"` matches the server's epoch (the same value in every step of a
  scenario) and `"<any>"` matches anything (error details, which differ between implementations).
