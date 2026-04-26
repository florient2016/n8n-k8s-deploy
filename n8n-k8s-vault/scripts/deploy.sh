#!/usr/bin/env bash
# =============================================================================
# deploy.sh
# Deploys the full n8n stack to Kubernetes in the correct order.
# Run after vault-setup.sh has completed.
# =============================================================================
set -euo pipefail

NAMESPACE="n8n"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
K8S_DIR="$BASE_DIR/k8s"

echo "=========================================================="
echo "  n8n Kubernetes Deployment"
echo "  Base dir: $BASE_DIR"
echo "=========================================================="

# ---------------------------------------------------------------------------
# Helper: wait for deployment
# ---------------------------------------------------------------------------
wait_for_deployment() {
  local name=$1
  local ns=${2:-$NAMESPACE}
  echo "  Waiting for deployment/$name in ns/$ns ..."
  kubectl rollout status deployment/"$name" -n "$ns" --timeout=300s
}

wait_for_statefulset() {
  local name=$1
  local ns=${2:-$NAMESPACE}
  echo "  Waiting for statefulset/$name in ns/$ns ..."
  kubectl rollout status statefulset/"$name" -n "$ns" --timeout=300s
}

# ---------------------------------------------------------------------------
# 1. Namespace
# ---------------------------------------------------------------------------
echo "=== [1] Namespace ==="
kubectl apply -f "$K8S_DIR/namespace/namespace.yaml"

# ---------------------------------------------------------------------------
# 2. RBAC
# ---------------------------------------------------------------------------
echo "=== [2] RBAC ==="
kubectl apply -f "$K8S_DIR/rbac/rbac.yaml"

# ---------------------------------------------------------------------------
# 3. Vault Agent templates ConfigMap
# ---------------------------------------------------------------------------
echo "=== [3] ConfigMaps ==="
kubectl apply -f "$K8S_DIR/secrets/configmap.yaml"
kubectl apply -f "$K8S_DIR/secrets/vault-agent-templates.yaml"

# ---------------------------------------------------------------------------
# 4. Storage (PVCs)
# ---------------------------------------------------------------------------
echo "=== [4] PersistentVolumeClaims ==="
kubectl apply -f "$K8S_DIR/storage/pvcs.yaml"
echo "  PVCs created:"
kubectl get pvc -n "$NAMESPACE"

# ---------------------------------------------------------------------------
# 5. PostgreSQL
# ---------------------------------------------------------------------------
echo "=== [5] PostgreSQL ==="
kubectl apply -f "$K8S_DIR/postgres/postgres.yaml"
wait_for_statefulset postgres

echo "  Running DB init job..."
kubectl apply -f "$K8S_DIR/postgres/postgres-init-job.yaml"
kubectl wait --for=condition=complete job/postgres-init -n "$NAMESPACE" --timeout=120s || \
  echo "  WARNING: Init job did not complete in time. Check: kubectl logs -n n8n -l app=postgres-init"

# ---------------------------------------------------------------------------
# 6. Redis
# ---------------------------------------------------------------------------
echo "=== [6] Redis ==="
kubectl apply -f "$K8S_DIR/redis/redis.yaml"
wait_for_statefulset redis

# ---------------------------------------------------------------------------
# 7. n8n Main + Workers
# ---------------------------------------------------------------------------
echo "=== [7] n8n Main ==="
kubectl apply -f "$K8S_DIR/n8n/n8n-main.yaml"
wait_for_deployment n8n-main

echo "=== [8] n8n Workers ==="
kubectl apply -f "$K8S_DIR/n8n/n8n-worker.yaml"
wait_for_deployment n8n-worker

# ---------------------------------------------------------------------------
# 8. Ingress
# ---------------------------------------------------------------------------
echo "=== [9] Ingress ==="
kubectl apply -f "$K8S_DIR/ingress/ingress.yaml"

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "  Deployment COMPLETE"
echo "=========================================================="
echo ""
kubectl get all -n "$NAMESPACE"
echo ""
echo "  PVCs:"
kubectl get pvc -n "$NAMESPACE"
echo ""
echo "  Ingress:"
kubectl get ingress -n "$NAMESPACE"
echo ""
echo "  Next steps:"
echo "  1. Point DNS for n8n.yourdomain.com to your ingress LB IP"
echo "  2. Open https://n8n.yourdomain.com and complete setup"
echo "  3. Import workflows from workflows/*.json"
echo "  4. Configure credentials in n8n UI (postgres, smtp, openai)"
echo "  5. Submit your first topic:"
echo "     curl -X POST https://n8n.yourdomain.com/webhook/submit-topic \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"topic\": \"Your first article topic\"}'"
echo "=========================================================="
