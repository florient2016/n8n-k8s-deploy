#!/usr/bin/env bash
# =============================================================================
# Create required host directories for local PersistentVolumes
# Run this on EACH Kubernetes node that will host the n8n workload
# Or run via a DaemonSet / node initialization script
# =============================================================================
set -euo pipefail

echo "Creating n8n local storage directories..."

mkdir -p /n8n/n8n-data
mkdir -p /n8n/postgres
mkdir -p /n8n/redis

# Set permissions for PostgreSQL (uid 999) and n8n (uid 1000)
chown -R 999:999 /n8n/postgres
chown -R 1000:1000 /n8n/n8n-data
chown -R 999:999 /n8n/redis

chmod 700 /n8n/postgres
chmod 750 /n8n/n8n-data
chmod 700 /n8n/redis

echo "Directories created:"
ls -la /n8n/