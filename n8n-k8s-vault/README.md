# n8n on Kubernetes with HashiCorp Vault — Production-Grade Article Automation

> **Self-hosted n8n** on Kubernetes, secrets managed by **HashiCorp Vault**, automated article generation running **3×/week**, delivered to your inbox.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Vault Configuration](#vault-configuration)
5. [Kubernetes Manifests](#kubernetes-manifests)
6. [n8n Workflows](#n8n-workflows)
7. [Workflow Design — Node by Node](#workflow-design--node-by-node)
8. [Schedule & Cron](#schedule--cron)
9. [Topic Queue — Database Schema](#topic-queue--database-schema)
10. [Email Delivery](#email-delivery)
11. [Optional: Medium Publishing](#optional-medium-publishing)
12. [Environment Variables Reference](#environment-variables-reference)
13. [Operational Best Practices](#operational-best-practices)
14. [Security Recommendations](#security-recommendations)
15. [Troubleshooting](#troubleshooting)
16. [Alternative Topic Storage](#alternative-topic-storage)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                           │
│                                                                      │
│  ┌─────────────┐   ┌──────────────────────────────────────────────┐ │
│  │  Ingress    │   │              Namespace: n8n                  │ │
│  │  (nginx +   │──▶│                                              │ │
│  │  cert-mgr)  │   │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │ │
│  └─────────────┘   │  │  n8n     │  │  n8n     │  │  n8n     │  │ │
│                    │  │  main    │  │ worker-1 │  │ worker-2 │  │ │
│  ┌─────────────┐   │  └────┬─────┘  └────┬─────┘  └────┬─────┘  │ │
│  │  HashiCorp  │   │       │              │              │        │ │
│  │   Vault     │   │  ┌────▼─────────────▼──────────────▼──────┐ │ │
│  │ (vault ns)  │──▶│  │            Redis (queue)               │ │ │
│  │             │   │  │         n8n-redis-pvc (5Gi)            │ │ │
│  └──────┬──────┘   │  └────────────────────────────────────────┘ │ │
│         │          │                                              │ │
│  Vault Agent       │  ┌────────────────────────────────────────┐ │ │
│  sidecar injects   │  │          PostgreSQL (n8n DB +          │ │ │
│  secrets at        │  │           article_topics table)        │ │ │
│  /vault/secrets/   │  │         n8n-postgres-pvc (20Gi)        │ │ │
│                    │  └────────────────────────────────────────┘ │ │
│                    │                                              │ │
│                    │  ┌────────────────────────────────────────┐ │ │
│                    │  │         n8n data volume                │ │ │
│                    │  │         n8n-data-pvc (10Gi RWX)        │ │ │
│                    │  └────────────────────────────────────────┘ │ │
│                    └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘

Flow:
 You → POST /webhook/submit-topic → article_topics table (status=pending)
 Schedule (Mon/Wed/Fri 08:00) → claim topic → GPT-4o → email → status=done
```

### Components

| Component | Image | Purpose |
|-----------|-------|---------|
| n8n main | `n8nio/n8n:latest` | UI, webhooks, schedule triggers |
| n8n worker (×2) | `n8nio/n8n:latest` | Job execution (queue mode) |
| PostgreSQL | `postgres:16-alpine` | n8n DB + article topic queue |
| Redis | `redis:7-alpine` | Bull queue backend |
| Vault Agent | Injected sidecar | Secret injection (no plaintext in manifests) |
| cert-manager | ClusterIssuer | Automatic Let's Encrypt TLS |
| nginx ingress | IngressController | HTTPS reverse proxy |

---

## Prerequisites

```bash
# Required tools
kubectl      # ≥ 1.27
helm         # ≥ 3.12 (optional, for cert-manager)
openssl      # for generating secrets
jq           # for JSON parsing in scripts

# Cluster requirements
# - HashiCorp Vault already installed in namespace 'vault', pod name 'vault-0'
# - Vault Agent Injector deployed (bundled with Vault Helm chart)
# - nginx Ingress Controller installed
# - cert-manager installed (or bring your own TLS)
# - A StorageClass that supports ReadWriteMany (for n8n-data-pvc)
#   e.g. NFS, AWS EFS, Longhorn, GlusterFS
```

### Install Vault Agent Injector (if not already installed)

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm upgrade --install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --set "injector.enabled=true" \
  --set "server.enabled=false"   # if Vault server is already running
```

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/yourorg/n8n-k8s-vault.git
cd n8n-k8s-vault

# 2. Set your Vault root token
export ROOT_TOKEN="hvs.xxxxxxxxxx"

# 3. Set real secret values (or let the script generate them)
export SMTP_PASSWORD="your-gmail-app-password"
export LLM_API_KEY="sk-xxxxxxxxxxxxxxxx"
export MEDIUM_TOKEN=""   # optional

# 4. Run Vault setup
chmod +x scripts/vault-setup.sh
./scripts/vault-setup.sh

# 5. Edit domain names in manifests
#    Replace 'n8n.yourdomain.com' in:
#      k8s/secrets/configmap.yaml
#      k8s/ingress/ingress.yaml

# 6. Edit StorageClass in k8s/storage/pvcs.yaml if needed

# 7. Deploy
chmod +x scripts/deploy.sh
./scripts/deploy.sh

# 8. Import workflows via n8n UI
#    Settings → Import from file → workflows/*.json

# 9. Submit your first topic
curl -X POST https://n8n.yourdomain.com/webhook/submit-topic \
  -H 'Content-Type: application/json' \
  -d '{"topic": "How to deploy n8n on Kubernetes with Vault integration", "priority": 1}'
```

---

## Vault Configuration

### Secret Paths

| Vault Path | Keys | Description |
|-----------|------|-------------|
| `secret/n8n/encryption` | `key` | n8n encryption key (32-byte hex) |
| `secret/n8n/postgres` | `password`, `host`, `port`, `db`, `user` | PostgreSQL credentials |
| `secret/n8n/redis` | `password`, `host`, `port` | Redis credentials |
| `secret/n8n/smtp` | `password`, `host`, `port`, `user`, `from` | SMTP/Gmail credentials |
| `secret/n8n/llm` | `api_key`, `provider` | OpenAI / Anthropic / Mistral key |
| `secret/n8n/medium` | `token` | Medium integration token (optional) |

### Vault Policy (`vault/policies/n8n-policy.hcl`)

```hcl
path "secret/data/n8n/*" {
  capabilities = ["read", "list"]
}
```

### Kubernetes Auth Role

```bash
vault write auth/kubernetes/role/n8n-role \
  bound_service_account_names=n8n-sa \
  bound_service_account_namespaces=n8n \
  policies=n8n-policy \
  ttl=1h
```

### How Secret Injection Works

Each pod has **Vault Agent Injector annotations**. When the pod starts:

1. Vault Agent sidecar authenticates to Vault using the pod's SA JWT
2. It renders Vault secrets into `/vault/secrets/n8n.env`
3. The n8n container runs `. /vault/secrets/n8n.env` before `n8n start`
4. **No secrets ever appear in Kubernetes manifests or environment variables**

---

## Kubernetes Manifests

```
k8s/
├── namespace/
│   └── namespace.yaml              # Namespace: n8n
├── rbac/
│   └── rbac.yaml                   # ServiceAccount, Role, RoleBinding, ClusterRoleBinding
├── secrets/
│   ├── configmap.yaml              # Non-sensitive n8n config (timezone, mode, host)
│   └── vault-agent-templates.yaml  # Vault secret rendering templates
├── storage/
│   └── pvcs.yaml                   # n8n-postgres-pvc, n8n-data-pvc, n8n-redis-pvc
├── postgres/
│   ├── postgres.yaml               # StatefulSet + Service
│   ├── postgres-init-job.yaml      # One-shot Job: creates topic queue table
│   └── init.sql                    # SQL schema
├── redis/
│   └── redis.yaml                  # StatefulSet + Service + ConfigMap
├── n8n/
│   ├── n8n-main.yaml               # Main deployment + Service
│   └── n8n-worker.yaml             # Worker deployment + HPA
└── ingress/
    └── ingress.yaml                # nginx Ingress + ClusterIssuer (TLS)
```

### PersistentVolumeClaims

| PVC Name | Size | Access Mode | Used By |
|----------|------|-------------|---------|
| `n8n-postgres-pvc` | 20Gi | RWO | PostgreSQL data directory |
| `n8n-data-pvc` | 10Gi | RWX | n8n `.n8n` folder (main + workers) |
| `n8n-redis-pvc` | 5Gi | RWO | Redis RDB + AOF persistence |

---

## n8n Workflows

```
workflows/
├── 01-topic-input.json         # Webhook: accepts topic submissions
├── 02-scheduled-publisher.json # Schedule: generates + emails article 3×/week
└── 03-medium-publisher.json    # Optional: publishes draft to Medium
```

### Import Workflows

1. Open n8n UI → **Settings → Import from file**
2. Import each JSON file in order
3. Activate workflows 01 and 02 (03 is optional)

---

## Workflow Design — Node by Node

### Workflow 01: Topic Input

```
Webhook (POST /submit-topic)
  └─→ Validate Input (IF: topic not empty)
        ├─→ [valid]   INSERT INTO article_topics → Respond 201 Created
        └─→ [invalid] Respond 400 Bad Request
```

**Submit a topic:**
```bash
curl -X POST https://n8n.yourdomain.com/webhook/submit-topic \
  -H 'Content-Type: application/json' \
  -d '{
    "topic": "ROSA HCP vs Classic: a practical comparison",
    "notes": "Focus on upgrade paths and SRE experience",
    "priority": 1
  }'
```

### Workflow 02: Scheduled Publisher

```
Schedule Trigger (Mon/Wed/Fri 08:00)
  └─→ Claim Next Pending Topic (UPDATE … RETURNING with FOR UPDATE SKIP LOCKED)
        └─→ Has Pending Topic? (IF length > 0)
              ├─→ [yes] Generate Article (HTTP → OpenAI GPT-4o)
              │           └─→ Format Article (Code node: Markdown + HTML email)
              │                 └─→ Send Email (SMTP)
              │                       └─→ Mark Topic Done (UPDATE status='done')
              │                             └─→ Log Run Success (INSERT workflow_runs)
              └─→ [no]  No Topics Available (NoOp — silent skip)

Error path (via Error Workflow setting):
  └─→ Mark Topic Error (retry_count++, status back to 'pending' if retries < 3)
        └─→ Email Error Alert
```

### Workflow 03: Medium Publisher (Optional)

```
Webhook (POST /publish-to-medium)
  └─→ GET /v1/me (get Medium user ID)
        └─→ POST /v1/users/{id}/posts (create draft)
              └─→ UPDATE article_topics SET article_url = ...
                    └─→ Respond 200 OK
```

---

## Schedule & Cron

The schedule trigger uses this cron expression:

```
0 8 * * 1,3,5
│ │ │ │ └─ Day of week: 1=Mon, 3=Wed, 5=Fri
│ │ │ └─── Month: * (every month)
│ │ └───── Day of month: * (every day)
│ └─────── Hour: 8 (08:00)
└───────── Minute: 0
```

This runs at **08:00 on Monday, Wednesday, and Friday** in the timezone set by `GENERIC_TIMEZONE` (default: `Europe/Berlin` — adjust in `configmap.yaml`).

---

## Topic Queue — Database Schema

```sql
-- Main queue table
CREATE TABLE article_topics (
    id            SERIAL PRIMARY KEY,
    topic         TEXT        NOT NULL,          -- article topic/request
    notes         TEXT,                          -- extra context for the LLM
    status        VARCHAR(20) NOT NULL DEFAULT 'pending',
                  -- pending → processing → done | error
    priority      SMALLINT    NOT NULL DEFAULT 5, -- 1=high, 10=low
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    scheduled_at  TIMESTAMPTZ,                   -- optional target date
    processed_at  TIMESTAMPTZ,
    error_msg     TEXT,
    article_title TEXT,                          -- set after generation
    article_url   TEXT,                          -- set after Medium publish
    email_sent    BOOLEAN     NOT NULL DEFAULT FALSE,
    retry_count   SMALLINT    NOT NULL DEFAULT 0  -- max 3 retries
);

-- Audit log
CREATE TABLE workflow_runs (
    id          SERIAL PRIMARY KEY,
    topic_id    INTEGER REFERENCES article_topics(id),
    run_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status      VARCHAR(20),
    duration_ms INTEGER,
    error_msg   TEXT,
    n8n_exec_id TEXT
);
```

**Useful queries:**
```sql
-- View pending topics
SELECT id, topic, priority, created_at FROM article_topics WHERE status = 'pending' ORDER BY priority, created_at;

-- View completed articles
SELECT id, topic, article_title, processed_at, email_sent FROM article_topics WHERE status = 'done';

-- Reset errored topics
UPDATE article_topics SET status = 'pending', retry_count = 0 WHERE status = 'error';
```

---

## Email Delivery

### Gmail App Password (Recommended)

1. Enable 2FA on your Google account
2. Go to **Google Account → Security → App Passwords**
3. Create an app password for "Mail"
4. Store in Vault: `vault kv put secret/n8n/smtp password="your-16-char-app-password"`

### Environment Variables for SMTP

| Variable | Example Value |
|----------|--------------|
| `N8N_SMTP_HOST` | `smtp.gmail.com` |
| `N8N_SMTP_PORT` | `587` |
| `N8N_SMTP_USER` | `your@gmail.com` |
| `N8N_SMTP_PASS` | *(from Vault)* |
| `N8N_SMTP_SENDER` | `your@gmail.com` |

### Configure in n8n Credentials UI

After deploying, go to **n8n UI → Credentials → SMTP**:
- **Host:** `smtp.gmail.com`
- **Port:** `587`
- **User:** your Gmail address
- **Password:** the app password from Vault

---

## Optional Medium Publishing

### Prerequisites

1. Generate a Medium integration token at: https://medium.com/me/settings → Integration Tokens
2. Store in Vault:
   ```bash
   kubectl exec -n vault vault-0 -- \
     env VAULT_TOKEN="$ROOT_TOKEN" \
     vault kv put secret/n8n/medium token="your-medium-token"
   ```
3. Set `MEDIUM_TOKEN` env in ConfigMap or source from the Vault-injected env file
4. Import and activate workflow `03-medium-publisher.json`

### Trigger Medium Publishing

After receiving the generated article by email:

```bash
curl -X POST https://n8n.yourdomain.com/webhook/publish-to-medium \
  -H 'Content-Type: application/json' \
  -d '{
    "topic_id": 1,
    "article_title": "Your Article Title",
    "article_content": "# Title\n\nFull markdown content..."
  }'
```

The article is created as a **draft** on Medium (not auto-published). Review and publish manually.

---

## Environment Variables Reference

### Set in ConfigMap (non-sensitive)

| Variable | Default | Description |
|----------|---------|-------------|
| `GENERIC_TIMEZONE` | `Europe/Berlin` | Timezone for scheduler |
| `N8N_HOST` | `n8n.yourdomain.com` | Public hostname |
| `WEBHOOK_URL` | `https://n8n.yourdomain.com/` | Webhook base URL |
| `EXECUTIONS_MODE` | `queue` | Enable queue mode |
| `DB_TYPE` | `postgresdb` | Database driver |
| `N8N_LOG_LEVEL` | `info` | Log verbosity |

### Injected by Vault Agent (sensitive)

| Variable | Vault Path | Description |
|----------|-----------|-------------|
| `N8N_ENCRYPTION_KEY` | `secret/n8n/encryption` → `key` | Workflow encryption |
| `DB_POSTGRESDB_PASSWORD` | `secret/n8n/postgres` → `password` | Postgres password |
| `QUEUE_BULL_REDIS_PASSWORD` | `secret/n8n/redis` → `password` | Redis password |
| `N8N_SMTP_PASS` | `secret/n8n/smtp` → `password` | SMTP password |
| `LLM_API_KEY` | `secret/n8n/llm` → `api_key` | OpenAI/LLM API key |

---

## Operational Best Practices

### Backup

```bash
# Backup PostgreSQL (run from a pod or external job)
kubectl exec -n n8n postgres-0 -- \
  pg_dump -U n8n n8n | gzip > n8n-backup-$(date +%Y%m%d).sql.gz

# Backup n8n data volume (export workflows from UI or API)
curl -s https://n8n.yourdomain.com/api/v1/workflows \
  -H "X-N8N-API-KEY: your-api-key" | jq . > workflows-backup.json
```

### Scaling Workers

```bash
# Manual scale
kubectl scale deployment n8n-worker -n n8n --replicas=4

# The HPA will auto-scale based on CPU/memory (2–8 replicas)
kubectl get hpa -n n8n
```

### Upgrade n8n

```bash
# Pull latest image and restart
kubectl set image deployment/n8n-main -n n8n n8n=n8nio/n8n:latest
kubectl set image deployment/n8n-worker -n n8n n8n-worker=n8nio/n8n:latest
kubectl rollout status deployment/n8n-main -n n8n
```

### Rotate Secrets

```bash
# Rotate LLM API key
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" \
  vault kv put secret/n8n/llm api_key="new-key" provider="openai"

# Restart pods to pick up new secret (Vault Agent will re-render on lease renewal)
kubectl rollout restart deployment/n8n-main deployment/n8n-worker -n n8n
```

---

## Security Recommendations

1. **Never commit secrets** — all sensitive values are in Vault, sourced at runtime
2. **Rotate secrets regularly** — use `vault kv put` and rolling restart
3. **Use network policies** — restrict pod-to-pod traffic within `n8n` namespace
4. **Enable audit logging** in Vault (`vault audit enable file file_path=/vault/audit/audit.log`)
5. **Use a non-root user** — all pods run as `uid=1000` (node user)
6. **Set resource limits** — prevents noisy-neighbor resource starvation
7. **Enable n8n 2FA** — under Settings → Personal → Two-factor authentication
8. **Restrict webhook access** — use IP allowlisting in nginx ingress annotations if needed:
   ```yaml
   nginx.ingress.kubernetes.io/whitelist-source-range: "1.2.3.4/32"
   ```
9. **Review LLM prompts** — the system prompt is stored in the workflow; rotate or update via n8n UI
10. **Seal Vault** if cluster is compromised: `kubectl exec -n vault vault-0 -- vault operator seal`

---

## Troubleshooting

### Pods stuck in Init state

```bash
# Check Vault Agent init logs
kubectl logs -n n8n <pod-name> -c vault-agent-init

# Check if Vault is reachable
kubectl exec -n n8n <pod-name> -- wget -qO- http://vault.vault.svc.cluster.local:8200/v1/sys/health
```

### Vault Agent not injecting secrets

```bash
# Verify the role is bound correctly
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault read auth/kubernetes/role/n8n-role

# Verify the SA exists and matches
kubectl get sa -n n8n n8n-sa

# Check Vault injector logs
kubectl logs -n vault -l app.kubernetes.io/name=vault-agent-injector
```

### n8n can't connect to PostgreSQL

```bash
# Test connectivity from n8n pod
kubectl exec -n n8n deployment/n8n-main -- \
  nc -zv postgres-service.n8n.svc.cluster.local 5432

# Check Postgres pod logs
kubectl logs -n n8n statefulset/postgres
```

### n8n can't connect to Redis

```bash
# Test connectivity
kubectl exec -n n8n deployment/n8n-main -- \
  nc -zv redis-service.n8n.svc.cluster.local 6379

# Check Redis logs
kubectl logs -n n8n statefulset/redis
```

### Scheduled workflow not running

```bash
# Check n8n-main pod is running (scheduler lives here)
kubectl get pod -n n8n -l component=main

# View workflow execution history in UI:
# n8n UI → Executions

# Manually trigger the workflow:
# n8n UI → Open workflow → Run Now
```

### Email not sending

```bash
# Test SMTP credentials
kubectl exec -n n8n deployment/n8n-main -- \
  sh -c '. /vault/secrets/n8n.env && echo "SMTP_PASS=${N8N_SMTP_PASS:0:3}..."'

# Check n8n logs for SMTP errors
kubectl logs -n n8n deployment/n8n-main | grep -i smtp
```

### Topic stuck in 'processing' state

```bash
# Connect to postgres and reset
kubectl exec -n n8n statefulset/postgres -- \
  psql -U n8n -c "UPDATE article_topics SET status='pending' WHERE status='processing';"
```

---

## Alternative Topic Storage

| Method | Pros | Cons |
|--------|------|------|
| **PostgreSQL table** *(default)* | Transactional, production-grade, already deployed | Requires DB access |
| **Google Sheets** | Simple, visual, no DB needed | Rate limits, auth complexity |
| **n8n Static Data** | Zero setup | Not persistent across restarts in cluster |
| **Airtable** | GUI, easy to manage | External SaaS dependency |
| **IMAP email input** | Submit topics by sending email | Parsing complexity |
| **GitHub Issues** | Version controlled, labels | Overkill for simple use |

To use Google Sheets: replace the PostgreSQL nodes in workflow 02 with n8n's built-in **Google Sheets** nodes. Use one sheet as the queue with columns: `Topic`, `Notes`, `Status`, `ProcessedAt`.

---

## File Structure

```
n8n-k8s-vault/
├── README.md
├── scripts/
│   ├── vault-setup.sh          # One-time Vault configuration
│   └── deploy.sh               # Deploy all K8s resources
├── vault/
│   └── policies/
│       └── n8n-policy.hcl      # Vault read policy for n8n
├── k8s/
│   ├── namespace/namespace.yaml
│   ├── rbac/rbac.yaml
│   ├── secrets/
│   │   ├── configmap.yaml
│   │   └── vault-agent-templates.yaml
│   ├── storage/pvcs.yaml
│   ├── postgres/
│   │   ├── postgres.yaml
│   │   ├── postgres-init-job.yaml
│   │   └── init.sql
│   ├── redis/redis.yaml
│   ├── n8n/
│   │   ├── n8n-main.yaml
│   │   └── n8n-worker.yaml
│   └── ingress/ingress.yaml
└── workflows/
    ├── 01-topic-input.json
    ├── 02-scheduled-publisher.json
    └── 03-medium-publisher.json
```

---

## License

MIT — use freely for your own infrastructure.

---

*Generated with n8n automation on Kubernetes. See the workflows in `workflows/` to understand how articles like this one are created.*
