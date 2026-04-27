# n8n on Kubernetes with HashiCorp Vault — Production Deployment

> **Self-hosted n8n article automation system**: submit a topic → scheduled run 3×/week → LLM generates article → email delivered → optional Dev.to publishing.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Repository Structure](#repository-structure)
4. [Vault Configuration](#vault-configuration)
5. [Kubernetes Manifests Explained](#kubernetes-manifests-explained)
6. [Storage Setup](#storage-setup)
7. [Topic Queue: Database Schema](#topic-queue-database-schema)
8. [n8n Workflow Design](#n8n-workflow-design)
9. [Credentials Setup in n8n](#credentials-setup-in-n8n)
10. [Ingress and HTTPS](#ingress-and-https)
11. [Schedule: 3×/week Cron](#schedule-3week-cron)
12. [Email Delivery](#email-delivery)
13. [Optional Dev.to Publishing](#optional-devto-publishing)
14. [Deployment Steps](#deployment-steps)
15. [Submitting Topics](#submitting-topics)
16. [Environment Variables Reference](#environment-variables-reference)
17. [Operational Best Practices](#operational-best-practices)
18. [Security Recommendations](#security-recommendations)
19. [Troubleshooting](#troubleshooting)
20. [Alternative Topic Storage Options](#alternative-topic-storage-options)

---

## Architecture Overview

```
                          ┌─────────────────────────────────────────────┐
                          │           Kubernetes Cluster                 │
                          │                                              │
  You ──── HTTPS ────────►│  Ingress (nginx + cert-manager)             │
  (submit topic)          │       │                                      │
                          │       ▼                                      │
                          │  ┌──────────┐    ┌─────────────────────┐    │
                          │  │  n8n     │◄──►│  HashiCorp Vault     │    │
                          │  │  Main    │    │  (secrets injected   │    │
                          │  │  (UI +   │    │   via Agent sidecar) │    │
                          │  │ Webhooks)│    └─────────────────────┘    │
                          │  └────┬─────┘                               │
                          │       │ Queue (Bull/Redis)                   │
                          │       ▼                                      │
                          │  ┌──────────┐   ┌──────────┐               │
                          │  │  n8n     │   │  n8n     │  (2+ workers) │
                          │  │ Worker 1 │   │ Worker 2 │               │
                          │  └────┬─────┘   └────┬─────┘               │
                          │       │               │                      │
                          │       └───────┬───────┘                     │
                          │               ▼                              │
                          │  ┌──────────────────────────────────────┐   │
                          │  │  PostgreSQL          Redis            │   │
                          │  │  (n8n state +        (Bull queue)    │   │
                          │  │   topic queue)                        │   │
                          │  └──────────────────────────────────────┘   │
                          └─────────────────────────────────────────────┘
                                       │
                          Scheduled Workflow (Mon/Wed/Fri 9am)
                                       │
                               ┌───────▼────────┐
                               │  LLM API       │
                               │  (OpenAI GPT-4)│
                               └───────┬────────┘
                                       │
                          ┌────────────▼─────────────┐
                          │  Email (SMTP/Gmail)       │
                          │  Optional: Dev.to API     │
                          └──────────────────────────┘
```

**Components:**

| Component | Purpose | Image |
|-----------|---------|-------|
| n8n Main | Workflow engine, UI, webhooks | `n8nio/n8n:latest` |
| n8n Workers | Execute workflow jobs from queue | `n8nio/n8n:latest` |
| PostgreSQL 15 | n8n state + article topic queue | `postgres:15-alpine` |
| Redis 7 | Bull queue for worker jobs | `redis:7-alpine` |
| HashiCorp Vault | Secret management (existing install) | — |
| Nginx Ingress | HTTPS termination | — |
| cert-manager | Automatic TLS certificates | — |

---

## Prerequisites

- Kubernetes cluster with:
  - Vault already installed in `vault` namespace
  - `vault-0` pod running
  - Vault Agent Injector (webhook) deployed (standard with Vault Helm chart)
  - nginx ingress controller
  - cert-manager with a `letsencrypt-prod` ClusterIssuer
  - `metrics-server` (for HPA)
- `kubectl` configured with cluster admin access
- Environment variables set (see below)

---

## Repository Structure

```
n8n-k8s/
├── vault/
│   ├── 01-vault-setup.sh          # One-time Vault configuration script
│   └── n8n-policy.hcl             # Vault policy for n8n secrets
├── k8s/
│   ├── base/
│   │   └── namespace.yaml         # n8n namespace
│   ├── rbac/
│   │   └── rbac.yaml              # ServiceAccount, ClusterRoleBinding, Role
│   ├── storage/
│   │   └── storage.yaml           # StorageClass, PVs, PVCs
│   ├── postgres/
│   │   └── postgres.yaml          # PostgreSQL Deployment + Service + ConfigMap
│   ├── redis/
│   │   └── redis.yaml             # Redis Deployment + Service + ConfigMap
│   ├── n8n/
│   │   ├── n8n-main.yaml          # n8n main Deployment + Service + ConfigMap
│   │   └── n8n-worker.yaml        # n8n Worker Deployment + HPA
│   └── ingress/
│       └── ingress.yaml           # Ingress + NetworkPolicy
├── workflows/
│   ├── 01-topic-input-workflow.json       # Webhook to receive topics
│   ├── 02-scheduled-publisher-workflow.json  # Scheduled article generator
│   └── 03-error-handler-workflow.json     # Error alerting
├── scripts/
│   ├── deploy.sh                  # Master deploy script
│   └── create-host-dirs.sh        # Node-level directory setup
└── README.md
```

---

## Vault Configuration

### Required Environment Variables

```bash
export VAULT_ROOT_TOKEN="hvs.xxxxxxxxxxxx"
export N8N_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export POSTGRES_PASSWORD="$(openssl rand -base64 24)"
export REDIS_PASSWORD="$(openssl rand -base64 24)"
export SMTP_PASSWORD="your-gmail-app-password"
export LLM_API_KEY="sk-proj-xxxxxxxxxxxx"
export DEV_TOKEN="your-dev-token"   # Optional — omit to skip Dev.to
```

### Run Vault Setup

```bash
chmod +x vault/01-vault-setup.sh
./vault/01-vault-setup.sh
```

This script (executed via `kubectl exec` on `vault-0`):

1. Enables KV v2 secrets engine at `secret/`
2. Creates the `n8n` Vault policy
3. Writes secrets to these paths:
   - `secret/n8n/core` → `encryption_key`
   - `secret/n8n/postgres` → `password`, `host`, `port`, `database`, `user`
   - `secret/n8n/redis` → `password`, `host`, `port`
   - `secret/n8n/smtp` → `password`
   - `secret/n8n/llm` → `api_key`
   - `secret/n8n/devto` → `token` (optional)
4. Enables Kubernetes auth backend
5. Configures Kubernetes auth with cluster CA and API host
6. Creates `n8n` Vault role bound to `n8n-sa` service account

### Vault Secret Paths

```
secret/
└── n8n/
    ├── core        { encryption_key }
    ├── postgres    { password, host, port, database, user }
    ├── redis       { password, host, port }
    ├── smtp        { password }
    ├── llm         { api_key }
    └── devto       { token }
```

### How Vault Agent Injection Works

Each pod has these annotations:

```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: "n8n"
vault.hashicorp.com/agent-inject-secret-<name>: "secret/data/n8n/<path>"
vault.hashicorp.com/agent-inject-template-<name>: |
  {{- with secret "secret/data/n8n/<path>" -}}
  export SOME_VAR="{{ .Data.data.field }}"
  {{- end }}
```

The Vault Agent sidecar:
- Authenticates with Vault using the pod's Kubernetes service account token
- Renders secret templates to `/vault/secrets/<filename>`
- n8n starts with: `source /vault/secrets/n8n-*-env && exec n8n start`

Secrets live in a **memory-backed emptyDir** — never written to disk.

---

## Kubernetes Manifests Explained

### ServiceAccount & RBAC (`k8s/rbac/rbac.yaml`)

- `n8n-sa` — ServiceAccount used by all n8n pods
- `n8n-vault-token-review` — ClusterRoleBinding granting `system:auth-delegator` so Vault can verify service account tokens
- `n8n-secret-reader` — Role + RoleBinding for reading secrets in the `n8n` namespace

### Storage (`k8s/storage/storage.yaml`)

| Resource | Type | Size | Mount Path |
|----------|------|------|-----------|
| `n8n-data-pvc` | PVC | 5 Gi | `/home/node/.n8n` |
| `n8n-postgres-pvc` | PVC | 10 Gi | `/var/lib/postgresql/data` |
| `n8n-redis-pvc` | PVC | 2 Gi | `/data` |

StorageClass `standard` uses `kubernetes.io/no-provisioner` (local volumes on `/n8n`).

### n8n ConfigMap (`n8n-config`)

**Before applying, update these values in `k8s/n8n/n8n-main.yaml`:**

```yaml
N8N_HOST: "n8n.yourdomain.com"          # your actual domain
WEBHOOK_URL: "https://n8n.yourdomain.com"
GENERIC_TIMEZONE: "Europe/Berlin"        # your timezone (TZ database name)
TZ: "Europe/Berlin"
N8N_SMTP_SENDER: "your-email@gmail.com"
N8N_SMTP_USER: "your-email@gmail.com"
```

---

## Storage Setup

### Step 1: Create host directories on each node

```bash
# SSH to each Kubernetes node that may schedule n8n pods
chmod +x scripts/create-host-dirs.sh
./scripts/create-host-dirs.sh
```

This creates:
```
/n8n/
├── n8n-data/    (owner: uid 1000)
├── postgres/    (owner: uid 999)
└── redis/       (owner: uid 999)
```

### Step 2: Apply storage manifests

```bash
kubectl apply -f k8s/storage/storage.yaml
kubectl get pvc -n n8n
```

---

## Topic Queue: Database Schema

The `article_topics` table is auto-created by the PostgreSQL init script:

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
    CONSTRAINT status_check CHECK (status IN ('pending','processing','done','failed'))
);
```

**Status lifecycle:**

```
pending → processing → done
                    ↘ failed  (after 3 retries)
```

**Useful queries:**

```sql
-- View queue
SELECT id, LEFT(topic, 60) AS topic, status, created_at, retry_count
FROM article_topics
ORDER BY created_at DESC;

-- Re-queue a failed topic
UPDATE article_topics SET status = 'pending', retry_count = 0, error_msg = NULL
WHERE id = <id>;

-- View processed articles
SELECT id, topic, article_url, processed_at FROM article_topics WHERE status = 'done';
```

---

## n8n Workflow Design

### Workflow 1: Topic Input (Webhook)

**Trigger:** HTTP POST to `https://n8n.yourdomain.com/webhook/submit-topic`

```
Webhook → Validate Input → INSERT INTO article_topics → Success/Error Response
```

**Node by node:**

| Node | Type | Purpose |
|------|------|---------|
| Webhook: Receive Topic | Webhook | Accept POST with `{ topic, scheduled_at? }` |
| Validate Input | IF | Ensure `topic` is not empty |
| Insert Topic to PostgreSQL | Postgres | INSERT into `article_topics` with `status='pending'` |
| Success Response | Respond to Webhook | Return `{ success: true, id, topic }` |
| Error Response | Respond to Webhook | Return `{ success: false, error }` (HTTP 400) |

### Workflow 2: Scheduled Publisher

**Trigger:** Cron `0 9 * * 1,3,5` (Mon/Wed/Fri at 09:00)

```
Schedule Trigger
    └→ Fetch Next Pending Topic (SELECT ... FOR UPDATE SKIP LOCKED)
        └→ Topic Available? (IF)
            ├→ [YES] Mark as Processing (UPDATE status='processing')
            │    └→ Generate Article via LLM (HTTP POST to OpenAI)
            │        └→ Parse & Format Article (Code node)
            │            └→ Send Article via Email
            │                └→ Dev.to Token Available? (IF)
            │                    ├→ [YES] Publish Draft to Dev.to → Mark Done (with URL)
            │                    └→ [NO]  Mark Done (email only)
            └→ [NO]  Stop gracefully
```

**Key design decisions:**

- `FOR UPDATE SKIP LOCKED` prevents duplicate processing when multiple workers are running
- `status='processing'` is set before the LLM call to prevent race conditions
- Error handling resets to `pending` with `retry_count++` (max 3 retries)
- Dev.to publishing checks for `DEV_TOKEN` env var — gracefully skips if not set

### Workflow 3: Error Handler

Set as the **Error Workflow** for Workflow 2. Sends an HTML email alert with the error message, stack trace, and execution ID.

---

## Credentials Setup in n8n

After deployment, create these credentials in the n8n UI (`Settings → Credentials`):

### PostgreSQL Credential
- **Type:** PostgreSQL
- **Name:** `n8n PostgreSQL`
- Host: `n8n-postgres-svc.n8n.svc.cluster.local`
- Port: `5432`
- Database: `n8n`
- User: `n8n`
- Password: *(from Vault — set manually or use env-sourced value)*

### SMTP Credential
- **Type:** SMTP
- **Name:** `n8n SMTP`
- Host: `smtp.gmail.com`
- Port: `587`
- User: `your-email@gmail.com`
- Password: *(Gmail App Password from Vault)*

### LLM Credential (OpenAI)
- **Type:** HTTP Header Auth
- **Name:** `OpenAI LLM`
- Header Name: `Authorization`
- Header Value: `Bearer sk-proj-xxxxxxxx`

> For Claude/Anthropic, create a second HTTP Header Auth credential with `x-api-key: sk-ant-...`

---

## Ingress and HTTPS

The Ingress uses cert-manager with Let's Encrypt. Before applying:

1. Update `n8n.yourdomain.com` in `k8s/ingress/ingress.yaml`
2. Ensure your `ClusterIssuer` name matches (`letsencrypt-prod`)
3. Create DNS A/CNAME record pointing to your ingress controller's external IP

```bash
kubectl get svc -n ingress-nginx   # find EXTERNAL-IP
```

---

## Schedule: 3×/week Cron

The Schedule Trigger node uses:

```
0 9 * * 1,3,5
```

**Breakdown:**
- `0` — at minute 0
- `9` — at hour 9 (09:00)
- `*` — every day of month
- `*` — every month
- `1,3,5` — Monday (1), Wednesday (3), Friday (5)

**Respects `GENERIC_TIMEZONE`** set in the ConfigMap.

To change frequency:

| Schedule | Cron Expression |
|---------|----------------|
| Mon/Wed/Fri 9am | `0 9 * * 1,3,5` |
| Tue/Thu/Sat 10am | `0 10 * * 2,4,6` |
| Daily 8am | `0 8 * * *` |
| Weekdays 9am | `0 9 * * 1-5` |

---

## Email Delivery

n8n uses its built-in SMTP integration. Configuration is in the `n8n-config` ConfigMap:

```yaml
N8N_EMAIL_MODE: "smtp"
N8N_SMTP_HOST: "smtp.gmail.com"
N8N_SMTP_PORT: "587"
N8N_SMTP_STARTTLS: "true"
N8N_SMTP_USER: "your-email@gmail.com"
```

**Gmail setup:**
1. Enable 2FA on your Google account
2. Go to: Google Account → Security → App Passwords
3. Create an App Password for "Mail"
4. Use the 16-character app password as `SMTP_PASSWORD`

**For other providers:**

| Provider | Host | Port |
|----------|------|------|
| Gmail | smtp.gmail.com | 587 |
| Outlook | smtp.office365.com | 587 |
| SendGrid | smtp.sendgrid.net | 587 |
| Mailgun | smtp.mailgun.org | 587 |

---

## Optional Dev.to Publishing

If `DEV_TOKEN` is set in Vault at `secret/n8n/devto`, the workflow automatically creates a **draft article** on Dev.to after email delivery.

**To get a Dev.to API token:**
1. Go to https://dev.to/settings/extensions
2. Generate a new API key
3. Add it to your env: `export DEV_TOKEN="your-token-here"`
4. Re-run `vault/01-vault-setup.sh` or manually:
   ```bash
   kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_ROOT_TOKEN \
     vault kv put secret/n8n/devto token="your-token"
   ```

**To auto-publish (not draft):** In Workflow 2, change `"published": false` to `"published": true` in the Dev.to HTTP Request node.

---

## Deployment Steps

```bash
# 1. Clone / prepare the repo
cd n8n-k8s

# 2. Set required environment variables
export VAULT_ROOT_TOKEN="hvs.xxxxxxxxxxxx"
export N8N_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export POSTGRES_PASSWORD="$(openssl rand -base64 24)"
export REDIS_PASSWORD="$(openssl rand -base64 24)"
export SMTP_PASSWORD="your-gmail-app-password"
export LLM_API_KEY="sk-proj-xxxxxxxxxxxx"
export DEV_TOKEN="your-dev-token"      # Optional

# 3. Update domain/email in manifests
sed -i 's/n8n.yourdomain.com/n8n.mycompany.com/g' \
  k8s/n8n/n8n-main.yaml \
  k8s/ingress/ingress.yaml \
  workflows/02-scheduled-publisher-workflow.json \
  workflows/03-error-handler-workflow.json

sed -i 's/your-email@gmail.com/me@mycompany.com/g' \
  k8s/n8n/n8n-main.yaml \
  workflows/02-scheduled-publisher-workflow.json \
  workflows/03-error-handler-workflow.json

# 4. Configure Vault
chmod +x vault/01-vault-setup.sh
./vault/01-vault-setup.sh

# 5. Create host directories (on each node)
# SSH into node and run: ./scripts/create-host-dirs.sh

# 6. Deploy
chmod +x scripts/deploy.sh
./scripts/deploy.sh

# 7. Import workflows in n8n UI
#    Settings → Workflows → Import from File
#    Import: workflows/01-topic-input-workflow.json
#    Import: workflows/02-scheduled-publisher-workflow.json
#    Import: workflows/03-error-handler-workflow.json

# 8. Configure credentials in n8n UI (see Credentials section)

# 9. Activate workflows (toggle in n8n UI)
```

---

## Submitting Topics

Via curl:

```bash
# Submit a topic for the next scheduled run
curl -X POST https://n8n.yourdomain.com/webhook/submit-topic \
  -H "Content-Type: application/json" \
  -d '{"topic": "Write about ROSA HCP vs Classic: comparing managed OpenShift options"}'

# Submit with a specific scheduled time
curl -X POST https://n8n.yourdomain.com/webhook/submit-topic \
  -H "Content-Type: application/json" \
  -d '{
    "topic": "Terraform best practices on AKS",
    "scheduled_at": "2025-01-20T09:00:00Z"
  }'

# View queue status (direct DB query via kubectl)
kubectl exec -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-postgres -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U n8n -d n8n \
  -c "SELECT id, LEFT(topic,60), status, created_at FROM article_topics ORDER BY created_at DESC;"
```

**Topic examples:**
- `"Write about ROSA HCP vs Classic"`
- `"Terraform best practices on AKS"`
- `"How to deploy n8n on Kubernetes with Vault integration"`
- `"Kubernetes RBAC: a practical guide for platform engineers"`
- `"GitOps with ArgoCD and Helm on multi-cluster setups"`

---

## Environment Variables Reference

| Variable | Source | Description |
|----------|--------|-------------|
| `N8N_ENCRYPTION_KEY` | Vault `secret/n8n/core` | Encrypts n8n credentials at rest |
| `DB_POSTGRESDB_PASSWORD` | Vault `secret/n8n/postgres` | PostgreSQL password |
| `QUEUE_BULL_REDIS_PASSWORD` | Vault `secret/n8n/redis` | Redis auth password |
| `N8N_SMTP_PASS` | Vault `secret/n8n/smtp` | SMTP/Gmail app password |
| `LLM_API_KEY` | Vault `secret/n8n/llm` | OpenAI/Anthropic API key |
| `DEV_TOKEN` | Vault `secret/n8n/devto` | Dev.to API token (optional) |
| `N8N_HOST` | ConfigMap | n8n hostname |
| `WEBHOOK_URL` | ConfigMap | Full URL for webhooks |
| `GENERIC_TIMEZONE` | ConfigMap | Timezone (e.g., `Europe/Berlin`) |
| `EXECUTIONS_MODE` | ConfigMap | Must be `queue` |
| `QUEUE_BULL_REDIS_HOST` | ConfigMap | Redis service hostname |
| `DB_TYPE` | ConfigMap | Must be `postgresdb` |

---

## Operational Best Practices

### Scaling

```bash
# Scale workers up during heavy load
kubectl scale deployment n8n-worker -n n8n --replicas=4

# The HPA will auto-scale between 2-5 workers based on CPU/memory
kubectl get hpa -n n8n
```

### Backups

```bash
# Backup PostgreSQL data
kubectl exec -n n8n \
  $(kubectl get pod -n n8n -l app=n8n-postgres -o jsonpath='{.items[0].metadata.name}') \
  -- pg_dump -U n8n n8n | gzip > n8n-db-$(date +%Y%m%d).sql.gz

# Backup n8n data volume (workflows, credentials)
kubectl cp n8n/$(kubectl get pod -n n8n -l app=n8n-main \
  -o jsonpath='{.items[0].metadata.name}'):/home/node/.n8n ./n8n-data-backup-$(date +%Y%m%d)
```

### Rolling Updates

```bash
# Update n8n to latest
kubectl set image deployment/n8n-main n8n=n8nio/n8n:latest -n n8n
kubectl set image deployment/n8n-worker n8n-worker=n8nio/n8n:latest -n n8n
kubectl rollout status deployment/n8n-main -n n8n
```

### Monitoring

```bash
# Pod status
kubectl get pods -n n8n -w

# n8n main logs
kubectl logs -n n8n -l app=n8n-main --tail=100 -f

# Worker logs
kubectl logs -n n8n -l app=n8n-worker --tail=100 -f

# PostgreSQL logs
kubectl logs -n n8n -l app=n8n-postgres --tail=50

# Resource usage
kubectl top pods -n n8n
```

---

## Security Recommendations

1. **Vault token rotation:** Vault leases auto-renew (TTL: 1h, max: 24h). For long-running pods, configure Vault Agent for lease renewal.

2. **Network isolation:** The NetworkPolicy restricts:
   - n8n to only reach Postgres, Redis, Vault, and internet (for APIs)
   - No direct pod-to-pod access outside n8n namespace

3. **Webhook security:** Add webhook authentication to the topic input webhook:
   - In n8n UI, edit Webhook node → Authentication → Header Auth
   - Add `X-Webhook-Secret: <token>` to your curl calls

4. **RBAC least privilege:** The `n8n-sa` service account has only the minimum permissions needed for Vault authentication.

5. **Image pinning:** Replace `n8nio/n8n:latest` with a specific version in production:
   ```yaml
   image: n8nio/n8n:1.68.0
   ```

6. **Secrets in memory only:** All Vault-injected secrets use `emptyDir: { medium: Memory }` — they are never persisted to disk on the node.

7. **PostgreSQL hardening:** The init script creates a dedicated `n8n` user (not superuser). Consider enabling SSL for PostgreSQL connections.

8. **Audit logging:** Enable Vault audit logging:
   ```bash
   kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_ROOT_TOKEN \
     vault audit enable file file_path=/vault/logs/audit.log
   ```

---

## Troubleshooting

### Vault Agent not injecting secrets

```bash
# Check Vault Agent is running as sidecar
kubectl describe pod -n n8n -l app=n8n-main

# Check Vault Agent logs
kubectl logs -n n8n -l app=n8n-main -c vault-agent

# Verify Kubernetes auth is configured
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_ROOT_TOKEN \
  vault auth list

# Test Kubernetes auth from within a pod
kubectl exec -it -n n8n $(kubectl get pod -n n8n -l app=n8n-main \
  -o jsonpath='{.items[0].metadata.name}') -c n8n -- \
  sh -c 'ls /vault/secrets/'
```

### PVCs stuck in Pending

```bash
kubectl describe pvc n8n-postgres-pvc -n n8n
# Common causes:
# - Host directory /n8n/postgres doesn't exist → run create-host-dirs.sh
# - Node selector doesn't match any node
# - StorageClass not found
```

### n8n can't connect to PostgreSQL

```bash
# Test from n8n pod
kubectl exec -it -n n8n $(kubectl get pod -n n8n -l app=n8n-main \
  -o jsonpath='{.items[0].metadata.name}') -c n8n -- \
  nc -zv n8n-postgres-svc 5432

# Check postgres pod is running
kubectl get pods -n n8n -l app=n8n-postgres

# Check postgres logs
kubectl logs -n n8n -l app=n8n-postgres -c postgres
```

### n8n can't connect to Redis

```bash
kubectl exec -it -n n8n $(kubectl get pod -n n8n -l app=n8n-worker \
  -o jsonpath='{.items[0].metadata.name}') -c n8n-worker -- \
  nc -zv n8n-redis-svc 6379
```

### Workflow not triggering on schedule

```bash
# Check n8n timezone
kubectl exec -n n8n $(kubectl get pod -n n8n -l app=n8n-main \
  -o jsonpath='{.items[0].metadata.name}') -c n8n -- \
  sh -c 'echo $GENERIC_TIMEZONE && date'

# Ensure workflow is ACTIVE in n8n UI
# Verify cron expression at: https://crontab.guru/#0_9_*_*_1,3,5
```

### Email not being sent

```bash
# Test SMTP from within the cluster
kubectl exec -it -n n8n $(kubectl get pod -n n8n -l app=n8n-main \
  -o jsonpath='{.items[0].metadata.name}') -c n8n -- \
  nc -zv smtp.gmail.com 587

# Check SMTP env vars are populated
kubectl exec -n n8n $(kubectl get pod -n n8n -l app=n8n-main \
  -o jsonpath='{.items[0].metadata.name}') -c n8n -- \
  sh -c 'cat /vault/secrets/n8n-smtp-env'
```

### Workers not picking up jobs

```bash
# Verify worker mode
kubectl exec -n n8n $(kubectl get pod -n n8n -l app=n8n-worker \
  -o jsonpath='{.items[0].metadata.name}') -c n8n-worker -- \
  sh -c 'echo $EXECUTIONS_MODE'

# Check Redis queue
kubectl exec -it -n n8n $(kubectl get pod -n n8n -l app=n8n-redis \
  -o jsonpath='{.items[0].metadata.name}') -c redis -- \
  sh -c 'PASS=$(cat /vault/secrets/redis-password); redis-cli -a $PASS keys "bull:*" | head -20'
```

---

## Alternative Topic Storage Options

While PostgreSQL is recommended for production, here are alternatives:

| Option | Pros | Cons |
|--------|------|------|
| **PostgreSQL** (this impl) | Durable, SQL queries, retry logic | Requires DB credential in n8n |
| **Google Sheets** | Easy to edit manually | Requires Google OAuth, external dependency |
| **n8n Variables** | Built-in, no setup | Limited to simple key/value, not persistent across restarts |
| **Email (IMAP)** | No extra infra | Polling latency, format parsing complexity |
| **Airtable** | Nice UI | External SaaS, potential cost |
| **Notion DB** | Rich metadata | External SaaS, OAuth required |

To switch to Google Sheets: replace the PostgreSQL nodes with n8n's built-in Google Sheets nodes, using a sheet with columns: `topic`, `status`, `created_at`.

---

## License

MIT