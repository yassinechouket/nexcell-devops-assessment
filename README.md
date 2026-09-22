# NexCell DevOps Assessment

## ABOUT ME

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

## AWS Design

This section is a design/documentation exercise only — no AWS infrastructure is provisioned by this repository. Facts below come directly from the assessment brief; everything else is marked **(proposed)** or **(assumption)**.

### 1. Target architecture

All components run in **eu-west-2 (London)**. The API and worker in this repo (`app/main.py`, `app/worker.py`) map onto two ECS Fargate services built from the same image: the API sits behind an Application Load Balancer, the worker has no public entry point and only consumes jobs from Redis. The frontend is a separate ECS Fargate service fronted by CloudFront. ElastiCache Redis is shared as both the cache and the job-queue broker the worker reads from. PostgreSQL is managed outside AWS (out of cost scope). A vector database (EC2 m5.xlarge) and an internal admin tool (EC2 t3.large) run alongside this stack but outside the containerized deployment path.

### 2. Networking and security

- **VPC/subnets (proposed):** ALB and CloudFront stay at the edge in **public subnets**; ECS tasks (api, worker, frontend), ElastiCache, the vector-DB EC2 instance, and the admin-tool EC2 instance sit in **private subnets**, reached only through the ALB or a bastion/VPN. A NAT gateway gives private subnets controlled outbound access (ECR pulls, calls to the external PostgreSQL).
- **Security groups (proposed):** ALB SG allows 443 from the internet; API task SG accepts traffic only from the ALB SG; worker task SG has no inbound rule at all (egress-only to Redis and PostgreSQL); Redis SG accepts traffic only from the api/worker task SGs; the admin-tool EC2 SG is restricted to a VPN/allowlisted range, never `0.0.0.0/0`.
- **IAM (proposed):** least-privilege per service — a shared ECS *execution* role for image pull/log write, and a separate *task* role per service scoped to only the Secrets Manager entries and resources that service needs. No shared "admin" role across services.
- **Secrets:** `POSTGRES_DSN`, `REDIS_URL`, and any future API keys go in **Secrets Manager** and are injected into task definitions via `secrets:` (never `environment:`) — the same "no credentials baked into the image or config file" principle already enforced in this repo's `.env.example`/Dockerfile.
- **CI → AWS auth:** current state (per the assessment) is long-lived AWS access keys in GitHub secrets — a real risk (leak = standing access until manually rotated). Required future state, already reflected in `.github/workflows/ci.yml`'s `deploy` job: **GitHub Actions OIDC** assumes a scoped IAM role per-run via short-lived STS credentials; no access keys stored anywhere.

### 3. Deploying without downtime, with rollback

- **Immutable image:** every build is tagged with the commit SHA (already implemented in `ci.yml`), never deployed by mutable `:latest` alone in a hardened setup.
- **Safe migrations (proposed):** the assessment notes migrations are currently manual and have caused ordering problems. This repo already replaces that with a tracked, idempotent `migrate.py` step (`schema_migrations` table, additive-only SQL) run as the compose `migrate` service. In ECS the same image/command would run as a **one-off ECS task**, required to exit 0 before the service deployment proceeds — mirroring the `depends_on: service_completed_successfully` gate already used in `docker-compose.yml`. Migrations must stay backward-compatible (additive, no drops/renames) so the previous task revision keeps working during rollout.
- **Health checks:** ALB target group health check against `GET /health` (liveness, no DB/Redis dependency) so ECS never routes traffic to a task that hasn't started cleanly; `GET /ready` (checks both dependencies) gates readiness the same way it already gates `api` in Compose.
- **Rolling deployment (proposed):** ECS rolling update with `minimumHealthyPercent=100` / `maximumPercent=200` — new tasks must pass the health check before old tasks are drained, so capacity never drops and there's no traffic gap.
- **Rollback (proposed):** enable the ECS **deployment circuit breaker with rollback** — if new tasks fail health checks, ECS automatically reverts the service to the last healthy task definition revision without manual intervention.

### 4. Initial monitoring alarms

The assessment states current monitoring only checks uptime, with no alerting on error rate, latency, or queue backlog. The three alarms below are **initial thresholds, not measured baselines** — this repo/assessment has no production traffic history yet, so they're a starting point to tune after observing real behavior.

| # | Metric | Proposed threshold | Evaluation period | Why it matters |
|---|--------|--------------------|--------------------|-----------------|
| 1 | ALB `HTTPCode_Target_5XX_Count` ÷ `RequestCount` (5xx rate) | > 5% of requests | 5 min, 2 consecutive periods | Most direct signal that the API or a dependency (Postgres/Redis) is failing users right now. |
| 2 | ALB `TargetResponseTime` (p95) | > 1000ms | 5 min, 3 consecutive periods | Catches degradation (DB pool exhaustion, Redis contention, undersized task) before it becomes outright errors. |
| 3 | Job queue backlog — Redis `LLEN` on the job queue, published as a custom CloudWatch metric (ElastiCache has no native queue-depth metric) | > 500 pending jobs | 5 min, 3 consecutive periods | Signals the worker has stalled or can't keep up; since Redis also serves as the cache, an unbounded backlog risks memory pressure on the same node. |

## Cost Optimization Proposal

