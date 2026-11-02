"""Server settings, read from environment variables."""

from dataclasses import dataclass
import os
from pathlib import Path

MB = 1024 * 1024


@dataclass(frozen=True)
class Settings:
    token: str
    data_dir: Path = Path("/data")
    prune_clip_days: int = 60
    max_blob_bytes: int = 32 * MB
    # A push carries up to 50 records, and a clip can hold several inline representations of up
    # to 256 KB each (base64 adds a third), so this leaves room for a full batch.
    max_json_bytes: int = 32 * MB
    # One record's sealed payload. Clips carry large content as blobs, so a payload stays well
    # below this.
    max_record_bytes: int = 4 * MB
    # A page of /v1/changes stops growing at this many payload bytes, so a few large records
    # don't make one response of hundreds of megabytes.
    max_page_bytes: int = 8 * MB
    # The database file may not grow beyond this: the disk is shared with other apps. Pushes and
    # blob uploads are refused with 507 above it; deletions still go through.
    max_storage_bytes: int = 2048 * MB

    @classmethod
    def from_env(cls) -> "Settings":
        token = os.environ.get("SYNC_TOKEN", "")
        if len(token) < 16:
            raise RuntimeError("SYNC_TOKEN is required and must be at least 16 characters")
        return cls(
            token=token,
            data_dir=Path(os.environ.get("DATA_DIR", "/data")),
            prune_clip_days=int(os.environ.get("PRUNE_CLIP_DAYS", "60")),
            max_blob_bytes=int(os.environ.get("MAX_BLOB_MB", "32")) * MB,
            max_json_bytes=int(os.environ.get("MAX_JSON_MB", "32")) * MB,
            max_storage_bytes=int(os.environ.get("MAX_STORAGE_MB", "2048")) * MB,
        )
