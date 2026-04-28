# n8n on Kubernetes + HashiCorp Vault — Production Deployment

> **Self-hosted n8n article automation**: submit a topic → stored in PostgreSQL → scheduled 3×/week → LLM generates article → email delivered → optional Dev.to publishing.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Repository Structure](#repository-structure)
4. [Quick Start](#quick-start)
5. [Vault Configuration](#vault-configuration)
6. [Storage Design (hostPath)](#storage-design-hostpath)
7. [Why IPs Instead of DNS](#why-ips-instead-of-dns)
8. [Kubernetes Resources Explained](#kubernetes-resources-explained)
9. [Topic Queue Schema](#topic-queue-schema)
10. [n8n Workflow Design](#n8n-workflow-design)
11. [Credentials Setup in n8n UI](#credentials-setup-in-n8n-ui)
12. [Schedule: 3×/week Cron](#schedule-3week-cron)
13. [Email Delivery](#email-delivery)
14. [Optional Dev.to Publishing](#optional-devto-publishing)
15. [Submitting Topics](#submitting-topics)
16. [Environment Variables Reference](#environment-variables-reference)
17. [Operational Best Practices](#operational-best-practices)
18. [Security Recommendations](#security-recommendations)
19. [Troubleshooting](#troubleshooting)
20. [Alternative Topic Storage](#alternative-topic-storage)

---

## Architecture Overview

```
  You ─── HTTPS ──► Ingress (nginx + cert-manager)
                         │
                         ▼
                   ┌──────────────┐      ┌──────────────────┐
                   │  n8n Main    │◄────►│  HashiCorp Vault  │
                   │  (UI +       │      │  (secrets via     │
                   │  Webhooks)   │      │  Agent sidecar)   │
                   └──────┬───────┘      └──────────────────┘
                          │ Bull Queue (Redis by ClusterIP)
                          ▼
              ┌───────────────────────┐
              │  n8n Worker  (×2-5)   │
              └──────────┬────────────┘
                         │
              ┌──────────┴──────────┐
              │                     │
         PostgreSQL              Redis
         (ClusterIP)           (ClusterIP)
         article_topics         Bull queue
         + n8n state
                         │
                Schedule (Mon/Wed/Fri 9am)
                         │
                    LLM API (OpenAI/Claude)
                         │
                   Email (SMTP/Gmail)
               Optional: Dev.to API
```

| Component | Image | Purpose |
|-----------|-------|---------|
| n8n Main | `n8nio/n8n:latest` | UI, webhooks, scheduler |
| n8n Worker (×2) | `n8nio/n8n:latest` | Execute workflow jobs |
| PostgreSQL 15 | `postgres:15-alpine` | n8n state + article queue |
| Redis 7 | `redis:7-alpine` | Bull job queue |
| Vault Agent | sidecar | Inject secrets at runtime |

---

## Prerequisites

- Kubernetes cluster with:
  - Vault installed in `vault` namespace, `vault-0` pod running
  - Vault Agent Injector (mutating webhook) — comes with the Vault Helm chart
  - nginx Ingress Controller
  - cert-manager with a `letsencrypt-prod` ClusterIssuer
- `kubectl` with cluster-admin access
- Required env vars set (see Vault section)

---

## Repository Structure

```
n8n-k8s/
├── vault/
│   ├── 01-vault-setup.sh           # One-time Vault config (run first)
│   └── n8n-policy.hcl              # Vault policy reference
├── k8s/
│   ├── base/namespace.yaml
│   ├── rbac/rbac.yaml
│   ├── storage/
│   │   ├── storage.yaml            # StorageClass, hostPath PVs, PVCs
│   │   └── fix-host-dirs-job.yaml  # Job to create /n8n/* on node
│   ├── postgres/postgres.yaml
│   ├── redis/redis.yaml
│   ├── n8n/
│   │   ├── n8n-main.yaml           # ConfigMap + Deployment + Service
│   │   └── n8n-worker.yaml         # Worker Deployment + HPA
│   └── ingress/ingress.yaml
├── workflows/
│   ├── 01-topic-input-workflow.json
│   ├── 02-scheduled-publisher-workflow.json
│   └── 03-error-handler-workflow.json
├── scripts/
│   └── deploy.sh                   # Master deploy (resolves Service IPs)
└── README.md
```

---

## Quick Start

```bash
# 1. Set environment variables
export VAULT_ROOT_TOKEN="hvs.xxxxxxxxxxxx"
export N8N_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export POSTGRES_PASSWORD="$(openssl rand -base64 24)"
export REDIS_PASSWORD="$(openssl rand -base64 24)"
export SMTP_PASSWORD="your-gmail-app-password"
export LLM_API_KEY="sk-proj-xxxxxxxxxxxx"
export DEV_TOKEN="your-dev-token"       # Optional — skip Dev.to if unset

# 2. Edit your domain and email in the ConfigMap
#    k8s/n8n/n8n-main.yaml → n8n-config section
#    Change: N8N_HOST, WEBHOOK_URL, N8N_SMTP_SENDER, N8N_SMTP_USER

# 3. Configure Vault
chmod +x vault/01-vault-setup.sh
./vault/01-vault-setup.sh

# 4. Create namespace and deploy
kubectl apply -f k8s/base/namespace.yaml

# Optional: pre-create host directories (avoids PVC pending)
kubectl apply -f k8s/storage/fix-host-dirs-job.yaml
kubectl wait --for=condition=complete job/n8n-create-host-dirs -n n8n --timeout=60s

# 5. Run the master deploy script
chmod +x scripts/deploy.sh
./scripts/deploy.sh

# 6. Import workflows in the n8n UI, create credentials, activate workflows
```

---

## Vault Configuration

### Secret Paths

```
secret/
└── n8n/
    ├── core     { encryption_key }
    ├── postgres { password }
    ├── redis    { password }
    ├── smtp     { password }
    ├── llm      { api_key }
    └── devto    { token }          ← optional
```

### How Vault Agent Injection Works

Each pod has these annotations which tell the Vault Agent sidecar to:
1. Authenticate with Vault using the pod's Kubernetes SA token
2. Fetch secrets and render them as shell-sourceable env files
3. Write files to `/vault/secrets/` (memory-backed emptyDir — never on disk)

n8n starts with:
```sh
for f in /vault/secrets/*-env; do . "$f"; done
exec n8n start
```

### Vault Policy

```hcl
path "secret/data/n8n/*" {
  capabilities = ["read"]
}
path "secret/metadata/n8n/*" {
  capabilities = ["list"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
```

The Vault role `n8n` binds to ServiceAccount `n8n-sa` in namespace `n8n`.

---

## Storage Design (hostPath)

### Why hostPath?

The `kubernetes.io/no-provisioner` StorageClass requires manually pre-provisioned PVs. Using `local` volume type with `nodeAffinity` + `WaitForFirstConsumer` **conflicts** with PVC `selector` label matching — the scheduler cannot satisfy both constraints simultaneously, causing PVCs to stay `Pending` forever.

**Fix:** Use `hostPath` PVs with `volumeBindingMode: Immediate`. hostPath PVs:
- Don't require `nodeAffinity`
- Bind immediately via label selectors
- Work reliably on single-node and simple multi-node clusters

### PV/PVC mapping

| PVC | PV | Host path | Size |
|-----|-----|-----------|------|
| `n8n-data-pvc` | `n8n-data-pv` | `/n8n/n8n-data` | 5 Gi |
| `n8n-postgres-pvc` | `n8n-postgres-pv` | `/n8n/postgres` | 10 Gi |
| `n8n-redis-pvc` | `n8n-redis-pv` | `/n8n/redis` | 2 Gi |

The `DirectoryOrCreate` hostPath type creates the directory automatically if missing. Alternatively run the fix Job:

```bash
kubectl apply -f k8s/storage/fix-host-dirs-job.yaml
kubectl wait --for=condition=complete job/n8n-create-host-dirs -n n8n --timeout=60s
```

---

## Why IPs Instead of DNS

By requirement, pods connect to PostgreSQL and Redis using **ClusterIP addresses**, not DNS names. This avoids any potential CoreDNS resolution issues.

`scripts/deploy.sh` resolves the IPs at deploy time:

```bash
PG_IP=$(kubectl get svc n8n-postgres-svc -n n8n -o jsonpath='{.spec.clusterIP}')
REDIS_IP=$(kubectl get svc n8n-redis-svc -n n8n -o jsonpath='{.spec.clusterIP}')
```

It then:
1. Creates `ConfigMap/n8n-svc-ips` with `pg-ip` and `redis-ip` keys
2. Patches `ConfigMap/n8n-config` with `DB_POSTGRESDB_HOST` and `QUEUE_BULL_REDIS_HOST`

Init containers in n8n-main and n8n-worker read `/config/pg-ip` and `/config/redis-ip` (mounted from `n8n-svc-ips`) for TCP readiness checks.

To check current IPs at any time:
```bash
kubectl get configmap n8n-svc-ips -n n8n -o yaml
kubectl get svc -n n8n
```

---

## Kubernetes Resources Explained

### RBAC (`k8s/rbac/rbac.yaml`)

| Resource | Purpose |
|----------|---------|
| `ServiceAccount/n8n-sa` | Identity for all n8n pods; used by Vault Agent to authenticate |
| `ClusterRoleBinding/n8n-vault-token-review` | Grants `system:auth-delegator` so Vault can verify SA tokens |
| `Role/n8n-secret-reader` | Allows n8n pods to read secrets in the `n8n` namespace |

### PostgreSQL (`k8s/postgres/postgres.yaml`)

- Single replica, `Recreate` strategy (required for RWO PVC)
- Vault Agent runs as init + sidecar; writes `/vault/secrets/pg-env`
- Entrypoint wrapper: `source /vault/secrets/pg-env && exec docker-entrypoint.sh postgres`
- `PGDATA=/var/lib/postgresql/data/pgdata` (subdirectory avoids mount issues)
- Init SQL creates `article_topics` table automatically on first start

### Redis (`k8s/redis/redis.yaml`)

- AOF persistence enabled (durability over RDB snapshots)
- Password read from `/vault/secrets/redis-password` at startup
- `maxmemory-policy: allkeys-lru` prevents OOM on queue overflow

### n8n Main (`k8s/n8n/n8n-main.yaml`)

- `EXECUTIONS_MODE=queue` — hands off executions to workers via Redis
- Three init containers: wait-vault-secrets, wait-postgres (by IP), wait-redis (by IP)
- PVC `n8n-data-pvc` mounts at `/home/node/.n8n` (stores workflows, credentials, binary data)

### n8n Workers (`k8s/n8n/n8n-worker.yaml`)

- Stateless — use `emptyDir` for temp data, not a PVC
- Run `n8n worker` command (not `n8n start`)
- HPA scales between 2–5 replicas based on CPU utilization

---

## Topic Queue Schema

Auto-created by PostgreSQL init script on first start:

```sql
CREATE TABLE article_topics (
    id           SERIAL PRIMARY KEY,
    topic        TEXT        NOT NULL,
    status       VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    scheduled_at TIMESTAMPTZ,
    processed_at TIMESTAMPTZ,
    article_url  TEXT,
    error_msg    TEXT,
    retry_count  INT         NOT NULL DEFAULT 0,
    CONSTRAINT status_chk CHECK (status IN ('pending','processing','done','failed'))
);
```

**Status lifecycle:**
```
pending ──► processing ──► done
                       ↘
                       failed  (after 3 retries)
```

**Useful queries:**
```sql
-- View full queue
SELECT id, LEFT(topic, 60), status, retry_count, created_at
FROM article_topics ORDER BY created_at DESC;

-- Re-queue a failed topic
UPDATE article_topics
SET status='pending', retry_count=0, error_msg=NULL
WHERE id = <id>;

-- Clear done topics older than 30 days
DELETE FROM article_topics
WHERE status='done' AND processed_at < NOW() - INTERVAL '30 days';
```

Run queries via kubectl:
```bash
kubectl exec -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-postgres -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U n8n -d n8n -c "SELECT id, LEFT(topic,60), status FROM article_topics;"
```

---

## n8n Workflow Design

### Workflow 1: Topic Input (Webhook)

**Endpoint:** `POST https://n8n.yourdomain.com/webhook/submit-topic`

```
Webhook → Validate (IF: topic not empty)
  ├─ YES → INSERT article_topics → 200 JSON response
  └─ NO  → 400 error response
```

### Workflow 2: Scheduled Publisher

**Cron:** `0 9 * * 1,3,5` — Mon/Wed/Fri at 09:00 (per `GENERIC_TIMEZONE`)

```
Schedule Trigger
  └─► SELECT topic WHERE status='pending' FOR UPDATE SKIP LOCKED
        └─► Topic found?
              ├─ NO  → Stop (no topics queued)
              └─ YES → UPDATE status='processing'
                          └─► POST to LLM API (OpenAI GPT-4o)
                                └─► Parse response (Code node)
                                      └─► Send HTML email
                                            └─► DEV_TOKEN set?
                                                  ├─ YES → POST dev.to/api/articles (draft)
                                                  │          └─► UPDATE status='done', article_url
                                                  └─ NO  → UPDATE status='done'

  On any error → UPDATE status='pending', retry_count++
                 (fails permanently after 3 retries → status='failed')
```

**Key design choices:**
- `FOR UPDATE SKIP LOCKED` prevents race conditions with multiple workers
- Error handling resets topic to `pending` for automatic retry (max 3)
- Dev.to publishes as **draft** by default (safe); change `published: false → true` to auto-publish

### Workflow 3: Error Handler

Set as the Error Workflow in Workflow 2's settings. Sends an HTML alert email with the error message, node name, and stack trace.

---

## Credentials Setup in n8n UI

After deploy, go to **Settings → Credentials → New**:

### PostgreSQL
- Type: `PostgreSQL`
- Host: `<PG_IP>` (from `kubectl get configmap n8n-svc-ips -n n8n -o jsonpath='{.data.pg-ip}'`)
- Port: `5432`, Database: `n8n`, User: `n8n`
- Password: your `POSTGRES_PASSWORD` value

### SMTP
- Type: `SMTP`
- Host: `smtp.gmail.com`, Port: `587`, SSL: STARTTLS
- User: `you@gmail.com`, Password: Gmail App Password

### LLM (OpenAI)
- Type: `HTTP Header Auth`
- Name: `Authorization`, Value: `Bearer sk-proj-...`

> For Anthropic Claude: Name: `x-api-key`, Value: `sk-ant-...`  
> Update the HTTP Request URL to `https://api.anthropic.com/v1/messages`

---

## Schedule: 3×/week Cron

```
0 9 * * 1,3,5
│ │   │
│ │   └── Day of week: 1=Mon, 3=Wed, 5=Fri
│ └────── Hour: 09:00
└──────── Minute: 00
```

Common alternatives:

| Schedule | Cron |
|----------|------|
| Mon/Wed/Fri 9am | `0 9 * * 1,3,5` |
| Tue/Thu/Sat 10am | `0 10 * * 2,4,6` |
| Daily 8am | `0 8 * * *` |
| Weekdays noon | `0 12 * * 1-5` |

Verify at: https://crontab.guru/#0_9_*_*_1,3,5

---

## Email Delivery

Config in `n8n-config` ConfigMap (non-sensitive fields):

```yaml
N8N_SMTP_HOST: "smtp.gmail.com"
N8N_SMTP_PORT: "587"
N8N_SMTP_STARTTLS: "true"
N8N_SMTP_USER: "you@gmail.com"
N8N_SMTP_SENDER: "you@gmail.com"
```

SMTP password is injected by Vault as `N8N_SMTP_PASS`.

**Gmail setup:**
1. Enable 2FA → Google Account → Security → App Passwords
2. Generate App Password for "Mail"
3. Export as `SMTP_PASSWORD` before running vault setup

| Provider | Host | Port |
|----------|------|------|
| Gmail | smtp.gmail.com | 587 |
| Outlook | smtp.office365.com | 587 |
| SendGrid | smtp.sendgrid.net | 587 |

---

## Optional Dev.to Publishing

If `DEV_TOKEN` is exported before running `01-vault-setup.sh`, the publisher workflow creates a **draft article** on Dev.to after emailing.

Get a Dev.to API key: https://dev.to/settings/extensions → Generate API key

To add/update the token later:
```bash
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/devto token="your-new-token"

# Restart n8n pods to pick up new secret
kubectl rollout restart deployment/n8n-main deployment/n8n-worker -n n8n
```

To auto-publish (skip draft): in Workflow 2, change `"published": false` → `"published": true` in the Dev.to HTTP Request node.

---

## Submitting Topics

```bash
# Submit a topic
curl -X POST https://n8n.yourdomain.com/webhook/submit-topic \
  -H "Content-Type: application/json" \
  -d '{"topic": "Write about ROSA HCP vs Classic"}'

# With optional scheduled time
curl -X POST https://n8n.yourdomain.com/webhook/submit-topic \
  -H "Content-Type: application/json" \
  -d '{
    "topic": "Terraform best practices on AKS",
    "scheduled_at": "2025-02-01T09:00:00Z"
  }'

# Check queue
kubectl exec -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-postgres \
    -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U n8n -d n8n \
  -c "SELECT id, LEFT(topic,60), status, created_at FROM article_topics ORDER BY id DESC LIMIT 10;"
```

---

## Environment Variables Reference

| Variable | Where | Description |
|----------|-------|-------------|
| `N8N_ENCRYPTION_KEY` | Vault `secret/n8n/core` | Encrypts credentials stored in PostgreSQL |
| `DB_POSTGRESDB_PASSWORD` | Vault `secret/n8n/postgres` | PostgreSQL password |
| `QUEUE_BULL_REDIS_PASSWORD` | Vault `secret/n8n/redis` | Redis AUTH password |
| `N8N_SMTP_PASS` | Vault `secret/n8n/smtp` | SMTP/Gmail App Password |
| `LLM_API_KEY` | Vault `secret/n8n/llm` | OpenAI/Anthropic API key |
| `DEV_TOKEN` | Vault `secret/n8n/devto` | Dev.to API token (optional) |
| `DB_POSTGRESDB_HOST` | n8n-config (patched) | PostgreSQL ClusterIP |
| `QUEUE_BULL_REDIS_HOST` | n8n-config (patched) | Redis ClusterIP |
| `EXECUTIONS_MODE` | n8n-config | Must be `queue` |
| `GENERIC_TIMEZONE` | n8n-config | Scheduler timezone (e.g. `Europe/Berlin`) |
| `WEBHOOK_URL` | n8n-config | Full HTTPS URL for webhooks |

---

## Operational Best Practices

```bash
# Scale workers manually
kubectl scale deployment n8n-worker -n n8n --replicas=4

# Rolling update n8n version
kubectl set image deployment/n8n-main n8n=n8nio/n8n:1.70.0 -n n8n
kubectl set image deployment/n8n-worker n8n-worker=n8nio/n8n:1.70.0 -n n8n

# Backup PostgreSQL
kubectl exec -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-postgres -o jsonpath='{.items[0].metadata.name}') \
  -- pg_dump -U n8n n8n | gzip > n8n-backup-$(date +%Y%m%d).sql.gz

# Backup n8n data (workflows, credentials)
kubectl cp n8n/$(kubectl get pod -n n8n -l app=n8n-main \
  -o jsonpath='{.items[0].metadata.name}'):/home/node/.n8n \
  ./n8n-data-$(date +%Y%m%d)

# View HPA
kubectl get hpa -n n8n
kubectl top pods -n n8n
```

---

## Security Recommendations

1. **Webhook authentication** — Edit the Topic Input webhook node: Authentication → Header Auth → add `X-Webhook-Token`
2. **Pin image versions** — Replace `n8nio/n8n:latest` with a specific tag in production
3. **Vault lease renewal** — `agent-pre-populate-only: false` (default) enables the agent sidecar for automatic secret renewal
4. **Secrets in RAM only** — All `vault-secrets` volumes use `emptyDir: { medium: Memory }`
5. **NetworkPolicy** — Applied by `k8s/ingress/ingress.yaml`; limits egress to Vault, Postgres, Redis, and external APIs
6. **Postgres access** — The `n8n` DB user is not a superuser; init script grants only necessary privileges
7. **Vault audit log** — Enable for production:
   ```bash
   kubectl exec -n vault vault-0 -- \
     env VAULT_TOKEN=$VAULT_ROOT_TOKEN \
     vault audit enable file file_path=/vault/logs/audit.log
   ```

---

## Troubleshooting

### PVCs stuck in Pending

```bash
kubectl describe pvc n8n-postgres-pvc -n n8n
# Root cause: hostPath directory might not exist or permissions wrong

# Fix: run the host-dirs Job
kubectl apply -f k8s/storage/fix-host-dirs-job.yaml
kubectl wait --for=condition=complete job/n8n-create-host-dirs -n n8n --timeout=60s
kubectl get pvc -n n8n
```

### PostgreSQL pod stuck in Init or CrashLoopBackOff

```bash
# Check Vault Agent init logs
kubectl logs -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-postgres -o jsonpath='{.items[0].metadata.name}') \
  -c vault-agent-init

# Check postgres container logs
kubectl logs -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-postgres -o jsonpath='{.items[0].metadata.name}') \
  -c postgres

# Verify Vault secret exists
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$VAULT_ROOT_TOKEN \
  vault kv get secret/n8n/postgres

# Verify Kubernetes auth role
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$VAULT_ROOT_TOKEN \
  vault read auth/kubernetes/role/n8n
```

### n8n can't reach PostgreSQL or Redis

```bash
# Show current IPs
kubectl get configmap n8n-svc-ips -n n8n -o jsonpath='{.data}' | python3 -m json.tool

# Test connectivity from n8n pod
PG_IP=$(kubectl get svc n8n-postgres-svc -n n8n -o jsonpath='{.spec.clusterIP}')
kubectl exec -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-main -o jsonpath='{.items[0].metadata.name}') \
  -c n8n -- nc -zv "$PG_IP" 5432

# If IPs changed (e.g. after Service recreation), re-run:
./scripts/deploy.sh   # Will patch n8n-config with new IPs
kubectl rollout restart deployment/n8n-main deployment/n8n-worker -n n8n
```

### Vault secrets not injected

```bash
# Check Vault Agent init container
kubectl logs -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-main -o jsonpath='{.items[0].metadata.name}') \
  -c vault-agent-init

# Verify SA is bound to Vault role
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$VAULT_ROOT_TOKEN \
  vault read auth/kubernetes/role/n8n

# Verify Vault Agent webhook is running
kubectl get mutatingwebhookconfigurations | grep vault
```

### Workers not processing jobs

```bash
# Check worker logs
kubectl logs -n n8n -l app=n8n-worker -c n8n-worker --tail=50

# Verify EXECUTIONS_MODE is queue
kubectl exec -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-worker -o jsonpath='{.items[0].metadata.name}') \
  -c n8n-worker -- sh -c 'echo $EXECUTIONS_MODE'

# Check Redis queue contents
REDIS_IP=$(kubectl get svc n8n-redis-svc -n n8n -o jsonpath='{.spec.clusterIP}')
REDIS_PASS=$(kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$VAULT_ROOT_TOKEN vault kv get -field=password secret/n8n/redis)
kubectl run redis-debug --rm -it --image=redis:7-alpine --restart=Never -- \
  redis-cli -h "$REDIS_IP" -a "$REDIS_PASS" keys "bull:*"
```

### Email not sending

```bash
# Verify SMTP vars are set in the running pod
kubectl exec -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-main -o jsonpath='{.items[0].metadata.name}') \
  -c n8n -- sh -c 'cat /vault/secrets/smtp-env'

# Test SMTP connectivity from cluster
kubectl run smtp-test --rm -it --image=busybox:1.36 --restart=Never -- \
  nc -zv smtp.gmail.com 587
```

---

## Alternative Topic Storage

| Option | Pros | Cons |
|--------|------|------|
| **PostgreSQL** ✅ (this impl) | Durable, retry logic, SQL queries | Needs DB credential in n8n |
| **Google Sheets** | Easy manual editing | Google OAuth, external SaaS |
| **n8n Static Data** | Built-in, zero setup | Not durable across pod restarts |
| **Email / IMAP** | No extra infra | Parsing complexity, polling lag |
| **Airtable** | Rich UI | External SaaS, potential cost |

To use Google Sheets: replace the `Postgres` nodes with `Google Sheets` nodes. Use columns: `topic`, `status`, `created_at`. No schema migration needed.

---

## License

MIT
