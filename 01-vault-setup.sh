#!/usr/bin/env bash
# =============================================================================
# Vault Setup Script — run once before deploying n8n
# All Vault commands execute via: kubectl exec -n vault vault-0
# =============================================================================
set -euo pipefail

: "${VAULT_ROOT_TOKEN:?Set VAULT_ROOT_TOKEN before running}"
: "${N8N_ENCRYPTION_KEY:?Set N8N_ENCRYPTION_KEY}"
: "${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD}"
: "${REDIS_PASSWORD:?Set REDIS_PASSWORD}"
: "${SMTP_PASSWORD:?Set SMTP_PASSWORD}"
: "${LLM_API_KEY:?Set LLM_API_KEY}"

DEV_TOKEN="${DEV_TOKEN:-}"
VAULT_NS="vault"
VAULT_POD="vault-0"
N8N_NS="n8n"

echo "========================================="
echo "  Vault Setup for n8n"
echo "========================================="

# ---------------------------------------------------------------------------
# 1. Collect Kubernetes cluster info
# ---------------------------------------------------------------------------
echo ""
echo "[1] Collecting cluster info..."

KUBE_HOST=$(kubectl cluster-info | grep 'Kubernetes control' | awk '{print $NF}' \
  | sed 's/\x1b\[[0-9;]*m//g')
echo "  Kubernetes API: ${KUBE_HOST}"

KUBE_CA=$(kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode)

echo "[2] Getting Vault SA JWT..."
VAULT_SA_JWT=$(kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token)
echo "  JWT: ${VAULT_SA_JWT:0:50}..."

# ---------------------------------------------------------------------------
# 2. Write Vault policy and copy to pod
# ---------------------------------------------------------------------------
echo ""
echo "[3] Writing Vault policy..."

cat > /tmp/n8n-policy.hcl << 'POLICY'
path "secret/data/n8n/*" {
  capabilities = ["read"]
}
path "secret/metadata/n8n/*" {
  capabilities = ["list"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
POLICY

kubectl cp /tmp/n8n-policy.hcl "${VAULT_NS}/${VAULT_POD}:/tmp/n8n-policy.hcl"
rm /tmp/n8n-policy.hcl

# ---------------------------------------------------------------------------
# 3. Configure Vault via kubectl exec
# ---------------------------------------------------------------------------
echo ""
echo "[4] Configuring Vault..."

# Enable KV v2
kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault secrets enable -path=secret kv-v2 2>/dev/null \
  || echo "  KV v2 already enabled."

# Write policy from copied file
kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault policy write n8n /tmp/n8n-policy.hcl
echo "  Policy 'n8n' written."

# ---------------------------------------------------------------------------
# 4. Write secrets
# ---------------------------------------------------------------------------
echo ""
echo "[5] Writing secrets to Vault..."

kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/core \
    encryption_key="${N8N_ENCRYPTION_KEY}"

kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/postgres \
    password="${POSTGRES_PASSWORD}"

kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/redis \
    password="${REDIS_PASSWORD}"

kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/smtp \
    password="${SMTP_PASSWORD}"

kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/llm \
    api_key="${LLM_API_KEY}"

if [ -n "${DEV_TOKEN}" ]; then
  kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
    env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
    vault kv put secret/n8n/devto \
      token="${DEV_TOKEN}"
  echo "  Dev.to token written."
else
  echo "  Skipping Dev.to token (DEV_TOKEN not set)."
fi

echo "  All secrets written."

# ---------------------------------------------------------------------------
# 5. Enable and configure Kubernetes auth
# ---------------------------------------------------------------------------
echo ""
echo "[6] Configuring Kubernetes auth..."

kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault auth enable kubernetes 2>/dev/null \
  || echo "  Kubernetes auth already enabled."

kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault write auth/kubernetes/config \
    token_reviewer_jwt="${VAULT_SA_JWT}" \
    kubernetes_host="${KUBE_HOST}" \
    kubernetes_ca_cert="${KUBE_CA}" \
    issuer="https://kubernetes.default.svc.cluster.local"

echo "  Kubernetes auth configured."

# Create Vault role for n8n
kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
  env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault write auth/kubernetes/role/n8n \
    bound_service_account_names="n8n-sa" \
    bound_service_account_namespaces="${N8N_NS}" \
    policies="n8n" \
    ttl="1h" \
    max_ttl="24h"

echo "  Vault role 'n8n' created."

echo ""
echo "========================================="
echo "  Vault setup COMPLETE"
echo "========================================="
echo ""
echo "Next: run  scripts/deploy.sh"
