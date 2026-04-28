#!/usr/bin/env bash
# =============================================================================
# Master Deploy Script — n8n on Kubernetes with HashiCorp Vault
# Run AFTER: vault/01-vault-setup.sh
#
# Key fixes in this version:
#   1. hostPath PVs — bind immediately, no nodeAffinity conflicts
#   2. Service ClusterIPs fetched and stored in ConfigMap n8n-svc-ips
#      so pods use IPs not DNS (per requirement)
#   3. PostgreSQL rollout timeout bumped; proper readiness gates
# =============================================================================
set -euo pipefail

NAMESPACE="n8n"

echo "========================================="
echo "  n8n Kubernetes Deployment"
echo "========================================="

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
echo ""
echo "[0] Pre-flight checks..."
kubectl get pod -n vault vault-0 --no-headers &>/dev/null || {
  echo "ERROR: vault-0 pod not found in 'vault' namespace. Run vault setup first."
  exit 1
}
echo "  vault-0 OK"

# ---------------------------------------------------------------------------
# 1. Namespace
# ---------------------------------------------------------------------------
echo ""
echo "[1] Namespace..."
kubectl apply -f  namespace.yaml
echo "  Namespace '${NAMESPACE}' ready."

# ---------------------------------------------------------------------------
# 2. RBAC
# ---------------------------------------------------------------------------
echo ""
echo "[2] RBAC..."
kubectl apply -f  rbac.yaml
echo "  RBAC done."

# ---------------------------------------------------------------------------
# 3. Storage (hostPath PVs — bind immediately with Immediate volumeBindingMode)
# ---------------------------------------------------------------------------
echo ""
echo "[3] Storage..."
kubectl apply -f storage.yaml

