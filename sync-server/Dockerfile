FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/app/.venv

WORKDIR /app

RUN pip install --no-cache-dir uv==0.9.17

# Dependencies first, so code changes don't reinstall them.
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --frozen --no-dev --no-cache

COPY app ./app

# Owned by the app user, so a fresh named volume mounted here is writable.
RUN useradd --system --uid 10001 --no-create-home cortex \
    && mkdir /data \
    && chown cortex:cortex /data
USER cortex

ENV PATH="/app/.venv/bin:$PATH" \
    DATA_DIR=/data

EXPOSE 8000

# One worker: the store serializes on one SQLite connection, and a push wakes the waiting
# `/v1/changes` requests through memory. Each device holds one of those open; more connections
# than the limit are answered 503 instead of piling up request bodies in memory. On shutdown the
# waiting requests are cut off after 5 s rather than held until their wait ends.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-access-log", "--limit-concurrency", "16", "--timeout-graceful-shutdown", "5"]
