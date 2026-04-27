#!/usr/bin/env bash
# =============================================================================
# vault/01-vault-setup.sh
# Configure HashiCorp Vault for n8n on Kubernetes
# Run this ONCE from your local machine (kubectl access required)
# =============================================================================
set -euo pipefail

# ─── Prerequisites ────────────────────────────────────────────────────────────
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }

echo "======================================================"
echo " n8n on Kubernetes — Vault Setup"
echo "======================================================"

# ─── 1. Collect cluster info ──────────────────────────────────────────────────
echo "[1/8] Collecting cluster information..."

KUBE_HOST=$(kubectl cluster-info | grep 'Kubernetes control' | awk '{print $NF}')
echo "  Kubernetes API: ${KUBE_HOST}"

KUBE_CA=$(kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode)

echo "[2/8] Collecting Vault service account JWT from vault-0 pod..."
VAULT_SA_JWT=$(kubectl exec -n vault vault-0 -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token)
echo "  JWT (first 50 chars): ${VAULT_SA_JWT:0:50}..."

# ─── 2. Collect secrets from environment variables ───────────────────────────
echo ""
echo "[3/8] Collecting secret values from environment variables..."
echo "      (Set these before running to avoid interactive prompts)"
echo ""
echo "  Required env vars:"
echo "    export VAULT_ROOT_TOKEN=..."
echo "    export N8N_ENCRYPTION_KEY=..."
echo "    export POSTGRES_PASSWORD=..."
echo "    export REDIS_PASSWORD=..."
echo "    export SMTP_PASSWORD=..."
echo "    export LLM_API_KEY=..."
echo "    export MEDIUM_TOKEN=...   (optional)"
echo ""

# Helper: read from env var or fall back to hidden prompt
require_secret() {
  local var_name="$1"
  local prompt_label="$2"
  local value="${!var_name:-}"

  if [[ -n "${value}" ]]; then
    echo "  ✓ ${var_name} loaded from environment"
  else
    read -rp "  ${prompt_label}: " -s value; echo ""
    if [[ -z "${value}" ]]; then
      echo "  ERROR: ${var_name} is required but was not provided." >&2
      exit 1
    fi
  fi
  # Export back so callers can use it
  export "${var_name}=${value}"
}

optional_secret() {
  local var_name="$1"
  local prompt_label="$2"
  local value="${!var_name:-}"

  if [[ -n "${value}" ]]; then
    echo "  ✓ ${var_name} loaded from environment"
  else
    read -rp "  ${prompt_label} (leave blank to skip): " -s value; echo ""
    export "${var_name}=${value:-DISABLED}"
  fi
}

require_secret  VAULT_ROOT_TOKEN    "Vault ROOT_TOKEN"
require_secret  N8N_ENCRYPTION_KEY  "n8n Encryption Key (32+ chars)"
require_secret  POSTGRES_PASSWORD   "PostgreSQL password"
require_secret  REDIS_PASSWORD      "Redis password"
require_secret  SMTP_PASSWORD       "SMTP / Gmail App Password"
require_secret  LLM_API_KEY         "LLM API Key (OpenAI/Anthropic/etc)"
optional_secret MEDIUM_TOKEN        "Medium Integration Token"

echo ""
echo "  All secrets collected."

# ─── 3. Enable Vault KV secrets engine ───────────────────────────────────────
echo ""
echo "[4/8] Enabling KV-v2 secrets engine at 'secret/'..."

kubectl exec -n vault vault-0 -- \
  vault login -no-print "${VAULT_ROOT_TOKEN}"

kubectl exec -n vault vault-0 -- \
  vault secrets enable -path=secret kv-v2 2>/dev/null || \
  echo "  KV-v2 already enabled, skipping."

# ─── 4. Write secrets ─────────────────────────────────────────────────────────
echo "[5/8] Writing secrets to Vault..."

# n8n core secrets
kubectl exec -n vault vault-0 -- \
  vault kv put secret/n8n/core \
    encryption_key="${N8N_ENCRYPTION_KEY}"

