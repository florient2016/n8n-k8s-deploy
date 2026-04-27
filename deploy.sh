#!/usr/bin/env bash
# =============================================================================
# Master Deploy Script: n8n on Kubernetes with HashiCorp Vault
# Run AFTER vault/01-vault-setup.sh
# =============================================================================
set -euo pipefail

NAMESPACE="n8n"
KUBECTL="kubectl"

echo "========================================="
echo "  n8n Kubernetes Deployment"
echo "  Namespace: ${NAMESPACE}"
echo "========================================="

# ---------------------------------------------------------------------------
# Pre-flight: check required tools
# ---------------------------------------------------------------------------
echo ""
echo "[0] Pre-flight checks..."
for tool in kubectl; do
  command -v "$tool" &>/dev/null || { echo "ERROR: '$tool' not found in PATH"; exit 1; }
done

# Check Vault is reachable
kubectl get pod -n vault vault-0 --no-headers &>/dev/null || {
  echo "ERROR: vault-0 pod not found in vault namespace"
  exit 1
}
echo "  All pre-flight checks passed."

# ---------------------------------------------------------------------------
# Step 1: Create namespace
# ---------------------------------------------------------------------------
echo ""
echo "[1] Creating namespace..."
kubectl apply -f namespace.yaml
echo "  Namespace '${NAMESPACE}' ready."

# ---------------------------------------------------------------------------
# Step 2: Create host directories (run this on each node)
# ---------------------------------------------------------------------------
echo ""
echo "[2] Host directory setup..."
echo "  NOTE: Run scripts/create-host-dirs.sh on each Kubernetes node"
echo "  that will host n8n workloads before continuing."
echo "  Press Enter when done, or Ctrl+C to cancel."
read -r

# ---------------------------------------------------------------------------
# Step 3: RBAC
# ---------------------------------------------------------------------------
echo ""
echo "[3] Applying RBAC..."
kubectl apply -f rbac.yaml
echo "  RBAC resources created."

# ---------------------------------------------------------------------------
# Step 4: Storage
# ---------------------------------------------------------------------------
echo ""
echo "[4] Applying storage (StorageClass, PVs, PVCs)..."
kubectl apply -f storage.yaml
echo "  Storage resources created."

# Verify PVCs are bound
echo "  Waiting for PVCs to bind..."
for pvc in n8n-data-pvc n8n-postgres-pvc n8n-redis-pvc; do
  echo -n "    ${pvc}: "
  for i in $(seq 1 30); do
    STATUS=$(kubectl get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [[ "$STATUS" == "Bound" ]]; then
      echo "Bound ✓"
      break
    fi
    if [[ "$i" == "30" ]]; then
      echo "WARNING: still not bound after 60s (status: ${STATUS})"
      echo "  Check: kubectl describe pvc ${pvc} -n ${NAMESPACE}"
    fi
    sleep 2
  done
done

# ---------------------------------------------------------------------------
# Step 5: PostgreSQL
# ---------------------------------------------------------------------------
echo ""
echo "[5] Deploying PostgreSQL..."
kubectl apply -f postgres.yaml

echo "  Waiting for PostgreSQL to be ready..."
kubectl rollout status deployment/n8n-postgres -n "${NAMESPACE}" --timeout=120s
echo "  PostgreSQL ready ✓"

# ---------------------------------------------------------------------------
# Step 6: Redis
# ---------------------------------------------------------------------------
echo ""
echo "[6] Deploying Redis..."
kubectl apply -f redis.yaml

echo "  Waiting for Redis to be ready..."
kubectl rollout status deployment/n8n-redis -n "${NAMESPACE}" --timeout=60s
echo "  Redis ready ✓"

# ---------------------------------------------------------------------------
# Step 7: n8n main
# ---------------------------------------------------------------------------
echo ""
echo "[7] Deploying n8n main..."
kubectl apply -f n8n-main.yaml

echo "  Waiting for n8n main to be ready..."
kubectl rollout status deployment/n8n-main -n "${NAMESPACE}" --timeout=180s
echo "  n8n main ready ✓"

# ---------------------------------------------------------------------------
# Step 8: n8n workers
# ---------------------------------------------------------------------------
echo ""
echo "[8] Deploying n8n workers..."
kubectl apply -f n8n-worker.yaml

echo "  Waiting for n8n workers to be ready..."
kubectl rollout status deployment/n8n-worker -n "${NAMESPACE}" --timeout=120s
echo "  n8n workers ready ✓"

# ---------------------------------------------------------------------------
# Step 9: Ingress
# ---------------------------------------------------------------------------
echo ""
echo "[9] Applying Ingress and NetworkPolicy..."
kubectl apply -f ingress.yaml
echo "  Ingress applied."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Deployment Complete!"
echo "========================================="
echo ""
kubectl get all -n "${NAMESPACE}"
echo ""
echo "Next steps:"
echo "  1. Import workflows from workflows/ into n8n UI"
echo "  2. Create PostgreSQL credential in n8n (n8n PostgreSQL)"
echo "  3. Create SMTP credential in n8n"
echo "  4. Create OpenAI/LLM HTTP Header Auth credential in n8n"
echo "  5. Test: curl -X POST https://n8n.yourdomain.com/webhook/submit-topic \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"topic\": \"Write about ROSA HCP vs Classic\"}'"
echo ""
echo "  Monitor pods: kubectl get pods -n ${NAMESPACE} -w"
echo "  Logs:         kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=n8n -f"