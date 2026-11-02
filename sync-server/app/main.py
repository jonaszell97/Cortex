"""HTTP API of the sync server (docs/SYNC.md, "Server API").

The server is a mailbox: it orders opaque, end-to-end encrypted records by a sequence number and
keeps the newest write per record. It never sees content, and it never logs payloads or blobs.
"""

import asyncio
import base64
import binascii
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress
import hmac
import json
import logging
import time
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Path, Query, Request, Response
from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    field_validator,
    model_validator,
)
from pydantic.alias_generators import to_camel
from starlette.concurrency import run_in_threadpool
from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.config import Settings
from app.prune import prune, prune_daily
from app.store import Record, Store

log = logging.getLogger("sync")

RECORD_ID = r"^[0-9a-f]{32}$"
BLOB_ID = r"^[0-9a-f]{32,64}$"
DEVICE_ID = r"^[A-Za-z0-9._-]{1,64}$"
MAX_PUSH_RECORDS = 500
MAX_BLOB_IDS = 1000
# A sealed tombstone (protocol v2) is a few dozen bytes; the cap keeps tombstones, which skip the
# storage check, from carrying data.
MAX_TOMBSTONE_PAYLOAD = 1024
# A `modifiedAt` further ahead of the server's clock would win last-writer-wins for good.
MAX_CLOCK_LEAD_MS = 24 * 60 * 60 * 1000
# The longest `/v1/changes` holds an answer for a push to arrive (`wait`), and how often a held
# request checks that the client is still there.
MAX_WAIT_SECONDS = 60
DISCONNECT_CHECK_SECONDS = 1.0

BlobID = Annotated[str, Field(pattern=BLOB_ID)]


class RecordIn(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)

    collection: Literal["clip", "snippet", "action", "reading", "knowledge", "device", "meta"]
    id: str = Field(pattern=RECORD_ID)
    modified_at: int = Field(ge=0, le=2**53)
    device: str = Field(pattern=DEVICE_ID)
    deleted: bool
    keep: bool = False
    blobs: list[BlobID] = Field(default_factory=list, max_length=MAX_BLOB_IDS)
    payload: bytes | None

    @field_validator("payload", mode="before")
    @classmethod
    def decode_payload(cls, value: Any) -> Any:
        if isinstance(value, str):
            try:
                return base64.b64decode(value, validate=True)
            except binascii.Error as error:
                raise ValueError("payload is not valid base64") from error
        return value

    @field_validator("modified_at")
    @classmethod
    def check_clock(cls, value: int) -> int:
        if value > time.time() * 1000 + MAX_CLOCK_LEAD_MS:
            raise ValueError("modifiedAt is more than a day ahead of the server's clock")
        return value

    @model_validator(mode="after")
    def check_tombstone(self) -> "RecordIn":
        # Since protocol v2 a tombstone carries a small sealed payload; v1 tombstones have none.
        if not self.deleted and self.payload is None:
            raise ValueError("every record except a tombstone has a payload")
        if self.deleted and self.payload is not None and len(self.payload) > MAX_TOMBSTONE_PAYLOAD:
            raise ValueError(f"a tombstone payload exceeds {MAX_TOMBSTONE_PAYLOAD} bytes")
        return self

    def to_record(self) -> Record:
        return Record(
            collection=self.collection,
            id=self.id,
            modified_at=self.modified_at,
            device=self.device,
            deleted=self.deleted,
            keep=self.keep,
            blob_ids=tuple(self.blobs),
            payload=self.payload,
        )


class PushIn(BaseModel):
    device: str = Field(pattern=DEVICE_ID)
    records: list[RecordIn] = Field(max_length=MAX_PUSH_RECORDS)


class MissingIn(BaseModel):
    ids: list[BlobID] = Field(max_length=MAX_BLOB_IDS)


def record_json(record: Record) -> dict[str, Any]:
    return {
        "collection": record.collection,
        "id": record.id,
        "seq": record.seq,
        "modifiedAt": record.modified_at,
        "device": record.device,
        "deleted": record.deleted,
        "keep": record.keep,
        "blobs": list(record.blob_ids),
        "payload": None if record.payload is None else base64.b64encode(record.payload).decode(),
    }


