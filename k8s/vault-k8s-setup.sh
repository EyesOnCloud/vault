#!/bin/bash

set -e

VAULT_ADDR="http://localhost:8200"
VAULT_TOKEN="root"

export VAULT_ADDR VAULT_TOKEN

echo "[*] Configuring Vault for Kubernetes authentication"
echo "[*] This connects your self-managed cluster to Vault"

# ── Step 1: Enable Kubernetes auth method ─────────────────────────────────────
echo ""
echo "[*] Enabling Kubernetes auth method in Vault..."
vault auth enable kubernetes 2>/dev/null || echo "    (kubernetes auth already enabled)"

# ── Step 2: Get Kubernetes API server address ─────────────────────────────────
K8S_HOST=$(kubectl config view --raw --minify --flatten \
    -o jsonpath='{.clusters[0].cluster.server}')
echo "[✓] Kubernetes API server: $K8S_HOST"

# ── Step 3: Get the service account JWT and CA cert ───────────────────────────
K8S_CA_CERT=$(kubectl config view --raw --minify --flatten \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode)

# Create a dedicated service account for Vault's token review
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth
  namespace: default
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: default
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
---
apiVersion/rbac.authorization.k8s.io/v1: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-auth-tokenreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-auth
    namespace: default
EOF

sleep 3

SA_JWT=$(kubectl get secret vault-auth-token -o jsonpath='{.data.token}' | base64 --decode)

# ── Step 4: Configure Kubernetes auth in Vault ────────────────────────────────
echo ""
echo "[*] Configuring Vault Kubernetes auth backend..."
vault write auth/kubernetes/config \
    token_reviewer_jwt="$SA_JWT" \
    kubernetes_host="$K8S_HOST" \
    kubernetes_ca_cert="$K8S_CA_CERT" \
    issuer="https://kubernetes.default.svc.cluster.local"

echo "[✓] Kubernetes auth configured"

# ── Step 5: Create Vault role for the application ─────────────────────────────
echo ""
echo "[*] Creating Vault role for payment-app service account..."
vault write auth/kubernetes/role/payment-app \
    bound_service_account_names=payment-app \
    bound_service_account_namespaces=default \
    policies=app-db-readonly \
    ttl=1h

echo "[✓] Vault role created: payment-app"

# ── Step 6: Install Vault Agent Injector via Helm ─────────────────────────────
echo ""
echo "[*] Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

echo "[*] Installing Vault Agent Injector (external Vault mode)..."
helm install vault-agent hashicorp/vault \
    --namespace default \
    --set "injector.enabled=true" \
    --set "server.enabled=false" \
    --set "injector.externalVaultAddr=http://$(hostname -I | awk '{print $1}'):8200"

echo "[✓] Vault Agent Injector installed"

echo ""
echo "════════════════════════════════════════════════════════"
echo " Kubernetes + Vault Configuration Complete"
echo "════════════════════════════════════════════════════════"
echo " Vault address for cluster : http://$(hostname -I | awk '{print $1}'):8200"
echo " Auth method               : kubernetes"
echo " Vault role                : payment-app"
echo " Bound service account     : payment-app / default namespace"
echo " Policy                    : app-db-readonly"
echo "════════════════════════════════════════════════════════"
