# n8n on Kubernetes with HashiCorp Vault — Production-Grade Article Automation

> Self-hosted n8n in Kubernetes with Vault-managed secrets, PostgreSQL, Redis queue mode, automated article generation, and email delivery.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Repository Structure](#repository-structure)
4. [Vault Configuration](#vault-configuration)
5. [Kubernetes Manifests](#kubernetes-manifests)
6. [Storage Configuration](#storage-configuration)
7. [n8n Workflow Design](#n8n-workflow-design)
8. [Cron Schedule](#cron-schedule)
9. [Email Configuration](#email-configuration)
10. [Medium Publishing](#medium-publishing)
11. [Deployment Guide](#deployment-guide)
12. [Topic Queue Schema](#topic-queue-schema)
13. [Operational Best Practices](#operational-best-practices)
14. [Security Recommendations](#security-recommendations)
15. [Troubleshooting](#troubleshooting)
16. [Alternatives to PostgreSQL Topic Queue](#alternatives)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                                │
│                                                                           │
│  ┌─────────────┐     ┌──────────────────────────────────────────────┐   │
│  │   HashiCorp  │     │              Namespace: n8n                   │   │
│  │    Vault     │◄────┤                                              │   │
│  │  (ns: vault) │     │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │   │
│  └─────────────┘     │  │ n8n-main │  │  Worker  │  │  Worker  │  │   │
│        ▲             │  │(1 replica)│  │  Pod x1  │  │  Pod x2  │  │   │
│        │ KV secrets  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  │   │
│  Vault Agent         │       │              │              │         │   │
│  Sidecar (injected)  │       └──────────────┴──────────────┘         │   │
│                      │                    │                           │   │
│                      │              ┌─────▼──────┐                   │   │
│                      │              │   Redis    │ ← Bull Queue       │   │
│                      │              │  (Queue)   │                   │   │
│                      │              └─────┬──────┘                   │   │
│                      │                    │                           │   │
│                      │              ┌─────▼──────┐                   │   │
│                      │              │ PostgreSQL  │ ← n8n DB +        │   │
│                      │              │            │   article_topics   │   │
│                      │              └────────────┘                   │   │
│                      └──────────────────────────────────────────────┘   │
│                                                                           │
│  ┌─────────────┐     ┌──────────────┐                                   │
│  │   Ingress   │────►│  n8n Service │   HTTPS via cert-manager           │
│  │  (NGINX)    │     │  ClusterIP   │                                   │
│  └─────────────┘     └──────────────┘                                   │
│                                                                           │
│  Storage (local volumes at /n8n):                                        │
│  ├── n8n-data-pvc     → /n8n/data                                        │
│  ├── n8n-postgres-pvc → /n8n/postgres                                    │
│  └── n8n-redis-pvc    → /n8n/redis                                       │
└──────────────────────────────────────────────────────────────────────────┘

Automation Flow:
  You → POST /webhook/submit-topic → PostgreSQL (article_topics)
                                          │
                    ┌─────────────────────┘
                    │  Mon/Wed/Fri 08:00 UTC
                    ▼
          Fetch pending topic
                    │
                    ▼
          Generate article (GPT-4o)
                    │
                    ▼
          Send to email ──────────────────────────► Your Inbox
                    │
                    ▼ (if MEDIUM_TOKEN set)
          Post draft to Medium
                    │
                    ▼
          Mark topic as 'done'
```

**Components:**

| Component | Role | Replicas |
|-----------|------|----------|
| n8n main | UI, scheduler, webhook receiver | 1 |
| n8n worker | Execution engine (queue consumer) | 2 (HPA: 2–10) |
| PostgreSQL 16 | n8n metadata + article topic queue | 1 |
| Redis 7 | Bull queue for job distribution | 1 |
| Vault Agent | Secret injection sidecar | per pod |

---

## Prerequisites

- Kubernetes cluster (v1.25+)
- `kubectl` configured
- HashiCorp Vault installed in namespace `vault` (pod: `vault-0`)
- Vault Agent Injector webhook installed (`vault-agent-injector`)
- NGINX Ingress Controller
- cert-manager (for TLS) — *or* pre-existing wildcard certificate
- Node with `/n8n` directory writable (for local PVs)
- OpenAI API key (or Anthropic/other LLM)
- Gmail account with App Password (or other SMTP)

**Verify Vault Agent Injector is installed:**
```bash
kubectl get pods -n vault
# Should show: vault-agent-injector-xxx   Running
```

---

## Repository Structure

```
n8n-k8s/
├── vault/
│   ├── 01-vault-setup.sh          # One-time Vault config script
│   └── n8n-vault-policy.hcl       # Vault policy (read-only for n8n paths)
├── k8s/
│   ├── namespace/
│   │   └── namespace.yaml         # Namespace: n8n
│   ├── storage/
│   │   └── storage.yaml           # StorageClass + PVs + PVCs
│   ├── rbac/
│   │   └── rbac.yaml              # ServiceAccount n8n-sa + RBAC
│   ├── postgres/
│   │   └── postgres.yaml          # PostgreSQL deployment + init SQL
│   ├── redis/
│   │   └── redis.yaml             # Redis deployment
│   ├── n8n/
│   │   ├── configmap.yaml         # Non-sensitive n8n config
│   │   ├── n8n-main.yaml          # n8n main instance
│   │   └── n8n-worker.yaml        # n8n workers + HPA
│   ├── ingress/
│   │   └── ingress.yaml           # Ingress + TLS + cert-manager
│   └── vault-agent/
│       └── vault-agent-configmap.yaml  # Reference Vault Agent config
├── workflows/
│   ├── 01-topic-input-workflow.json        # Webhook to accept topics
│   ├── 02-scheduled-publishing-workflow.json  # Main automation
│   └── 03-error-handler-workflow.json      # Error notifications
├── scripts/
│   ├── deploy.sh                  # Full deployment script
│   └── troubleshoot.sh            # Diagnostic script
└── README.md
```

---

## Vault Configuration

### Secret Paths

| Path | Keys | Description |
|------|------|-------------|
| `secret/n8n/core` | `encryption_key` | n8n data encryption key (32+ chars) |
| `secret/n8n/postgres` | `password`, `user`, `db`, `host`, `port` | PostgreSQL credentials |
| `secret/n8n/redis` | `password`, `host`, `port` | Redis credentials |
| `secret/n8n/smtp` | `password` | Gmail App Password or SMTP password |
| `secret/n8n/llm` | `api_key` | OpenAI/Anthropic/LLM API key |
| `secret/n8n/medium` | `token` | Medium integration token (optional) |

### Step 1: Run Vault Setup Script

export VAULT_ROOT_TOKEN="hvs.xxxxxxxxxxxx"
export N8N_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export POSTGRES_PASSWORD="$(openssl rand -base64 24)"
export REDIS_PASSWORD="$(openssl rand -base64 24)"
export SMTP_PASSWORD="your-gmail-app-password"
export LLM_API_KEY="sk-proj-xxxxxxxxxxxx"
export MEDIUM_TOKEN="your-medium-token"   # omit entirely to skip

```bash
chmod +x vault/01-vault-setup.sh
./vault/01-vault-setup.sh
```

This script:
1. Collects your Kubernetes API host and CA certificate
2. Gets the Vault SA JWT from the `vault-0` pod
3. Prompts for all secret values (input is hidden)
4. Enables KV-v2 at `secret/`
5. Writes all secrets to Vault
6. Creates the `n8n-policy` Vault policy
7. Enables and configures Kubernetes auth method
8. Creates the `n8n` Kubernetes auth role

### Step 2: Verify Secrets Were Written

```bash
# All commands use kubectl exec on vault-0 (as required)

# List secrets
kubectl exec -n vault vault-0 -- vault kv list secret/n8n/

# Read a specific secret (redacted)
kubectl exec -n vault vault-0 -- vault kv get secret/n8n/postgres

# Verify the policy
kubectl exec -n vault vault-0 -- vault policy read n8n-policy

# Verify Kubernetes auth role
kubectl exec -n vault vault-0 -- vault read auth/kubernetes/role/n8n
```

### Vault Policy Details

```hcl
# Grants READ access to all n8n secret paths
path "secret/data/n8n/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/n8n/*" {
  capabilities = ["list"]
}
```

### How Vault Agent Injection Works

Every n8n pod has these Kubernetes annotations:

```yaml
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "n8n"
  vault.hashicorp.com/agent-inject-secret-postgres: "secret/data/n8n/postgres"
  vault.hashicorp.com/agent-inject-template-postgres: |
    {{- with secret "secret/data/n8n/postgres" -}}
    export DB_POSTGRESDB_PASSWORD="{{ .Data.data.password }}"
    {{- end }}
```

The Vault Agent Injector mutating webhook:
1. Intercepts the pod creation
2. Injects a `vault-agent` init container that authenticates to Vault using the pod's SA token
3. Renders the Consul Template (`.ctmpl`) into `/vault/secrets/<name>`
4. The n8n container sources these files at startup: `. /vault/secrets/postgres`

Secrets are stored in an `emptyDir` volume with `medium: Memory` (RAM only — not written to disk).

---

## Kubernetes Manifests

### Applying Manifests

```bash
# In order:
kubectl apply -f k8s/namespace/namespace.yaml
kubectl apply -f k8s/rbac/rbac.yaml
kubectl apply -f k8s/storage/storage.yaml    # Edit YOUR_NODE_NAME first!
kubectl apply -f k8s/postgres/postgres.yaml
kubectl apply -f k8s/redis/redis.yaml
kubectl apply -f k8s/n8n/configmap.yaml      # Edit YOUR_DOMAIN.com first!
kubectl apply -f k8s/n8n/n8n-main.yaml
kubectl apply -f k8s/n8n/n8n-worker.yaml
kubectl apply -f k8s/ingress/ingress.yaml    # Edit YOUR_DOMAIN.com first!
```

Or use the deploy script:
```bash
./scripts/deploy.sh my-node-name
```

### Required Substitutions Before Applying

In `k8s/storage/storage.yaml`:
```yaml
- YOUR_NODE_NAME   # ← your actual Kubernetes node hostname
```

In `k8s/n8n/configmap.yaml`:
```yaml
N8N_HOST: "n8n.YOUR_DOMAIN.com"
WEBHOOK_URL: "https://n8n.YOUR_DOMAIN.com/"
N8N_SMTP_USER: "your-email@gmail.com"
GENERIC_TIMEZONE: "Europe/Berlin"   # ← your timezone (e.g., America/New_York)
```

In `k8s/ingress/ingress.yaml`:
```yaml
email: your-email@example.com
host: n8n.YOUR_DOMAIN.com
```

---

## Storage Configuration

All PVCs use the `standard` StorageClass backed by local volumes on `/n8n`:

| PVC Name | Mount Path on Node | Size | Used By |
|---|---|---|---|
| `n8n-data-pvc` | `/n8n/data` | 5Gi | n8n main (workflows, credentials) |
| `n8n-postgres-pvc` | `/n8n/postgres` | 10Gi | PostgreSQL data |
| `n8n-redis-pvc` | `/n8n/redis` | 2Gi | Redis AOF persistence |

**Create host directories on your node before applying:**
```bash
# Run on the target Kubernetes node
sudo mkdir -p /n8n/data /n8n/postgres /n8n/redis
sudo chown -R 1000:1000 /n8n/data    # n8n user
sudo chown -R 999:999 /n8n/postgres  # postgres user
sudo chown -R 1000:1000 /n8n/redis   # redis user
```

---

## n8n Workflow Design

### Workflow 1: Topic Input (Webhook)

**Purpose:** Accept article topics via HTTP POST and store them in PostgreSQL.

```
[Webhook Trigger]
    POST /webhook/submit-topic
    Body: { "topic": "Write about ROSA HCP vs Classic" }
         │
         ▼
[IF Node] ── topic provided? ──YES──► [PostgreSQL INSERT]
                             │                │
                             NO               ▼
                             │        [Respond 200 + topic ID]
                             ▼
                    [Respond 400 + error]
```

**Node-by-node:**

| # | Node | Type | Purpose |
|---|------|------|---------|
| 1 | Webhook - Receive Topic | Webhook | POST endpoint at `/webhook/submit-topic` |
| 2 | IF - Topic Provided? | If | Validate `body.topic` is not empty |
| 3 | PostgreSQL - Insert Topic | Postgres | `INSERT INTO article_topics (topic)` |
| 4 | Respond - Success | Respond to Webhook | Return `{success: true, id, topic}` |
| 5 | Respond - Error | Respond to Webhook | Return 400 with error message |

**Example usage:**
```bash
curl -X POST https://n8n.YOUR_DOMAIN.com/webhook/submit-topic \
  -H 'Content-Type: application/json' \
  -d '{"topic": "How to deploy n8n on Kubernetes with Vault integration"}'

# Response:
# {"success": true, "id": 1, "topic": "How to deploy...", "created_at": "..."}
```

---

### Workflow 2: Scheduled Publishing (Main Automation)

**Purpose:** Every Mon/Wed/Fri at 08:00, fetch the oldest pending topic, generate an article, email it, and optionally post to Medium.

```
[Schedule Trigger] Mon/Wed/Fri 08:00
         │
         ▼
[PostgreSQL] SELECT oldest pending topic (retry_count < 3)
         │
         ▼
[IF] Topic exists?
    YES ──► [PostgreSQL] UPDATE status='processing'
                 │
                 ▼
           [OpenAI] Generate article (GPT-4o, ~2000 words)
                 │
                 ▼
           [Code Node] Extract title, tags, word count
                 │
                 ▼
           [Email] Send HTML email with full article
                 │
                 ▼
           [IF] MEDIUM_TOKEN env set?
              YES ──► [HTTP] GET medium.com/v1/users/me
                          │
                          ▼
                     [HTTP] POST create draft on Medium
                          │
                          ▼
              NO ─────► [PostgreSQL] UPDATE status='done'
    NO  ──► (silently end — no topics pending)
```

**Node-by-node:**

| # | Node | Type | Purpose |
|---|------|------|---------|
| 1 | Schedule - 3x Per Week | Schedule Trigger | Cron `0 8 * * 1,3,5` |
| 2 | PostgreSQL - Fetch Next Topic | Postgres | SELECT oldest pending topic |
| 3 | IF - Topic Exists? | If | Guard if queue is empty |
| 4 | PostgreSQL - Mark Processing | Postgres | UPDATE status='processing' |
| 5 | OpenAI - Generate Article | OpenAI | GPT-4o with detailed system prompt |
| 6 | Code - Format Article | Code | Parse title, tags, word count |
| 7 | Email - Send Article | Email (SMTP) | Styled HTML email |
| 8 | IF - Medium Token Set? | If | Check `MEDIUM_TOKEN` env var |
| 9 | Medium - Get User ID | HTTP Request | GET `/v1/users/me` |
| 10 | Medium - Create Draft | HTTP Request | POST create draft |
| 11 | PostgreSQL - Mark Done | Postgres | UPDATE status='done' |

---

### Workflow 3: Error Handler

Configured as the `errorWorkflow` for Workflow 2. Triggered on any uncaught exception.

```
[Error Trigger]
     │
     ▼
[PostgreSQL] Revert any stuck 'processing' topics to 'error'
     │
     ▼
[Email] Send error alert with: workflow name, node, error message, execution link
```

---

## Cron Schedule

The scheduler runs **Monday, Wednesday, Friday at 08:00** (timezone from `GENERIC_TIMEZONE`):

```
0 8 * * 1,3,5
│ │ │ │  └─── Days of week: 1=Mon, 3=Wed, 5=Fri
│ │ │ └────── Month: * (every month)
│ │ └──────── Day of month: * (any)
│ └────────── Hour: 8 (08:00)
└──────────── Minute: 0
```

**To change the schedule**, edit the `Schedule - 3x Per Week` node in Workflow 02:

| Use Case | Cron Expression |
|---|---|
| Mon/Wed/Fri 08:00 (default) | `0 8 * * 1,3,5` |
| Tue/Thu/Sat 09:00 | `0 9 * * 2,4,6` |
| Weekdays 06:00 | `0 6 * * 1-5` |
| Every day 07:30 | `30 7 * * *` |
| Mon/Wed 10:00 | `0 10 * * 1,3` |

---

## Email Configuration

**Gmail App Password setup** (recommended):

1. Go to [myaccount.google.com](https://myaccount.google.com)
2. Security → 2-Step Verification → App passwords
3. Create a new app password for "Mail"
4. Store it in Vault: run `vault/01-vault-setup.sh` and enter it when prompted

**ConfigMap settings** (edit `k8s/n8n/configmap.yaml`):

```yaml
N8N_EMAIL_MODE: "smtp"
N8N_SMTP_HOST: "smtp.gmail.com"
N8N_SMTP_PORT: "587"
N8N_SMTP_USER: "your-email@gmail.com"
N8N_SMTP_SENDER: "n8n Automation <your-email@gmail.com>"
N8N_SMTP_SSL: "false"
N8N_SMTP_STARTTLS: "true"
# N8N_SMTP_PASS → injected from Vault secret/n8n/smtp
```

**Other SMTP providers:**

| Provider | Host | Port | TLS |
|---|---|---|---|
| Gmail | smtp.gmail.com | 587 | STARTTLS |
| SendGrid | smtp.sendgrid.net | 587 | STARTTLS |
| Mailgun | smtp.mailgun.org | 587 | STARTTLS |
| AWS SES | email-smtp.us-east-1.amazonaws.com | 587 | STARTTLS |
| Outlook | smtp.office365.com | 587 | STARTTLS |

---

## Medium Publishing

Medium publishing is **optional** and gated by the `MEDIUM_TOKEN` environment variable.

### Enabling Medium Integration

1. Get your Medium Integration Token:
   - Go to [medium.com/me/settings](https://medium.com/me/settings)
   - Integration tokens → Get integration token

2. Store in Vault:
```bash
kubectl exec -n vault vault-0 -- \
  vault kv patch secret/n8n/medium token="YOUR_MEDIUM_TOKEN"
```

3. The workflow automatically checks the token at runtime:
   - If set and not `DISABLED` → creates a **draft** on Medium
   - If not set → email only

### Medium API Notes

- Articles are created as **drafts** (`publishStatus: draft`) — you review before publishing
- Change to `"public"` in the HTTP Request node to auto-publish
- The Medium API supports `markdown` content format (used here)
- Rate limits: 10 posts per hour per user

---

## Deployment Guide

### Quick Start

```bash
# 1. Clone / copy this repository
cd n8n-k8s

# 2. Edit configurations
# ── Replace YOUR_NODE_NAME in k8s/storage/storage.yaml
# ── Replace YOUR_DOMAIN.com in k8s/n8n/configmap.yaml and k8s/ingress/ingress.yaml
# ── Replace your-email@gmail.com in k8s/n8n/configmap.yaml

# 3. Configure Vault
chmod +x vault/01-vault-setup.sh
./vault/01-vault-setup.sh

# 4. Create host directories on your node
ssh <node> "sudo mkdir -p /n8n/{data,postgres,redis} && sudo chmod -R 777 /n8n"

# 5. Deploy
chmod +x scripts/deploy.sh
./scripts/deploy.sh <your-node-name>
```

### Post-Deployment: Configure n8n Credentials

In the n8n UI (`https://n8n.YOUR_DOMAIN.com`):

1. **PostgreSQL credential** (name: `n8n PostgreSQL`):
   - Host: `postgres-service.n8n.svc.cluster.local`
   - Database: `n8n`
   - User: `n8n`
   - Password: *(from Vault secret/n8n/postgres)*

2. **OpenAI credential** (name: `OpenAI API`):
   - API Key: *(from Vault secret/n8n/llm)*

3. **SMTP credential** (name: `SMTP Gmail`):
   - Host: `smtp.gmail.com`, Port: `587`
   - User: `your-email@gmail.com`
   - Password: *(from Vault secret/n8n/smtp)*

### Import Workflows

```
n8n UI → Workflows → Import from file
```
Import in order:
1. `workflows/03-error-handler-workflow.json`
2. `workflows/01-topic-input-workflow.json`
3. `workflows/02-scheduled-publishing-workflow.json`

Activate all three workflows (toggle the switch to ON).

### Submit Your First Topic

```bash
curl -X POST https://n8n.YOUR_DOMAIN.com/webhook/submit-topic \
  -H 'Content-Type: application/json' \
  -d '{"topic": "How to deploy n8n on Kubernetes with Vault integration"}'
```

---

## Topic Queue Schema

```sql
CREATE TABLE article_topics (
    id            SERIAL PRIMARY KEY,
    topic         TEXT        NOT NULL,
    status        VARCHAR(20) NOT NULL DEFAULT 'pending',
    -- 'pending'    → waiting to be processed
    -- 'processing' → currently being generated
    -- 'done'       → article generated and emailed
    -- 'error'      → failed (see error_message)
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    scheduled_at  TIMESTAMPTZ,          -- when processing started
    processed_at  TIMESTAMPTZ,          -- when completed/failed
    article_title TEXT,                 -- extracted article title
    article_url   TEXT,                 -- Medium URL if published
    error_message TEXT,                 -- error details if status=error
    retry_count   INTEGER NOT NULL DEFAULT 0  -- max 3 retries
);
```

**Useful queries:**

```sql
-- See queue status
SELECT status, count(*) FROM article_topics GROUP BY status;

-- See pending topics in order
SELECT id, topic, created_at FROM article_topics WHERE status='pending' ORDER BY created_at;

-- Reset a failed topic for retry
UPDATE article_topics SET status='pending', retry_count=0, error_message=NULL WHERE id=<id>;

-- View recent completions
SELECT id, topic, article_title, processed_at FROM article_topics
WHERE status='done' ORDER BY processed_at DESC LIMIT 10;
```

**Connect to PostgreSQL:**
```bash
kubectl exec -n n8n deploy/postgres -- psql -U n8n -d n8n
```

---

## Alternatives to PostgreSQL Topic Queue

| Method | Pros | Cons | Best For |
|--------|------|------|----------|
| **PostgreSQL table** *(default)* | Production-grade, queryable, persistent | Requires DB setup | Any production use |
| **Google Sheets** | Visual, easy to edit manually | Requires Google credentials, rate limits | Small teams |
| **n8n Static Data** | Zero setup, built-in | Lost on pod restart, not queryable | Development only |
| **Email/IMAP** | Trigger by sending an email | Polling latency, complex parsing | Personal setups |
| **n8n Form** | Built-in UI form | Needs n8n Pro for form persistence | Quick demos |
| **Airtable** | Spreadsheet-like, REST API | Cost, external dependency | Team collaboration |

---

## Operational Best Practices

### Monitoring

```bash
# Watch all n8n pods
watch kubectl get pods -n n8n

# Follow n8n main logs
kubectl logs -n n8n deploy/n8n-main -f

# Check execution queue depth (Redis)
kubectl exec -n n8n deploy/redis -- sh -c \
  'PASS=$(cat /vault/secrets/redis | tr -d "[:space:]"); redis-cli -a "$PASS" llen bull:jobs:wait'
```

### Backup Strategy

```bash
# PostgreSQL backup
kubectl exec -n n8n deploy/postgres -- \
  pg_dump -U n8n n8n > n8n-backup-$(date +%Y%m%d).sql

# n8n data backup (workflows and credentials)
kubectl cp n8n/$(kubectl get pod -n n8n -l app.kubernetes.io/name=n8n,app.kubernetes.io/component=main -o name | head -1 | cut -d/ -f2):/home/node/.n8n ./n8n-data-backup
```

### Scaling Workers

```bash
# Manual scale
kubectl scale deployment n8n-worker -n n8n --replicas=5

# HPA handles auto-scaling based on CPU/memory (min 2, max 10)
kubectl get hpa -n n8n
```

### Updating n8n

```bash
# Rolling update to latest
kubectl set image deployment/n8n-main n8n=n8nio/n8n:latest -n n8n
kubectl set image deployment/n8n-worker n8n-worker=n8nio/n8n:latest -n n8n
kubectl rollout status deployment/n8n-main -n n8n
```

---

## Security Recommendations

1. **Never hardcode secrets in manifests** — all sensitive values come from Vault via agent injection.

2. **Use Vault leases** — the n8n Kubernetes role has a 1h TTL. Vault Agent renews automatically.

3. **Restrict network access:**
   ```yaml
   # Add NetworkPolicy to restrict postgres/redis access
   # Only n8n pods should reach postgres:5432 and redis:6379
   ```

4. **Enable n8n user management** — create individual user accounts instead of using basic auth alone.

5. **Rotate secrets regularly:**
   ```bash
   # Rotate encryption key (requires re-encryption of stored credentials)
   kubectl exec -n vault vault-0 -- vault kv patch secret/n8n/core \
     encryption_key="$(openssl rand -base64 32)"
   ```

6. **Use ImagePullPolicy: Always** for production — ensures latest security patches are picked up.

7. **Enable Audit Logging in Vault:**
   ```bash
   kubectl exec -n vault vault-0 -- vault audit enable file file_path=/vault/logs/audit.log
   ```

8. **Rotate PostgreSQL/Redis passwords periodically** via Vault dynamic secrets (future enhancement).

9. **TLS everywhere** — ingress terminates TLS; all internal communication is within the cluster network.

10. **Limit Vault policy scope** — the `n8n-policy` grants read-only access. Workers never write to Vault.

---

## Troubleshooting

### Vault Agent Not Injecting Secrets

```bash
# Check if Vault Agent Injector is running
kubectl get pods -n vault | grep injector

# Check pod annotations are correct
kubectl describe pod -n n8n <pod-name> | grep vault

# Check vault-agent init container logs
kubectl logs -n n8n <pod-name> -c vault-agent-init

# Verify the Kubernetes auth role exists
kubectl exec -n vault vault-0 -- vault read auth/kubernetes/role/n8n

# Verify SA token reviewer JWT is still valid
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/login \
  role=n8n \
  jwt=$(kubectl create token n8n-sa -n n8n)
```

### n8n Pods CrashLoopBackOff

```bash
# Check recent events
kubectl describe pod -n n8n <pod-name>

# Check if Vault secrets were injected
kubectl exec -n n8n <pod-name> -- ls /vault/secrets/

# Check if all env vars are set
kubectl exec -n n8n <pod-name> -- env | grep -E 'DB_|QUEUE_|N8N_'

# Verify PostgreSQL connectivity
kubectl exec -n n8n <pod-name> -- nc -zv postgres-service 5432
```

### PostgreSQL Connection Errors

```bash
# Test connection from n8n pod
kubectl exec -n n8n deploy/n8n-main -- \
  sh -c '. /vault/secrets/postgres && echo "Password: $DB_POSTGRESDB_PASSWORD"'

# Connect directly to postgres
kubectl exec -n n8n deploy/postgres -- psql -U n8n -d n8n -c '\dt'

# Check postgres logs
kubectl logs -n n8n deploy/postgres --tail=50
```

### Redis Queue Issues

```bash
# Check Redis connectivity
kubectl exec -n n8n deploy/redis -- sh -c \
  'PASS=$(cat /vault/secrets/redis | tr -d "[:space:]"); redis-cli -a "$PASS" ping'

# Check queue depth
kubectl exec -n n8n deploy/redis -- sh -c \
  'PASS=$(cat /vault/secrets/redis | tr -d "[:space:]"); redis-cli -a "$PASS" keys "bull*"'

# Check if workers are consuming jobs
kubectl logs -n n8n deploy/n8n-worker --tail=30 | grep -E 'job|queue'
```

### Scheduling Not Firing

```bash
# Verify timezone is set correctly
kubectl exec -n n8n deploy/n8n-main -- env | grep TIMEZONE

# Check n8n scheduler logs
kubectl logs -n n8n deploy/n8n-main | grep -i schedule

# Manually trigger the workflow to test
# In n8n UI: open Workflow 02 → click "Execute Workflow"
```

### PVC Stuck in Pending

```bash
# Check PVC status
kubectl get pvc -n n8n

# Check PV status
kubectl get pv | grep n8n

# Check if node label matches
kubectl get node --show-labels | grep hostname

# Describe PVC for error details
kubectl describe pvc n8n-data-pvc -n n8n
```

### Email Not Sending

```bash
# Test SMTP from inside the cluster
kubectl run smtp-test --image=alpine --rm -it --restart=Never -- \
  sh -c "apk add openssl && openssl s_client -connect smtp.gmail.com:587 -starttls smtp"

# Check n8n email node error in execution logs (n8n UI)
# Settings → Executions → find the failed execution
```

---

## Run the Diagnostic Script

```bash
chmod +x scripts/troubleshoot.sh
./scripts/troubleshoot.sh
```

---

*Generated for n8n self-hosted on Kubernetes with HashiCorp Vault integration.*  
*Architecture: n8n + PostgreSQL + Redis queue mode + Vault Agent injection + local PVs.*
