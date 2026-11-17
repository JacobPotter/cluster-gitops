#!/usr/bin/env bash
# ==============================================================================
# HashiCorp Vault Community Edition - Initialization & Provisioning Script
# ==============================================================================
# This script initializes Vault, unseals the instance, enables KV-v2 secrets
# engine, configures Kubernetes ServiceAccount authentication, defines targeted
# ACL policies, binds Kubernetes auth roles, and seeds initial development secrets.
#
# Usage:
#   ./scripts/init-vault.sh [--namespace <vault-namespace>] [--keys-file <path>]
#
# Environment Variables:
#   VAULT_NAMESPACE   Kubernetes namespace where Vault is running (default: vault)
#   VAULT_KEYS_FILE   Path to save/load unseal keys and root token (default: .vault-keys.json)
#   VAULT_ADDR        Vault address (default: http://127.0.0.1:8200 or in-pod exec)
# ==============================================================================

set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="vault-0"
VAULT_KEYS_FILE="${VAULT_KEYS_FILE:-.vault-keys.json}"
USE_KUBECTL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n)
      VAULT_NAMESPACE="$2"
      shift 2
      ;;
    --keys-file|-k)
      VAULT_KEYS_FILE="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--namespace <vault-namespace>] [--keys-file <path>]"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

echo "================================================================="
echo "  HashiCorp Vault Community Edition - Provisioner & Initializer  "
echo "================================================================="
echo "Vault Namespace : ${VAULT_NAMESPACE}"
echo "Keys File       : ${VAULT_KEYS_FILE}"
echo ""

# Helper to run vault commands either via local vault binary or kubectl exec
vault_cmd() {
  if [[ "${USE_KUBECTL}" == "true" ]]; then
    kubectl exec -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env VAULT_TOKEN="${VAULT_TOKEN:-}" vault "$@"
  else
    vault "$@"
  fi
}

# Determine execution strategy
if command -v vault &> /dev/null && [[ -n "${VAULT_ADDR:-}" ]]; then
  echo "🚀 Using local 'vault' CLI targeting ${VAULT_ADDR}..."
  USE_KUBECTL=false
elif command -v kubectl &> /dev/null; then
  echo "🚀 Using 'kubectl exec' against ${VAULT_NAMESPACE}/${VAULT_POD}..."
  USE_KUBECTL=true
  
  if ! kubectl get pod "${VAULT_POD}" -n "${VAULT_NAMESPACE}" &> /dev/null; then
    echo "⚠️  Pod ${VAULT_POD} not found in namespace ${VAULT_NAMESPACE}."
    echo "⏳ Waiting up to 30s for ${VAULT_POD} to appear..."
    for i in {1..30}; do
      if kubectl get pod "${VAULT_POD}" -n "${VAULT_NAMESPACE}" &> /dev/null; then
        break
      fi
      sleep 1
    done
  fi

  if ! kubectl get pod "${VAULT_POD}" -n "${VAULT_NAMESPACE}" &> /dev/null; then
    echo "❌ Error: Pod '${VAULT_POD}' does not exist in namespace '${VAULT_NAMESPACE}'."
    echo ""
    echo "👉 To resolve this, apply the Vault Helm application to your cluster first:"
    echo "   kubectl apply -f bootstrap/vault.yaml"
    echo "   (or trigger an ArgoCD synchronization of the vault application)"
    exit 1
  fi

  echo "⏳ Waiting for pod ${VAULT_POD} to reach Running state..."
  for i in {1..30}; do
    POD_PHASE=$(kubectl get pod "${VAULT_POD}" -n "${VAULT_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "${POD_PHASE}" == "Running" ]]; then
      break
    fi
    sleep 1
  done
  if [[ "${POD_PHASE}" != "Running" ]]; then
    echo "❌ Error: Pod ${VAULT_POD} is in phase '${POD_PHASE}' (expected 'Running')."
    echo "   Check pod events: kubectl describe pod -n ${VAULT_NAMESPACE} ${VAULT_POD}"
    exit 1
  fi
else
  echo "❌ Error: Neither 'vault' nor 'kubectl' CLI is available."
  exit 1
fi

# ------------------------------------------------------------------------------
# 1. Check Initialization Status
# ------------------------------------------------------------------------------
echo "🔍 Checking Vault initialization status..."
INIT_STATUS=""
for attempt in {1..10}; do
  INIT_STATUS=$(vault_cmd status -format=json 2>/dev/null || true)
  if [[ -n "${INIT_STATUS}" ]] && echo "${INIT_STATUS}" | jq -e '.initialized != null' &>/dev/null; then
    break
  fi
  echo "⏳ Vault is starting up or unreachable. Waiting for service (attempt ${attempt}/10)..."
  sleep 3
done

if [[ -z "${INIT_STATUS}" ]] || ! echo "${INIT_STATUS}" | jq -e '.initialized != null' &>/dev/null; then
  echo "❌ Error: Could not retrieve valid initialization status from Vault."
  echo "   Inspect container logs: kubectl logs -n ${VAULT_NAMESPACE} ${VAULT_POD}"
  exit 1
fi

IS_INITIALIZED=$(echo "${INIT_STATUS}" | jq -r '.initialized')
IS_SEALED=$(echo "${INIT_STATUS}" | jq -r '.sealed')

UNSEAL_KEY=""
ROOT_TOKEN=""

if [[ "${IS_INITIALIZED}" == "false" ]]; then
  echo "📦 Initializing Vault instance (1 share, threshold 1)..."
  INIT_OUTPUT=$(vault_cmd operator init -key-shares=1 -key-threshold=1 -format=json)
  echo "${INIT_OUTPUT}" > "${VAULT_KEYS_FILE}"
  chmod 600 "${VAULT_KEYS_FILE}" 2>/dev/null || true
  
  UNSEAL_KEY=$(echo "${INIT_OUTPUT}" | jq -r '.unseal_keys_b64[0]')
  ROOT_TOKEN=$(echo "${INIT_OUTPUT}" | jq -r '.root_token')
  
  echo "✅ Vault initialized successfully!"
  echo "🔑 Keys saved securely to: ${VAULT_KEYS_FILE}"
else
  echo "ℹ️  Vault is already initialized."
  if [[ -f "${VAULT_KEYS_FILE}" ]]; then
    UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0] // .unseal_keys_hex[0]' "${VAULT_KEYS_FILE}")
    ROOT_TOKEN=$(jq -r '.root_token' "${VAULT_KEYS_FILE}")
  elif [[ -n "${VAULT_UNSEAL_KEY:-}" && -n "${VAULT_TOKEN:-}" ]]; then
    UNSEAL_KEY="${VAULT_UNSEAL_KEY}"
    ROOT_TOKEN="${VAULT_TOKEN}"
  fi
