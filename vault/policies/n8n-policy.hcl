# n8n Vault Policy
# Grants read access to all n8n-related secrets

path "secret/data/n8n/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/n8n/*" {
  capabilities = ["read", "list"]
}

# Allow renewal of own token
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Allow lookup of own token
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
