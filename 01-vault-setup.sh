#!/usr/bin/env bash
# =============================================================================
# Vault Setup Script for n8n on Kubernetes
# Run this ONCE from your local machine with kubectl configured
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# REQUIRED: Set these environment variables before running
# ---------------------------------------------------------------------------
: "${VAULT_ROOT_TOKEN:?VAULT_ROOT_TOKEN must be set}"
: "${N8N_ENCRYPTION_KEY:?N8N_ENCRYPTION_KEY must be set}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${SMTP_PASSWORD:?SMTP_PASSWORD must be set}"
: "${LLM_API_KEY:?LLM_API_KEY must be set}"

# Optional
DEV_TOKEN="${DEV_TOKEN:-}"

VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
N8N_NAMESPACE="n8n"

echo "========================================="
echo "  n8n Vault Setup"
echo "========================================="

# ---------------------------------------------------------------------------
# Step 1: Collect Kubernetes cluster information
# ---------------------------------------------------------------------------
echo "[1/6] Collecting Kubernetes cluster info..."

KUBE_HOST=$(kubectl cluster-info | grep 'Kubernetes control' | awk '{print $NF}' | sed 's/\x1b\[[0-9;]*m//g')
KUBE_CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode)

echo "  Kubernetes API: ${KUBE_HOST}"

echo "[2/6] Getting Vault service account JWT..."
VAULT_SA_JWT=$(kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token)
echo "  JWT (first 50 chars): ${VAULT_SA_JWT:0:50}..."

# ---------------------------------------------------------------------------
# Step 2: Create Vault policy file and copy to vault pod
# ---------------------------------------------------------------------------
echo "[3/6] Creating Vault policy..."

cat > /tmp/n8n-policy.hcl << 'POLICY'
# n8n application secrets - read only
path "secret/data/n8n/*" {
  capabilities = ["read", "list"]
}

# Allow token renewal
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Allow token lookup
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
POLICY

kubectl cp /tmp/n8n-policy.hcl "${VAULT_NAMESPACE}/${VAULT_POD}:/tmp/n8n-policy.hcl"
echo "  Policy file copied to vault pod."

# ---------------------------------------------------------------------------
# Step 3: Configure Vault (all commands via kubectl exec)
# ---------------------------------------------------------------------------
echo "[4/6] Configuring Vault via kubectl exec..."

kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault auth list > /dev/null 2>&1 || true

# Enable KV v2 secrets engine
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault secrets enable -path=secret kv-v2 2>/dev/null || \
  echo "  KV v2 already enabled at 'secret/'"

# Write the policy from the copied file
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault policy write n8n /tmp/n8n-policy.hcl

echo "  Vault policy 'n8n' written."

# ---------------------------------------------------------------------------
# Step 4: Write secrets to Vault
# ---------------------------------------------------------------------------
echo "[5/6] Writing secrets to Vault..."

# Core n8n secrets
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/core \
  encryption_key="${N8N_ENCRYPTION_KEY}"

# PostgreSQL
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/postgres \
  password="${POSTGRES_PASSWORD}" \
  host="n8n-postgres-svc.${N8N_NAMESPACE}.svc.cluster.local" \
  port="5432" \
  database="n8n" \
  user="n8n"

# Redis
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/redis \
  password="${REDIS_PASSWORD}" \
  host="n8n-redis-svc.${N8N_NAMESPACE}.svc.cluster.local" \
  port="6379"

# SMTP / Email
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/smtp \
  password="${SMTP_PASSWORD}"

# LLM API Key
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put secret/n8n/llm \
  api_key="${LLM_API_KEY}"

# Dev.to token (optional)
if [[ -n "${DEV_TOKEN}" ]]; then
  kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
    VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
    vault kv put secret/n8n/devto \
    token="${DEV_TOKEN}"
  echo "  Dev.to token written."
else
  echo "  Skipping Dev.to token (DEV_TOKEN not set)."
fi

echo "  All secrets written to Vault."

# ---------------------------------------------------------------------------
# Step 5: Enable Kubernetes Auth and create role
# ---------------------------------------------------------------------------
echo "[6/6] Configuring Kubernetes auth backend..."

# Enable Kubernetes auth (idempotent)
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault auth enable kubernetes 2>/dev/null || \
  echo "  Kubernetes auth already enabled."

# Configure Kubernetes auth backend
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault write auth/kubernetes/config \
  token_reviewer_jwt="${VAULT_SA_JWT}" \
  kubernetes_host="${KUBE_HOST}" \
  kubernetes_ca_cert="${KUBE_CA}" \
  issuer="https://kubernetes.default.svc.cluster.local"

echo "  Kubernetes auth configured."

# Create Vault role for n8n
kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault write auth/kubernetes/role/n8n \
  bound_service_account_names="n8n-sa" \
  bound_service_account_namespaces="${N8N_NAMESPACE}" \
  policies="n8n" \
  ttl="1h" \
  max_ttl="24h"

echo "  Vault role 'n8n' created."

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -f /tmp/n8n-policy.hcl

echo ""
echo "========================================="
echo "  Vault setup COMPLETE"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Create namespace:  kubectl create namespace ${N8N_NAMESPACE}"
echo "  2. Apply RBAC:        kubectl apply -f k8s/rbac/"
echo "  3. Apply storage:     kubectl apply -f k8s/storage/"
echo "  4. Deploy Postgres:   kubectl apply -f k8s/postgres/"
echo "  5. Deploy Redis:      kubectl apply -f k8s/redis/"
echo "  6. Deploy n8n:        kubectl apply -f k8s/n8n/"
echo "  7. Apply Ingress:     kubectl apply -f k8s/ingress/"