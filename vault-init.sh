#!/bin/bash

set -e

VAULT_ADDR="http://localhost:8200"
VAULT_TOKEN="root"

echo "[*] Waiting for Vault to become ready..."
for i in {1..30}; do
    if curl -s -o /dev/null -w "%{http_code}" "$VAULT_ADDR/v1/sys/health" | grep -qE "^(200|429|472|473|501|503)$"; then
        echo "[✓] Vault is responding"
        break
    fi
    echo "    Attempt $i/30 — waiting..."
    sleep 2
done

export VAULT_ADDR="$VAULT_ADDR"
export VAULT_TOKEN="$VAULT_TOKEN"

echo ""
echo "[*] Checking Vault status..."
vault status

echo ""
echo "[*] Enabling KV secrets engine v2 at 'secret/' path..."
# In dev mode, secret/ is already enabled — this may return an error which is safe to ignore
vault secrets enable -path=secret kv-v2 2>/dev/null || echo "    (secret/ engine already enabled — continuing)"

echo ""
echo "[*] Writing initial database secret to Vault..."
vault kv put secret/db \
    password="Vault_Managed_P@ssw0rd_v1" \
    username="appuser" \
    host="postgres" \
    port="5432" \
    database="appdb"

echo ""
echo "[*] Verifying secret was written..."
vault kv get secret/db

echo ""
echo "[*] Creating a read-only policy for the application..."
vault policy write app-db-readonly - << 'POLICY'
# Policy: app-db-readonly
# Purpose: Allows an application to read database credentials
# This application token cannot write, list other paths, or manage policies

path "secret/data/db" {
  capabilities = ["read"]
}

path "secret/metadata/db" {
  capabilities = ["read"]
}
POLICY

echo "[✓] Policy created: app-db-readonly"

echo ""
echo "[*] Creating an application-specific token with the read-only policy..."
APP_TOKEN=$(vault token create \
    -policy="app-db-readonly" \
    -display-name="payment-app" \
    -ttl="24h" \
    -format=json | jq -r '.auth.client_token')

echo "[✓] Application token created"
echo ""
echo "════════════════════════════════════════════════════════"
echo " Vault Initialization Complete"
echo "════════════════════════════════════════════════════════"
echo " Vault UI        : http://localhost:8200"
echo " Root token      : root"
echo " App token       : $APP_TOKEN"
echo " Secret path     : secret/db"
echo " Policy          : app-db-readonly"
echo "════════════════════════════════════════════════════════"
echo ""
echo " App token capabilities (read-only — cannot write or list):"
vault token capabilities "$APP_TOKEN" secret/data/db
echo ""
echo " Root token capabilities (full access):"
vault token capabilities root secret/data/db
echo ""
echo " Save the app token — you will use it in the lab"
echo " APP_TOKEN=$APP_TOKEN"
