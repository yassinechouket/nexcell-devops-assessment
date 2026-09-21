import json
import os

import redis

REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
QUEUE_NAME = os.environ.get("QUEUE_NAME", "jobs")


def process_job(job: dict) -> None:
    print(f"Processing job: {job}")


def main() -> None:
    r = redis.from_url(REDIS_URL)
    print(f"Worker started, listening on queue '{QUEUE_NAME}'")
    while True:
        try:
            item = r.blpop(QUEUE_NAME, timeout=5)
        except redis.exceptions.TimeoutError:
            continue
        if item is None:
            continue
        _, payload = item
        try:
            job = json.loads(payload)
        except json.JSONDecodeError:
            job = {"raw": payload.decode("utf-8", errors="replace")}
        process_job(job)


if __name__ == "__main__":
    main()