fi

# ------------------------------------------------------------------------------
# 2. Unseal Vault
# ------------------------------------------------------------------------------
if [[ "${IS_SEALED}" == "true" ]]; then
  if [[ -n "${UNSEAL_KEY}" && "${UNSEAL_KEY}" != "null" ]]; then
    echo "🔓 Unsealing Vault instance..."
    vault_cmd operator unseal "${UNSEAL_KEY}" > /dev/null
    echo "✅ Vault unsealed successfully!"
  else
    echo "⚠️  Vault is sealed but no unseal key was found in ${VAULT_KEYS_FILE} or environment."
    echo "   Please unseal Vault manually with: vault operator unseal"
  fi
else
  echo "ℹ️  Vault is already unsealed."
fi

# Set VAULT_TOKEN for subsequent commands
if [[ -n "${ROOT_TOKEN}" && "${ROOT_TOKEN}" != "null" ]]; then
  export VAULT_TOKEN="${ROOT_TOKEN}"
fi

# ------------------------------------------------------------------------------
# 3. Enable KV-v2 Secrets Engine
# ------------------------------------------------------------------------------
echo "⚙️  Configuring KV-v2 secrets engine at path 'secret/'..."
SECRETS_LIST=$(vault_cmd secrets list -format=json 2>/dev/null || echo "{}")
if echo "${SECRETS_LIST}" | jq -e '."secret/"' > /dev/null 2>&1; then
  echo "ℹ️  KV secrets engine at 'secret/' is already enabled."
else
  vault_cmd secrets enable -path=secret kv-v2
  echo "✅ Enabled KV-v2 at 'secret/'"
fi

# ------------------------------------------------------------------------------
# 4. Enable & Configure Kubernetes Authentication
# ------------------------------------------------------------------------------
echo "⚙️  Configuring Kubernetes authentication method..."
AUTH_LIST=$(vault_cmd auth list -format=json 2>/dev/null || echo "{}")
if echo "${AUTH_LIST}" | jq -e '."kubernetes/"' > /dev/null 2>&1; then
  echo "ℹ️  Kubernetes auth method is already enabled."
else
  vault_cmd auth enable kubernetes
  echo "✅ Enabled Kubernetes auth method."