Baseline is the assessment's supplied AWS total only — **£1,415/month**, which already sums exactly from the 10 line items below. This excludes the separately-mentioned £900/month LLM API cost; that is not AWS spend and is not part of this analysis. Target: <£45/customer × 20 customers = **£900/month**, i.e. a cut of **at least £515/month**. No current AWS unit prices are assumed anywhere below — every saving is a **percentage reduction against the supplied line item**, not a computed AWS rate.

### Savings by line item

| Item | Current | Measured fact used | Proposed action | Est. saving | New cost |
|---|---|---|---|---|---|
| Staging | £260 | Full production copy, running 24/7 | Schedule down outside business hours (~09:00–19:00 Mon–Fri only) | ~£155 (60%) | £105 |
| Workers Fargate | £190 | Queue empty 70% of the time | Queue-depth autoscaling, **min 1 replica always warm** (not scale-to-zero) | ~£75 (40%) | £115 |
| API Fargate | £210 | Avg 12% CPU | Replica-count autoscaling on load (not shrinking task size yet) | ~£55 (26%) | £155 |
| CloudWatch Logs | £95 | DEBUG level; logs never expire | Drop to INFO/WARN in prod; set 30–90 day retention | ~£50 (53%) | £45 |
| Redis | £150 | 8% memory used | Right-size **one** node tier down, only after confirming peak (not just current) memory/throughput | ~£50 (33%) | £100 |
| NAT Gateways | £140 | *(no direct measurement — general infra cost)* | VPC endpoints for ECR/S3/CloudWatch Logs/Secrets Manager to cut data processed through NAT | ~£40 (29%) | £100 |
| Admin EC2 | £55 | Used only office hours | Schedule stop/start (~09:00–18:00 Mon–Fri) | ~£35 (64%) | £20 |
| Frontend Fargate | £105 | Traffic 10–15% of peak nights/weekends | Same replica autoscaling approach as API | ~£25 (24%) | £80 |
| Vector DB EC2 | £130 | *(no utilization data supplied)* | **No instance right-sizing this round** — commit to a compute Savings Plan only, given an implied steady 24/7 workload | ~£20 (illustrative commitment discount, not a claimed AWS rate) | £110 |
| ALB/CloudFront/S3/ECR | £80 | ~400 old ECR images | ECR lifecycle policy (expire untagged, keep last N tagged); ALB/CloudFront/S3 left unchanged — no waste signal | ~£15 (low confidence) | £65 |

**Highest-value savings:** staging scheduling (£155), worker autoscaling (£75), and API autoscaling (£55) together account for £285 — over half of the total reduction — and are also the three items backed by the strongest measured facts (24/7 idle copy, 70%-empty queue, 12% CPU).

### Risks and mitigations

- **Staging:** blocks devs needing it outside scheduled hours → on-demand manual start (workflow trigger) for exceptions.
- **Workers:** a burst after idle could lag before scale-up → keep 1 warm replica, short scale-up cooldown on queue length.
- **API/Frontend:** average CPU hides peak bursts → scale on p95/target-tracking (not average), keep the existing HA floor (≥2 replicas) for zero-downtime deploys.
- **CloudWatch Logs:** losing DEBUG detail during an incident → keep a temporary log-level override (env var) for active debugging, not permanently on.
- **Redis:** it's both cache and queue broker — undersizing risks eviction storms or write throttling under burst → validate against 2+ weeks of peak (not current) usage before resizing; keep headroom.
- **NAT:** none to reliability — endpoint policies add minor operational surface only.
- **Admin EC2:** blocks after-hours emergency access → manual start runbook for rare out-of-hours need.
- **Vector DB:** 1-year Savings Plan commitment reduces flexibility if load later drops → choose the shortest viable term; commit only up to the confirmed minimum baseline once measured.
- **ECR lifecycle:** could delete an image a live/rollback task definition still references → retention rule always keeps the last N (e.g. 20–30) tagged builds and never touches images referenced by an active task definition.

### Reconciliation

- Total estimated savings: **£520/month**
- Projected AWS total: £1,415 − £520 = **£895/month**
- Projected cost/customer: £895 ÷ 20 = **£44.75/customer/month** — under the £45 target, with a small £5/month margin against the required £515 cut.

### What we are deliberately **not** cutting

**NAT Gateway redundancy (one per AZ).** Collapsing to a single shared NAT Gateway would save only a small slice of the £140 line (the per-gateway hourly charge) but creates a single point of failure for all private-subnet egress — ECR pulls, external PostgreSQL calls, Secrets Manager reads — in that AZ. The target is already reachable without this cut, so the reliability trade-off isn't justified.

### Detecting a future cost spike

- **AWS Budgets** with a monthly threshold alert (e.g. at 80% and 100% of the £900 target) and a forecasted-spend alert.
- **AWS Cost Anomaly Detection** per service, to catch unexpected jumps (e.g. a stuck autoscaling policy) faster than a monthly budget review would.
- Consistent **cost-allocation tags** (service, environment) so Cost Explorer can attribute a spike to a specific line item within hours, not at month-end.
- Cross-reference with the operational alarms above: a sustained queue-backlog or latency alarm firing often correlates with autoscaling stuck at max capacity — i.e., an operational alarm is frequently the earliest signal of a cost spike, not the bill itself.


**Kept intentionally simple:** the `deploy` job pushes `:latest` and calls `--force-new-deployment` instead of registering a new task-definition revision pinned to the commit SHA (noted directly in `ci.yml`). With 3 more hours: implement that SHA-pinned render/deploy step so ECS is provably running the exact commit that passed CI, not just "whatever `:latest` currently resolves to."
