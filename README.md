# Nexcell DevOps Assessment

This repository contains the work for the Nexcell DevOps technical assessment.

## Initial structure

- `app/` — reserved for the application implementation.
- `.github/workflows/` — reserved for GitHub Actions workflows.

The repository is intentionally minimal at this stage. No application, infrastructure, dependencies, or credentials have been added.

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