fi

echo "⚙️  Writing in-cluster Kubernetes auth engine configuration..."
vault_cmd write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# ------------------------------------------------------------------------------
# 5. Define Targeted Vault ACL Policies
# ------------------------------------------------------------------------------
echo "📜 Writing ACL policy: poke-db-policy..."
if [[ "${USE_KUBECTL}" == "true" ]]; then
  kubectl exec -i -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env VAULT_TOKEN="${VAULT_TOKEN:-}" vault policy write poke-db-policy - << 'EOF'
path "secret/data/poke-db/*" {
  capabilities = ["read"]
}
path "secret/metadata/poke-db/*" {
  capabilities = ["read", "list"]
}
EOF
else
  vault policy write poke-db-policy - << 'EOF'
path "secret/data/poke-db/*" {
  capabilities = ["read"]
}
path "secret/metadata/poke-db/*" {
  capabilities = ["read", "list"]
}
EOF
fi

echo "📜 Writing ACL policy: minio-policy..."
if [[ "${USE_KUBECTL}" == "true" ]]; then
  kubectl exec -i -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env VAULT_TOKEN="${VAULT_TOKEN:-}" vault policy write minio-policy - << 'EOF'
path "secret/data/minio" {
  capabilities = ["read"]
}
path "secret/metadata/minio" {
  capabilities = ["read", "list"]
}
EOF
else
  vault policy write minio-policy - << 'EOF'
path "secret/data/minio" {
  capabilities = ["read"]
}
path "secret/metadata/minio" {
  capabilities = ["read", "list"]
}
EOF
fi

echo "📜 Writing ACL policy: argocd-policy..."
if [[ "${USE_KUBECTL}" == "true" ]]; then
  kubectl exec -i -n "${VAULT_NAMESPACE}" "${VAULT_POD}" -- env VAULT_TOKEN="${VAULT_TOKEN:-}" vault policy write argocd-policy - << 'EOF'
path "secret/data/argocd/*" {
  capabilities = ["read"]
}
path "secret/metadata/argocd/*" {
  capabilities = ["read", "list"]
}
EOF
else
  vault policy write argocd-policy - << 'EOF'
path "secret/data/argocd/*" {
  capabilities = ["read"]
}
path "secret/metadata/argocd/*" {
  capabilities = ["read", "list"]
}
EOF
fi

# ------------------------------------------------------------------------------
# 6. Bind Kubernetes Auth Roles
# ------------------------------------------------------------------------------
echo "🔗 Binding Kubernetes auth role: poke-db..."
vault_cmd write auth/kubernetes/role/poke-db \
  bound_service_account_names=poke-db-sa \
  bound_service_account_namespaces=poke-db,poke-db-pr-*,default \
  policies=poke-db-policy \
  ttl=1h

echo "🔗 Binding Kubernetes auth role: minio..."
vault_cmd write auth/kubernetes/role/minio \
  bound_service_account_names=default,minio-sa \
  bound_service_account_namespaces=minio \
  policies=minio-policy \
  ttl=1h

echo "🔗 Binding Kubernetes auth role: argocd..."
vault_cmd write auth/kubernetes/role/argocd \
  bound_service_account_names=default,argocd-sa,argocd-notifications-controller \
  bound_service_account_namespaces=argocd \
  policies=argocd-policy \
  ttl=1h

# ------------------------------------------------------------------------------
# 7. Seed Initial Baseline Secrets
# ------------------------------------------------------------------------------
echo "🌱 Seeding baseline secret: secret/poke-db/api..."
vault_cmd kv put -mount=secret poke-db/api \
  DB_PASSWORD="postgres"

echo "🌱 Seeding baseline secret: secret/poke-db/postgres..."
vault_cmd kv put -mount=secret poke-db/postgres \
  POSTGRES_PASSWORD="postgres"

echo "🌱 Seeding baseline secret: secret/minio..."
vault_cmd kv put -mount=secret minio \
  MINIO_ROOT_USER="minioadmin" \
  MINIO_ROOT_PASSWORD="minioadminpassword"

echo "🌱 Seeding baseline secret: secret/argocd/notifications..."
vault_cmd kv put -mount=secret argocd/notifications \
  github-app-id="12345" \
  github-installation-id="67890" \
  github-private-key="-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0...\n-----END RSA PRIVATE KEY-----"

echo ""
echo "================================================================="
echo "🎉 HashiCorp Vault initialization and bootstrapping complete!"
echo "================================================================="
