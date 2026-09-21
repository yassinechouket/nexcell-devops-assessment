import os

import psycopg2
import redis
from fastapi import FastAPI, Response

app = FastAPI()

POSTGRES_DSN = os.environ.get(
    "POSTGRES_DSN", "postgresql://postgres:postgres@localhost:5432/postgres"
)
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")


def postgres_ok() -> bool:
    try:
        conn = psycopg2.connect(POSTGRES_DSN, connect_timeout=2)
        conn.close()
        return True
    except Exception:
        return False


def redis_ok() -> bool:
    try:
        redis.from_url(REDIS_URL, socket_connect_timeout=2).ping()
        return True
    except Exception:
        return False


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/ready")
def ready(response: Response):
    checks = {"postgres": postgres_ok(), "redis": redis_ok()}
    response.status_code = 200 if all(checks.values()) else 503
    return {"status": "ready" if all(checks.values()) else "not ready", "checks": checks}