echo "  Waiting up to 30s for PVCs to bind..."
ALL_BOUND=true
for PVC in n8n-data-pvc n8n-postgres-pvc n8n-redis-pvc; do
  for i in $(seq 1 15); do
    STATUS=$(kubectl get pvc "${PVC}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [ "$STATUS" = "Bound" ]; then
      echo "  ${PVC}: Bound ✓"
      break
    fi
    if [ "$i" = "15" ]; then
      echo "  ${PVC}: still Pending (status=${STATUS})"
      echo "    → kubectl describe pvc ${PVC} -n ${NAMESPACE}"
      ALL_BOUND=false
    fi
    sleep 2
  done
done

if [ "$ALL_BOUND" = "false" ]; then
  echo ""
  echo "WARN: Some PVCs not bound. Common fixes:"
  echo "  - Ensure hostPath directories exist on the node"
  echo "    Run: kubectl apply -f k8s/storage/fix-host-dirs-job.yaml"
  echo "  - Check StorageClass exists: kubectl get sc standard"
  echo ""
fi

# ---------------------------------------------------------------------------
# 4. PostgreSQL (deploy service first to get ClusterIP)
# ---------------------------------------------------------------------------
echo ""
echo "[4] PostgreSQL..."
# Apply only the Service first so we can get the ClusterIP
kubectl apply -f postgres.yaml

echo "  Waiting for PostgreSQL Service ClusterIP..."
PG_IP=""
for i in $(seq 1 20); do
  PG_IP=$(kubectl get svc n8n-postgres-svc -n "${NAMESPACE}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
  [ -n "$PG_IP" ] && [ "$PG_IP" != "None" ] && break
  sleep 2
done
if [ -z "$PG_IP" ]; then
  echo "ERROR: Could not get PostgreSQL Service ClusterIP"
  exit 1
fi
echo "  PostgreSQL ClusterIP: ${PG_IP}"

# ---------------------------------------------------------------------------
# 5. Redis (deploy service first to get ClusterIP)
# ---------------------------------------------------------------------------
echo ""
echo "[5] Redis..."
kubectl apply -f redis.yaml

echo "  Waiting for Redis Service ClusterIP..."
REDIS_IP=""
for i in $(seq 1 20); do
  REDIS_IP=$(kubectl get svc n8n-redis-svc -n "${NAMESPACE}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
  [ -n "$REDIS_IP" ] && [ "$REDIS_IP" != "None" ] && break
  sleep 2
done
if [ -z "$REDIS_IP" ]; then
  echo "ERROR: Could not get Redis Service ClusterIP"
  exit 1
fi
echo "  Redis ClusterIP: ${REDIS_IP}"

# ---------------------------------------------------------------------------
# 6. Create n8n-svc-ips ConfigMap with actual IPs (no DNS)
#    This ConfigMap is mounted into n8n-main and n8n-worker pods
#    and also used to patch the n8n-config ConfigMap
# ---------------------------------------------------------------------------
echo ""
echo "[6] Writing Service IPs into ConfigMaps..."

# ConfigMap with raw IP files (mounted as volume into init containers)
kubectl create configmap n8n-svc-ips \
  --from-literal=pg-ip="${PG_IP}" \
  --from-literal=redis-ip="${REDIS_IP}" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  n8n-svc-ips ConfigMap: pg-ip=${PG_IP}, redis-ip=${REDIS_IP}"

# Patch the main n8n-config ConfigMap with real IPs
# (replaces the REPLACE_* placeholders from the static manifest)
kubectl apply -f n8n-main.yaml

kubectl patch configmap n8n-config -n "${NAMESPACE}" \
  --type merge \
  -p "{\"data\":{\"DB_POSTGRESDB_HOST\":\"${PG_IP}\",\"QUEUE_BULL_REDIS_HOST\":\"${REDIS_IP}\"}}"

echo "  n8n-config patched: DB_POSTGRESDB_HOST=${PG_IP}, QUEUE_BULL_REDIS_HOST=${REDIS_IP}"

# ---------------------------------------------------------------------------
# 7. Wait for PostgreSQL to be fully ready
# ---------------------------------------------------------------------------
echo ""
echo "[7] Waiting for PostgreSQL rollout (timeout: 300s)..."
kubectl rollout status deployment/n8n-postgres -n "${NAMESPACE}" --timeout=300s
echo "  PostgreSQL ready ✓"

# ---------------------------------------------------------------------------
# 8. Wait for Redis to be fully ready
# ---------------------------------------------------------------------------
echo ""
echo "[8] Waiting for Redis rollout (timeout: 120s)..."
kubectl rollout status deployment/n8n-redis -n "${NAMESPACE}" --timeout=120s
echo "  Redis ready ✓"

# ---------------------------------------------------------------------------
# 9. Deploy n8n main
# ---------------------------------------------------------------------------
echo ""
echo "[9] Deploying n8n main..."
# ConfigMap already applied; apply the Deployment + Service
kubectl apply -f n8n-main.yaml

echo "  Waiting for n8n main rollout (timeout: 300s)..."
kubectl rollout status deployment/n8n-main -n "${NAMESPACE}" --timeout=300s
echo "  n8n main ready ✓"

# ---------------------------------------------------------------------------
# 10. Deploy n8n workers
# ---------------------------------------------------------------------------
echo ""
echo "[10] Deploying n8n workers..."
kubectl apply -f n8n-worker.yaml
kubectl rollout status deployment/n8n-worker -n "${NAMESPACE}" --timeout=180s
echo "  n8n workers ready ✓"

# ---------------------------------------------------------------------------
# 11. Ingress
# ---------------------------------------------------------------------------
echo ""
echo "[11] Ingress + NetworkPolicy..."
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
echo "Service IPs:"
echo "  PostgreSQL : ${PG_IP}:5432"
echo "  Redis      : ${REDIS_IP}:6379"
echo ""
kubectl get all -n "${NAMESPACE}"
echo ""
echo "Post-deploy steps:"
echo "  1. Import workflows from workflows/ folder in n8n UI"
echo "     Settings → Workflows → Import"
echo "  2. Create credentials (PostgreSQL, SMTP, HTTP Header Auth for LLM)"
echo "     - PostgreSQL host: ${PG_IP}"
echo "     - Redis host: ${REDIS_IP}"
echo "  3. Activate both workflows in n8n UI"
echo "  4. Submit your first topic:"
echo "       curl -X POST https://n8n.yourdomain.com/webhook/submit-topic \\"
echo "         -H 'Content-Type: application/json' \\"
echo "         -d '{\"topic\": \"Write about ROSA HCP vs Classic\"}'"
echo ""
echo "Useful commands:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl logs -n ${NAMESPACE} -l app=n8n-main -c n8n -f"
echo "  kubectl logs -n ${NAMESPACE} -l app=n8n-worker -c n8n-worker -f"
echo "  kubectl logs -n ${NAMESPACE} -l app=n8n-main -c vault-agent -f"
