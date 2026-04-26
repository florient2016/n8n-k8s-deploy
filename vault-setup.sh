#!/usr/bin/env bash
# =============================================================================
# vault-setup.sh
# Configures HashiCorp Vault for n8n on Kubernetes
# Run this script ONCE after your cluster and Vault are ready.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Prerequisites check
# ---------------------------------------------------------------------------
echo "=== [0] Checking prerequisites ==="
for cmd in kubectl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done

# ---------------------------------------------------------------------------
# 1. Collect cluster + Vault info
# ---------------------------------------------------------------------------
echo "=== [1] Collecting cluster info ==="

VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
N8N_NAMESPACE="n8n"
N8N_SA="n8n-sa"

# Kubernetes API host
KUBE_HOST=$(kubectl cluster-info | grep 'Kubernetes control' | awk '{print $NF}')
echo "  KUBE_HOST = $KUBE_HOST"

# Kubernetes CA certificate
KUBE_CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode)
echo "  KUBE_CA   = [retrieved, length=$(echo "$KUBE_CA" | wc -c)]"

# Vault SA JWT from the Vault pod
echo "Getting Service Account JWT from Vault pod..."
VAULT_SA_JWT=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token)
echo "  JWT: ${VAULT_SA_JWT:0:50}..."

# Root token (set ROOT_TOKEN in your environment before running this script)
if [[ -z "${ROOT_TOKEN:-}" ]]; then
  echo "ERROR: ROOT_TOKEN env var is required."
  echo "  export ROOT_TOKEN=<your-vault-root-token>"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Generate secrets (or accept from env)
# ---------------------------------------------------------------------------
echo "=== [2] Generating secrets ==="

N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(openssl rand -hex 32)}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 24)}"
REDIS_PASSWORD="${REDIS_PASSWORD:-$(openssl rand -hex 24)}"
SMTP_PASSWORD="${SMTP_PASSWORD:-changeme-set-real-smtp-password}"
LLM_API_KEY="${LLM_API_KEY:-changeme-set-real-llm-api-key}"
MEDIUM_TOKEN="${MEDIUM_TOKEN:-}"   # Optional

echo "  Secrets generated (or taken from env)."

# ---------------------------------------------------------------------------
# 3. Enable KV v2 secrets engine (idempotent)
# ---------------------------------------------------------------------------
echo "=== [3] Enabling KV v2 secrets engine ==="
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault secrets enable -path=secret kv-v2 2>/dev/null || \
  echo "  KV-v2 already enabled at 'secret/' — skipping."

# ---------------------------------------------------------------------------
# 4. Write secrets into Vault
# ---------------------------------------------------------------------------
echo "=== [4] Writing secrets to Vault ==="

run_vault() {
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    env VAULT_TOKEN="$ROOT_TOKEN" vault "$@"
}

run_vault kv put secret/n8n/encryption \
  key="$N8N_ENCRYPTION_KEY"

run_vault kv put secret/n8n/postgres \
  password="$POSTGRES_PASSWORD" \
  host="postgres-service.n8n.svc.cluster.local" \
  port="5432" \
  db="n8n" \
  user="n8n"

run_vault kv put secret/n8n/redis \
  password="$REDIS_PASSWORD" \
  host="redis-service.n8n.svc.cluster.local" \
  port="6379"

run_vault kv put secret/n8n/smtp \
  password="$SMTP_PASSWORD" \
  host="${SMTP_HOST:-smtp.gmail.com}" \
  port="${SMTP_PORT:-587}" \
  user="${SMTP_USER:-your-email@gmail.com}" \
  from="${SMTP_FROM:-your-email@gmail.com}"

run_vault kv put secret/n8n/llm \
  api_key="$LLM_API_KEY" \
  provider="${LLM_PROVIDER:-openai}"

if [[ -n "$MEDIUM_TOKEN" ]]; then
  run_vault kv put secret/n8n/medium \
    token="$MEDIUM_TOKEN"
  echo "  Medium token stored."
else
  echo "  No MEDIUM_TOKEN set — skipping."
fi

echo "  All secrets written."

# ---------------------------------------------------------------------------
# 5. Copy & apply Vault policy
# ---------------------------------------------------------------------------
echo "=== [5] Applying Vault policy ==="

POLICY_FILE="$(dirname "$0")/../vault/policies/n8n-policy.hcl"
if [[ ! -f "$POLICY_FILE" ]]; then
  echo "ERROR: Policy file not found at $POLICY_FILE"
  exit 1
fi

kubectl cp "$POLICY_FILE" "$VAULT_NAMESPACE/$VAULT_POD:/tmp/n8n-policy.hcl"
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault policy write n8n-policy /tmp/n8n-policy.hcl
echo "  Policy 'n8n-policy' written."

# ---------------------------------------------------------------------------
# 6. Enable Kubernetes auth (idempotent)
# ---------------------------------------------------------------------------
echo "=== [6] Enabling Kubernetes auth method ==="
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault auth enable kubernetes 2>/dev/null || \
  echo "  Kubernetes auth already enabled — skipping."

# ---------------------------------------------------------------------------
# 7. Configure Kubernetes auth
# ---------------------------------------------------------------------------
echo "=== [7] Configuring Kubernetes auth ==="

# Write CA cert to a temp file inside vault-0
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  sh -c "cat > /tmp/kube-ca.crt << 'EOFCA'
$KUBE_CA
EOFCA"

kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_TOKEN="$ROOT_TOKEN" \
  vault write auth/kubernetes/config \
    kubernetes_host="$KUBE_HOST" \
    kubernetes_ca_cert=@/tmp/kube-ca.crt \
    token_reviewer_jwt="$VAULT_SA_JWT" \
    issuer="https://kubernetes.default.svc.cluster.local"

echo "  Kubernetes auth configured."

# ---------------------------------------------------------------------------
# 8. Create Vault role for n8n service account
# ---------------------------------------------------------------------------
echo "=== [8] Creating Vault Kubernetes role ==="
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_TOKEN="$ROOT_TOKEN" \
  vault write auth/kubernetes/role/n8n-role \
    bound_service_account_names="$N8N_SA" \
    bound_service_account_namespaces="$N8N_NAMESPACE" \
    policies="n8n-policy" \
    ttl="1h"

echo "  Role 'n8n-role' created."

# ---------------------------------------------------------------------------
# 9. Verify
# ---------------------------------------------------------------------------
echo "=== [9] Verifying ==="
echo "--- Vault secrets at secret/n8n/ ---"
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault kv list secret/n8n

echo "--- Vault Kubernetes role ---"
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault read auth/kubernetes/role/n8n-role

# ---------------------------------------------------------------------------
# 10. Print summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "  Vault setup COMPLETE"
echo "=========================================================="
echo "  Secrets stored at:"
echo "    secret/n8n/encryption"
echo "    secret/n8n/postgres"
echo "    secret/n8n/redis"
echo "    secret/n8n/smtp"
echo "    secret/n8n/llm"
echo "    secret/n8n/medium  (if token provided)"
echo ""
echo "  Kubernetes role 'n8n-role' bound to:"
echo "    namespace: $N8N_NAMESPACE"
echo "    service account: $N8N_SA"
echo ""
echo "  IMPORTANT: Save these generated secrets securely!"
echo "    N8N_ENCRYPTION_KEY = $N8N_ENCRYPTION_KEY"
echo "    POSTGRES_PASSWORD  = $POSTGRES_PASSWORD"
echo "    REDIS_PASSWORD     = $REDIS_PASSWORD"
echo "=========================================================="
