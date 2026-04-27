# =============================================================================
# vault/n8n-vault-policy.hcl
# HashiCorp Vault policy for n8n workloads
# Grants read-only access to all n8n secret paths via KV-v2
# =============================================================================

# Core n8n secrets (encryption key)
path "secret/data/n8n/core" {
  capabilities = ["read"]
}

# PostgreSQL credentials
path "secret/data/n8n/postgres" {
  capabilities = ["read"]
}

# Redis credentials
path "secret/data/n8n/redis" {
  capabilities = ["read"]
}

# SMTP / email credentials
path "secret/data/n8n/smtp" {
  capabilities = ["read"]
}

# LLM API key
path "secret/data/n8n/llm" {
  capabilities = ["read"]
}

# Medium integration token (optional)
path "secret/data/n8n/medium" {
  capabilities = ["read"]
}

# Allow listing secret names (metadata only, not values)
path "secret/metadata/n8n/*" {
  capabilities = ["list"]
}
