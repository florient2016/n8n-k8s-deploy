#!/usr/bin/env bash
# =============================================================================
# n8n Kubernetes Deployment Script
# Prerequisites:
#   - kubectl configured and pointed at your cluster
#   - Vault already set up (run vault/vault-setup.sh first)
#   - Vault Agent Injector installed in the cluster
#   - cert-manager installed (for TLS)
#   - nginx ingress controller installed
# =============================================================================
set -euo pipefail

NAMESPACE="n8n"
DOMAIN="${DOMAIN:-n8n.example.com}"  # Override: DOMAIN=n8n.mycompany.com ./deploy.sh

echo "============================================================"
echo " n8n Kubernetes Deployment"
echo " Domain: ${DOMAIN}"
echo "============================================================"

# Replace placeholder domain in all manifests
echo ""
echo "[Setup] Replacing placeholder domain with: ${DOMAIN}"
find k8s/ -name "*.yaml" -exec sed -i "s/n8n\.example\.com/${DOMAIN}/g" {} \;

# Replace placeholder email
if [ -n "${ADMIN_EMAIL:-}" ]; then
  find k8s/ -name "*.yaml" -exec sed -i "s/your-email@example\.com/${ADMIN_EMAIL}/g" {} \;
  find workflows/ -name "*.json" -exec sed -i "s/your-email@example\.com/${ADMIN_EMAIL}/g" {} \;
fi

# ------------------------------------------------------------
echo ""
echo "[1/8] Creating namespace..."
kubectl apply -f k8s/namespace/namespace.yaml

# ------------------------------------------------------------
echo ""
echo "[2/8] Creating RBAC resources..."
kubectl apply -f k8s/rbac/rbac.yaml

# ------------------------------------------------------------
echo ""
echo "[3/8] Creating PersistentVolumeClaims..."
kubectl apply -f k8s/storage/pvcs.yaml

echo "  Waiting for PVCs to be bound..."
kubectl wait --for=condition=Bound pvc/n8n-postgres-pvc -n ${NAMESPACE} --timeout=60s
kubectl wait --for=condition=Bound pvc/n8n-redis-pvc -n ${NAMESPACE} --timeout=60s
kubectl wait --for=condition=Bound pvc/n8n-data-pvc -n ${NAMESPACE} --timeout=60s
echo "  All PVCs bound."

# ------------------------------------------------------------
echo ""
echo "[4/8] Deploying PostgreSQL..."
kubectl apply -f k8s/postgres/postgres.yaml

echo "  Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod/n8n-postgres-0 -n ${NAMESPACE} --timeout=120s
echo "  PostgreSQL ready."

# ------------------------------------------------------------
echo ""
echo "[5/8] Applying database schema..."
kubectl exec -n ${NAMESPACE} n8n-postgres-0 -- psql -U n8n -d n8n -f /dev/stdin < k8s/postgres/schema.sql
echo "  Schema applied."

# ------------------------------------------------------------
echo ""
echo "[6/8] Deploying Redis..."
kubectl apply -f k8s/redis/redis.yaml

echo "  Waiting for Redis to be ready..."
kubectl wait --for=condition=ready pod/n8n-redis-0 -n ${NAMESPACE} --timeout=120s
echo "  Redis ready."

# ------------------------------------------------------------
echo ""
echo "[7/8] Deploying n8n (main + workers)..."
kubectl apply -f k8s/n8n/configmap.yaml
kubectl apply -f k8s/n8n/n8n-main.yaml
kubectl apply -f k8s/n8n/n8n-worker.yaml

echo "  Waiting for n8n main to be ready..."
kubectl rollout status deployment/n8n -n ${NAMESPACE} --timeout=180s

echo "  Waiting for n8n workers to be ready..."
kubectl rollout status deployment/n8n-worker -n ${NAMESPACE} --timeout=120s

# ------------------------------------------------------------
echo ""
echo "[8/8] Creating Ingress..."
kubectl apply -f k8s/ingress/ingress.yaml

# ------------------------------------------------------------
echo ""
echo "============================================================"
echo " Deployment Complete!"
echo "============================================================"
echo ""
echo " Resources:"
kubectl get all -n ${NAMESPACE}
echo ""
echo " PVCs:"
kubectl get pvc -n ${NAMESPACE}
echo ""
echo " Next steps:"
echo "  1. Point DNS: ${DOMAIN} → your ingress load balancer IP"
echo "  2. Import workflows from workflows/ directory into n8n UI"
echo "  3. Configure n8n credentials:"
echo "     - PostgreSQL connection (uses Vault-injected password)"
echo "     - OpenAI API (uses LLM_API_KEY from Vault)"
echo "     - Gmail SMTP (uses SMTP credentials from Vault)"
echo "  4. Activate both workflows in n8n UI"
echo "  5. Test with: curl -X POST https://${DOMAIN}/webhook/article-topic \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"topic\":\"My First Article Topic\",\"priority\":1}'"
echo ""
