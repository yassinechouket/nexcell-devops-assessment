#!/usr/bin/env bash
set -uo pipefail

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

API_URL="${API_URL:-http://localhost:${API_PORT:-8000}}"
QUEUE_NAME="${QUEUE_NAME:-jobs}"
COMPOSE="docker compose"
CURL_TIMEOUT=5
RETRY_ATTEMPTS=10
RETRY_DELAY=3

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "[PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "[FAIL] $1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[FAIL] required command not found: $1" >&2
    exit 1
  fi
}

retry() {
  local desc="$1"
  shift
  local attempt=1
  while [ "$attempt" -le "$RETRY_ATTEMPTS" ]; do
    if "$@"; then
      return 0
    fi
    echo "  attempt ${attempt}/${RETRY_ATTEMPTS} failed for ${desc}, retrying in ${RETRY_DELAY}s..." >&2
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
  return 1
}

check_health() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" "$API_URL/health" 2>/dev/null)
  [ "$code" = "200" ]
}

check_ready() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" "$API_URL/ready" 2>/dev/null)
  [ "$code" = "200" ]
}

check_redis() {
  local out
  out=$($COMPOSE exec -T redis redis-cli ping 2>/dev/null | tr -d '\r')
  [ "$out" = "PONG" ]
}

check_worker() {
  local marker="smoke_$(date +%s)_$$"
  local payload="{\"task\":\"smoke_test\",\"marker\":\"${marker}\"}"

  if ! $COMPOSE exec -T redis redis-cli rpush "$QUEUE_NAME" "$payload" >/dev/null 2>&1; then
    echo "  could not push test job to redis queue '${QUEUE_NAME}'" >&2
    return 1
  fi

  local attempt=1
  while [ "$attempt" -le "$RETRY_ATTEMPTS" ]; do
    if $COMPOSE logs worker 2>/dev/null | grep -q "$marker"; then
      return 0
    fi
    echo "  attempt ${attempt}/${RETRY_ATTEMPTS}: job not yet consumed, retrying in ${RETRY_DELAY}s..." >&2
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
  return 1
}

require_cmd docker
require_cmd curl

echo "Running smoke tests against ${API_URL}"
echo

if retry "API /health" check_health; then
  pass "API /health returned 200"
else
  fail "API /health did not return 200 within $((RETRY_ATTEMPTS * RETRY_DELAY))s"
fi

if retry "API /ready" check_ready; then
  pass "API /ready returned 200 (postgres and redis reachable)"
else
  fail "API /ready did not return 200 within $((RETRY_ATTEMPTS * RETRY_DELAY))s"
fi

if retry "redis ping" check_redis; then
  pass "Redis responded to PING"
else
  fail "Redis did not respond to PING within $((RETRY_ATTEMPTS * RETRY_DELAY))s"
fi

if check_worker; then
  pass "Worker consumed test job from queue '${QUEUE_NAME}'"
else
  fail "Worker did not consume test job from queue '${QUEUE_NAME}' within $((RETRY_ATTEMPTS * RETRY_DELAY))s"
fi

echo
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi

exit 0