class PushSignal:
    """Wakes the `/v1/changes` requests that wait for a push. Used on the event loop only."""

    def __init__(self) -> None:
        self._event = asyncio.Event()

    def current(self) -> asyncio.Event:
        """The event the next push sets. Taken before reading `last_seq`, so a push that lands in
        between still wakes the waiter."""
        return self._event

    def notify(self) -> None:
        self._event.set()
        self._event = asyncio.Event()


def get_store(request: Request) -> Store:
    return request.app.state.store


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


def require_token(settings: Annotated[Settings, Depends(get_settings)], request: Request) -> None:
    scheme, _, token = request.headers.get("authorization", "").partition(" ")
    valid = scheme.lower() == "bearer" and hmac.compare_digest(
        token.encode(), settings.token.encode()
    )
    if not valid:
        raise HTTPException(401, "invalid or missing token", headers={"WWW-Authenticate": "Bearer"})


async def read_body(request: Request, limit: int) -> bytes:
    """Reads the request body, refusing it with 413 as soon as it exceeds `limit` bytes."""
    too_large = HTTPException(413, f"body exceeds {limit} bytes")
    length = request.headers.get("content-length")
    if length is not None and length.isdigit() and int(length) > limit:
        raise too_large
    chunks: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > limit:
            raise too_large
        chunks.append(chunk)
    return b"".join(chunks)


async def read_json[M: BaseModel](request: Request, model: type[M]) -> M:
    body = await read_body(request, get_settings(request).max_json_bytes)
    try:
        # In the threadpool: validating a 32 MB body would hold up every other request.
        return await run_in_threadpool(model.model_validate_json, body)
    except ValidationError as error:
        raise HTTPException(
            422, json.loads(error.json(include_input=False, include_url=False))
        ) from None


def require_space(store: Store, settings: Settings) -> None:
    """Refuses new data with 507 once the database is at its size cap."""
    if store.size_bytes() >= settings.max_storage_bytes:
        log.warning("storage cap of %d bytes reached", settings.max_storage_bytes)
        raise HTTPException(507, "the sync server's storage is full")


def json_response(content: dict[str, Any]) -> Response:
    return Response(json.dumps(content, separators=(",", ":")), media_type="application/json")


StoreDep = Annotated[Store, Depends(get_store)]
SettingsDep = Annotated[Settings, Depends(get_settings)]
BlobPath = Annotated[str, Path(pattern=BLOB_ID)]

api = APIRouter(prefix="/v1", dependencies=[Depends(require_token)])


async def wait_for_push(request: Request, store: Store, since: int, seconds: int) -> None:
    """Holds a `/v1/changes` request until the database has a record after `since`, for at most
    `seconds`. Stops early when the client hangs up, so abandoned waits don't hold the server's
    few connections (`--limit-concurrency`)."""
    signal: PushSignal = request.app.state.pushes
    deadline = time.monotonic() + seconds
    event = signal.current()
    # Not equal also covers a cursor ahead of the database, which the page answers with a new epoch.
    if await run_in_threadpool(store.last_seq) != since:
        return
    while (remaining := deadline - time.monotonic()) > 0 and not await request.is_disconnected():
        with suppress(TimeoutError):
            await asyncio.wait_for(event.wait(), min(remaining, DISCONNECT_CHECK_SECONDS))
        if event.is_set():
            event = signal.current()
            if await run_in_threadpool(store.last_seq) != since:
                return


def changes_page(store: Store, settings: Settings, since: int, limit: int) -> Response:
    if since > store.last_seq():
        # The client has seen a `seq` this database never handed out, so the database was rolled
        # back (restored from a backup) without a new epoch. A new epoch makes both clients
        # reset their cursor and upload again, instead of skipping the numbers handed out anew.
        epoch = store.rotate_epoch()
        log.warning("changes: cursor %d is ahead of the database, new epoch", since)
        return json_response({"records": [], "cursor": 0, "more": False, "epoch": epoch})
    records, more = store.changes(since, limit, settings.max_page_bytes)
    log.info("changes: since=%d returned=%d more=%s", since, len(records), more)
    return json_response(
        {
            "records": [record_json(record) for record in records],
            "cursor": records[-1].seq if records else since,
            "more": more,
            "epoch": store.epoch,
        }
    )