# PostgreSQL
kubectl exec -n vault vault-0 -- \
  vault kv put secret/n8n/postgres \
    password="${POSTGRES_PASSWORD}" \
    user="n8n" \
    db="n8n" \
    host="postgres-service.n8n.svc.cluster.local" \
    port="5432"

# Redis
kubectl exec -n vault vault-0 -- \
  vault kv put secret/n8n/redis \
    password="${REDIS_PASSWORD}" \
    host="redis-service.n8n.svc.cluster.local" \
    port="6379"

# SMTP / Email
kubectl exec -n vault vault-0 -- \
  vault kv put secret/n8n/smtp \
    password="${SMTP_PASSWORD}"

# LLM
kubectl exec -n vault vault-0 -- \
  vault kv put secret/n8n/llm \
    api_key="${LLM_API_KEY}"

# Medium (optional — write empty if not provided)
if [[ -n "${MEDIUM_TOKEN}" ]]; then
  kubectl exec -n vault vault-0 -- \
    vault kv put secret/n8n/medium \
      token="${MEDIUM_TOKEN}"
  echo "  Medium token stored."
else
  kubectl exec -n vault vault-0 -- \
    vault kv put secret/n8n/medium \
      token="DISABLED"
  echo "  Medium token skipped (set to DISABLED)."
fi

echo "  Secrets written successfully."

# ─── 5. Write Vault policy ───────────────────────────────────────────────────
echo "[6/8] Creating Vault policy for n8n..."

cat <<'EOF' > /tmp/n8n-vault-policy.hcl
# n8n secrets policy
# Grants read access to all n8n secret paths

path "secret/data/n8n/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/n8n/*" {
  capabilities = ["read", "list"]
}
EOF

kubectl cp /tmp/n8n-vault-policy.hcl vault/vault-0:/tmp/n8n-vault-policy.hcl

kubectl exec -n vault vault-0 -- \
  vault policy write n8n-policy /tmp/n8n-vault-policy.hcl

echo "  Policy 'n8n-policy' created."

# ─── 6. Enable Kubernetes auth ───────────────────────────────────────────────
echo "[7/8] Configuring Vault Kubernetes authentication..."

kubectl exec -n vault vault-0 -- \
  vault auth enable kubernetes 2>/dev/null || \
  echo "  Kubernetes auth already enabled, skipping."

# Write CA cert to a temp file in the pod
echo "${KUBE_CA}" > /tmp/kube-ca.crt
kubectl cp /tmp/kube-ca.crt vault/vault-0:/tmp/kube-ca.crt

kubectl exec -n vault vault-0 -- \
  vault write auth/kubernetes/config \
    token_reviewer_jwt="${VAULT_SA_JWT}" \
    kubernetes_host="${KUBE_HOST}" \
    kubernetes_ca_cert=@/tmp/kube-ca.crt \
    issuer="https://kubernetes.default.svc.cluster.local"

echo "  Kubernetes auth configured."

# ─── 7. Create Kubernetes auth role ──────────────────────────────────────────
echo "[8/8] Creating Vault auth role for n8n service account..."

kubectl exec -n vault vault-0 -- \
  vault write auth/kubernetes/role/n8n \
    bound_service_account_names="n8n-sa" \
    bound_service_account_namespaces="n8n" \
    policies="n8n-policy" \
    ttl="1h"

echo "  Vault role 'n8n' bound to SA 'n8n-sa' in namespace 'n8n'."

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " Vault setup complete!"
echo ""
echo " Secrets written:"
echo "   secret/n8n/core         (encryption_key)"
echo "   secret/n8n/postgres     (password, user, db, host, port)"
echo "   secret/n8n/redis        (password, host, port)"
echo "   secret/n8n/smtp         (password)"
echo "   secret/n8n/llm          (api_key)"
echo "   secret/n8n/medium       (token)"
echo ""
echo " Auth role: n8n → n8n-policy"
echo " Next step: apply Kubernetes manifests"
echo "======================================================"

# Cleanup temp files
rm -f /tmp/n8n-vault-policy.hcl /tmp/kube-ca.crt
