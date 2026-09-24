#!/usr/bin/env bash
# One-time setup. Run in Azure Cloud Shell (Bash).
set -euo pipefail

# ---- Change these two if needed ----
GITHUB_REPO="NaveenKumarS546/azure-secure-network"   # owner/repo on GitHub
LOCATION="australiaeast"
# ------------------------------------

RG="rg-secure-net"
APP_NAME="gh-azure-secure-network"
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "1) Resource group"
az group create -n "$RG" -l "$LOCATION" -o none

echo "2) App registration + service principal for GitHub (OIDC, no secrets)"
APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
az ad sp create --id "$APP_ID" -o none || true

echo "3) Contributor on THIS resource group only (least privilege)"
az role assignment create \
  --assignee "$APP_ID" \
  --role Contributor \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" -o none

echo "4) Trust GitHub: pushes to main + pull requests"
az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"main-branch\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:${GITHUB_REPO}:ref:refs/heads/main\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}" -o none
az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"pull-requests\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:${GITHUB_REPO}:pull_request\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}" -o none

echo "5) SSH key for the test VM"
[ -f ~/.ssh/secnet ] || ssh-keygen -t rsa -b 4096 -f ~/.ssh/secnet -N "" -q

echo
echo "===== Add these as GitHub repo secrets ====="
echo "AZURE_CLIENT_ID       = $APP_ID"
echo "AZURE_TENANT_ID       = $TENANT_ID"
echo "AZURE_SUBSCRIPTION_ID = $SUB_ID"
echo "VM_SSH_PUBLIC_KEY     = (the line below)"
cat ~/.ssh/secnet.pub