@api.get("/changes")
async def changes(
    request: Request,
    store: StoreDep,
    settings: SettingsDep,
    since: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=1000)] = 200,
    wait: Annotated[int, Query(ge=0, le=MAX_WAIT_SECONDS)] = 0,
) -> Response:
    if wait:
        await wait_for_push(request, store, since, wait)
    # In the threadpool, so reading a page and encoding it as JSON never blocks the event loop.
    return await run_in_threadpool(changes_page, store, settings, since, limit)


@api.post("/push")
async def push(request: Request, store: StoreDep, settings: SettingsDep) -> dict[str, Any]:
    body = await read_json(request, PushIn)
    for record in body.records:
        if record.payload is not None and len(record.payload) > settings.max_record_bytes:
            raise HTTPException(413, f"a record payload exceeds {settings.max_record_bytes} bytes")
    if not all(record.deleted for record in body.records):
        await run_in_threadpool(require_space, store, settings)
    results = await run_in_threadpool(store.push, [record.to_record() for record in body.records])
    applied = sum(result.status == "applied" for result in results)
    if applied:
        request.app.state.pushes.notify()
    log.info(
        "push: device=%s records=%d applied=%d stale=%d",
        body.device,
        len(results),
        applied,
        len(results) - applied,
    )
    return {
        "results": [
            {
                "collection": result.collection,
                "id": result.id,
                "status": result.status,
                "seq": result.seq,
            }
            for result in results
        ],
        "epoch": store.epoch,
    }


@api.post("/blobs/missing")
async def missing_blobs(request: Request, store: StoreDep) -> dict[str, Any]:
    body = await read_json(request, MissingIn)
    missing = await run_in_threadpool(store.missing_blobs, body.ids)
    log.info("blobs/missing: asked=%d missing=%d", len(body.ids), len(missing))
    return {"missing": missing, "epoch": store.epoch}


@api.put("/blobs/{blob_id}")
async def put_blob(
    request: Request, store: StoreDep, settings: SettingsDep, blob_id: BlobPath
) -> dict[str, Any]:
    await run_in_threadpool(require_space, store, settings)
    data = await read_body(request, settings.max_blob_bytes)
    stored = await run_in_threadpool(store.put_blob, blob_id, data, int(time.time() * 1000))
    log.info("blobs/put: bytes=%d stored=%s", len(data), stored)
    return {"stored": stored, "epoch": store.epoch}


@api.get("/blobs/{blob_id}")
async def get_blob(store: StoreDep, blob_id: BlobPath) -> Response:
    data = await run_in_threadpool(store.get_blob, blob_id)
    if data is None:
        raise HTTPException(404, "no such blob")
    return Response(data, media_type="application/octet-stream")


class EpochHeaderAndLog:
    """Gives every response the epoch, also the ones without a JSON body (blobs, errors), and logs
    it. Plain ASGI rather than `@app.middleware("http")`, which hides a client hanging up from
    `Request.is_disconnected()` (`wait_for_push` relies on it)."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        start = time.perf_counter()
        status = 0

        async def send_with_epoch(message: Message) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                MutableHeaders(scope=message)["X-Sync-Epoch"] = scope["app"].state.store.epoch
            await send(message)

        await self.app(scope, receive, send_with_epoch)
        log.info(
            "%s %s %d %.1fms",
            scope["method"],
            scope["path"],
            status,
            (time.perf_counter() - start) * 1000,
        )


def create_app(settings: Settings | None = None) -> FastAPI:
    """`settings` is for tests; without it they are read from the environment at startup."""

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
        resolved = settings or Settings.from_env()
        resolved.data_dir.mkdir(parents=True, exist_ok=True)
        store = Store(resolved.data_dir / "sync.sqlite")
        app.state.settings = resolved
        app.state.store = store
        app.state.pushes = PushSignal()
        prune(store, resolved.prune_clip_days)
        task = asyncio.create_task(prune_daily(store, resolved.prune_clip_days))
        try:
            yield
        finally:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
            store.close()

    app = FastAPI(
        title="Cortex Sync", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None
    )

    app.add_middleware(EpochHeaderAndLog)

    @app.get("/v1/health")
    async def health(store: StoreDep) -> dict[str, Any]:
        # `maxWait` tells clients that `/v1/changes` can wait for a push, and for how long.
        return {"status": "ok", "epoch": store.epoch, "maxWait": MAX_WAIT_SECONDS}

    app.include_router(api)
    return app


app = create_app()
