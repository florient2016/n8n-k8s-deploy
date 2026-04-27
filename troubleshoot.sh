#!/usr/bin/env bash
# =============================================================================
# scripts/troubleshoot.sh
# Diagnostic script for n8n on Kubernetes
# =============================================================================
set -euo pipefail

NS="n8n"
echo "======================================================"
echo " n8n on Kubernetes — Diagnostics"
echo "======================================================"

echo ""
echo "── PODS ──────────────────────────────────────────────"
kubectl get pods -n "${NS}" -o wide

echo ""
echo "── SERVICES ─────────────────────────────────────────"
kubectl get svc -n "${NS}"

echo ""
echo "── PVCS ─────────────────────────────────────────────"
kubectl get pvc -n "${NS}"

echo ""
echo "── INGRESS ──────────────────────────────────────────"
kubectl get ingress -n "${NS}"

echo ""
echo "── n8n MAIN LOGS (last 50) ──────────────────────────"
kubectl logs -n "${NS}" deploy/n8n-main --tail=50 2>/dev/null || echo "  n8n-main not found"

echo ""
echo "── WORKER LOGS (last 20) ────────────────────────────"
kubectl logs -n "${NS}" deploy/n8n-worker --tail=20 2>/dev/null || echo "  n8n-worker not found"

echo ""
echo "── POSTGRES LOGS (last 20) ──────────────────────────"
kubectl logs -n "${NS}" deploy/postgres --tail=20 2>/dev/null || echo "  postgres not found"

echo ""
echo "── REDIS LOGS (last 20) ─────────────────────────────"
kubectl logs -n "${NS}" deploy/redis --tail=20 2>/dev/null || echo "  redis not found"

echo ""
echo "── VAULT AGENT LOGS (from n8n-main) ─────────────────"
N8N_POD=$(kubectl get pod -n "${NS}" -l app.kubernetes.io/name=n8n,app.kubernetes.io/component=main -o name | head -1)
if [[ -n "${N8N_POD}" ]]; then
  kubectl logs -n "${NS}" "${N8N_POD}" -c vault-agent --tail=30 2>/dev/null || echo "  vault-agent container not found"
else
  echo "  n8n main pod not found"
fi

echo ""
echo "── TOPIC QUEUE STATUS ───────────────────────────────"
echo "  Connect to PostgreSQL to check queue:"
echo "  kubectl exec -n ${NS} deploy/postgres -- psql -U n8n -d n8n -c \\"
echo "    'SELECT status, count(*) FROM article_topics GROUP BY status;'"

echo ""
echo "── VAULT CONNECTIVITY TEST ──────────────────────────"
echo "  Test from n8n pod:"
echo "  kubectl exec -n ${NS} deploy/n8n-main -- ls /vault/secrets/"
echo "  kubectl exec -n ${NS} deploy/n8n-main -- cat /vault/secrets/core"

echo ""
echo "======================================================"
