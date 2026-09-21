# NexCell DevOps Assessment

## ABOUT YOU

**Name:** Yassine Chouket 

## BUILD AND RUN

**What I delivered:** a FastAPI API (`GET /health` liveness, `GET /ready` checks Postgres+Redis), a Redis-queue worker, a tracked SQL migration runner, a hardened production `Dockerfile`, a `docker-compose.yml` (postgres, redis, migrate, api, worker — healthchecks, restart policies, CPU/memory limits, bounded logs), `smoke_test.sh`, and a GitHub Actions workflow: a `test` job that runs on every PR, and a `deploy` job that is **designed only** (see AWS Design) and safely no-ops without AWS credentials.

Run and verify:
```
cp .env.example .env
docker compose up --build
./smoke_test.sh
```
All of the above was run and verified locally (build, healthy dependency chain, migration idempotency, worker consuming a pushed job, smoke test pass/fail paths). It has not been run on GitHub's own runners in this session — only reproduced locally with the same commands CI uses.

**Top 3 problems the assessment's described starting Dockerfile has, fixed here:**
1. **Mutable/unpinned base and deps** → `python:3.12.9-slim-bookworm` pinned, and every dependency pinned exactly in `requirements.txt`. Prevents a rebuild silently shipping a different Python or library version.
2. **Running as root with a dev server** → dedicated non-root `appuser`, and `uvicorn --workers 2` with no `--reload`. Reduces container breakout blast radius and removes dev-only overhead from the request path.
3. **No build caching, secrets via `ENV`** → `requirements.txt` is copied and installed before the app source (code-only changes reuse the dependency layer), and no credential is ever baked into the image; `POSTGRES_DSN`/`REDIS_URL` are supplied at runtime only.

**Reproducibility & safe migrations:** dependencies are exact-pinned (`==`) in `requirements.txt`, no floating versions. Migrations live in `app/migrations/*.sql` and are applied by `migrate.py`, which tracks what ran in a `schema_migrations` table (idempotent, additive-only — no destructive statements). It runs as its own one-off container that must **exit 0** before `api`/`worker` start (`depends_on: condition: service_completed_successfully`) — verified locally both for the happy path and for a deliberately broken migration, which correctly blocked the API/worker from starting.

## AWS DESIGN

*Design/documentation only — no AWS infrastructure is provisioned by this repository.*

**Target architecture:**
```
Client -> CloudFront -> Frontend (Fargate)
Client -> ALB -> API (Fargate) -> Redis (ElastiCache) <- Worker (Fargate)
                   \-> PostgreSQL (external, managed)
```
API and worker (this repo's image, two task definitions) run on ECS Fargate in **eu-west-2**; frontend is a third Fargate service behind CloudFront. Redis (ElastiCache) is shared cache + job-queue broker. PostgreSQL is managed outside AWS. A vector-DB EC2 (m5.xlarge) and admin-tool EC2 (t3.large) run alongside, outside the container path.

**Networking & security *(proposed)*:** ALB/CloudFront in public subnets; ECS tasks, ElastiCache, both EC2s in private subnets behind a NAT gateway. Security groups scoped tightly (API SG only from ALB SG, worker has no inbound rule, Redis SG only from api/worker). Least-privilege IAM: separate task role per service. Runtime secrets (`POSTGRES_DSN`, `REDIS_URL`) in **Secrets Manager**, injected via `secrets:`, never `environment:`. **CI → AWS auth:** today the assessment states long-lived access keys in GitHub secrets; the required fix is **GitHub Actions OIDC** assuming a scoped IAM role for short-lived STS credentials — the pattern is written into `ci.yml`'s `deploy` job, but it has never been exercised against a real AWS account/role.

**Zero-downtime deploy & rollback *(proposed, extending the compose pattern above)*:** SHA-tagged immutable image; the same migration-gate pattern as a one-off ECS task before the service updates; ALB health check on `/health`; rolling deployment (`minimumHealthyPercent=100`); ECS deployment circuit breaker for automatic rollback to the last healthy revision.

**Monitoring — 3 initial alarms** *(thresholds are starting points, not measured baselines — no production history exists)*:

| Metric | Threshold | Period | Why |
|---|---|---|---|
| ALB 5xx rate | >5% of requests | 5 min × 2 | Direct signal the API or a dependency is failing users. |
| ALB p95 latency | >1000ms | 5 min × 3 | Catches degradation before outright errors. |
| Redis job-queue depth (custom metric) | >500 pending | 5 min × 3 | Worker stalled/behind; risks memory pressure on the shared cache node. |

## COST

Baseline **£1,415/month** (assessment's 10 line items, sums exactly). Excludes the separate £900/month LLM API cost. Target: 20 × £45 = **£900/month** → cut of **≥£515/month**. All savings below are **estimates against the assessment's rounded figures**, not measured AWS pricing.

**Top 3 savings:**
| Change | Est. £/month | Risk |
|---|---|---|
| Schedule staging off outside business hours (it's a 24/7 full-prod copy today) | £155 | Blocks off-hours dev access → manual on-demand start. |
| Queue-depth autoscaling for workers, min 1 warm replica (queue empty 70% of the time) | £75 | Burst after idle could lag → keep 1 warm replica, fast scale-up. |
| Replica-count autoscaling for API (avg 12% CPU) | £55 | Average hides peak bursts → scale on p95, keep HA floor. |

The remaining ~£235 comes from smaller, lower-risk items (log level/retention, one Redis tier down after validating peak, NAT VPC endpoints, admin EC2 scheduling, ECR lifecycle cleanup, a Savings Plan — not a size change — for the vector DB, since no utilization data exists for it). Total estimated savings **£520/month** → projected AWS total **£895/month** → **£44.75/customer** (under the £45 target).

**Not cutting:** NAT Gateway per-AZ redundancy — the saving is small and collapsing it creates a single point of failure for all private-subnet egress. **Catching a spike early:** AWS Budgets threshold alerts + Cost Anomaly Detection per service, plus cost-allocation tags so Cost Explorer can attribute a spike within hours.

## JUDGEMENT

**Scaling to 100 customers:** the target becomes £4,500/month at the same £45/customer bar. ECS Fargate and ElastiCache scale horizontally without a redesign; the likely bottleneck is the single external PostgreSQL instance (connection limits, vertical-only scaling) and NAT data-processing volume growing with traffic — both would need attention before 5x load, not after.

**Biggest production risk, first fix:** manual, unordered migrations with no automated gate — a bad migration can ship silently, and there's no alerting to catch it fast. This repo already fixes the *local* version of that (a migration step that must succeed before the app starts); the first real fix in AWS is wiring that same one-off-task gate into the actual ECS deploy pipeline, which today only updates the running service and doesn't touch migrations at all.

**Kept intentionally simple:** the `deploy` job pushes `:latest` and calls `--force-new-deployment` instead of registering a new task-definition revision pinned to the commit SHA (noted directly in `ci.yml`). With 3 more hours: implement that SHA-pinned render/deploy step so ECS is provably running the exact commit that passed CI, not just "whatever `:latest` currently resolves to."
