#!/bin/bash
# ============================================================
#  01 - BOOTSTRAP  (run on the exam VM, ~5 min)
#  Creates: tfstate RG + storage + container, SPN, ~/spn.env
#  Prereq:  az login   (device code if no browser)
#  Usage:   source vars.env && bash 01-bootstrap.sh
# ============================================================
set -e

[ -z "$P" ] && { echo "run: source vars.env first"; exit 1; }

# ---- 0. tooling on the WORK vm (skip if already present) -----------
command -v az >/dev/null        || curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
command -v terraform >/dev/null || {
  curl -sL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list
  sudo apt-get update && sudo apt-get install -y terraform
}

# ---- shared provider cache: 6 modules x 250MB will fill a small disk
mkdir -p ~/.terraform.d/plugin-cache
grep -q plugin_cache_dir ~/.terraformrc 2>/dev/null || \
  echo 'plugin_cache_dir = "$HOME/.terraform.d/plugin-cache"' >> ~/.terraformrc

# ---- 1. subscription --------------------------------------------
[ -z "$SUB_ID" ] && export SUB_ID=$(az account show --query id -o tsv)
az account set -s "$SUB_ID"
echo "SUB_ID=$SUB_ID"

# ---- 2. state backend -------------------------------------------
az group create --name "$TFSTATE_RG" --location "$LOC" -o none

az storage account create \
  --name "$TFSTATE_SA" \
  --resource-group "$TFSTATE_RG" \
  --location "$LOC" \
  --sku Standard_LRS \
  -o none

KEY=$(az storage account keys list -g "$TFSTATE_RG" -n "$TFSTATE_SA" --query '[0].value' -o tsv)

az storage container create \
  --name "$TFSTATE_CONTAINER" \
  --account-name "$TFSTATE_SA" \
  --account-key "$KEY" \
  -o none

# ---- 3. service principal ---------------------------------------
# Owner (not Contributor): Contributor excludes Microsoft.Authorization/*,
# which we need for policy assignments AND role assignments.
SP=$(az ad sp create-for-rbac \
      --name "$SPN_NAME" \
      --role Owner \
      --scopes "/subscriptions/$SUB_ID" -o json)

APP_ID=$(echo "$SP"   | python3 -c 'import sys,json;print(json.load(sys.stdin)["appId"])')
SECRET=$(echo "$SP"   | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')
TENANT=$(echo "$SP"   | python3 -c 'import sys,json;print(json.load(sys.stdin)["tenant"])')

# ---- 4. env file -------------------------------------------------
cat > ~/spn.env <<ENVEOF
export ARM_CLIENT_ID="$APP_ID"
export ARM_CLIENT_SECRET="$SECRET"
export ARM_TENANT_ID="$TENANT"
export ARM_SUBSCRIPTION_ID="$SUB_ID"
export ARM_ACCESS_KEY="$KEY"
ENVEOF
chmod 600 ~/spn.env
grep -q 'source ~/spn.env' ~/.bashrc || echo 'source ~/spn.env' >> ~/.bashrc
source ~/spn.env

echo
echo "=================== SAVE THESE ==================="
echo "SUB_ID    : $SUB_ID"
echo "TENANT    : $TENANT"
echo "APP_ID    : $APP_ID"
echo "SECRET    : (in ~/spn.env, chmod 600)"
echo "TFSTATE   : $TFSTATE_RG / $TFSTATE_SA / $TFSTATE_CONTAINER"
echo "=================================================="
echo
echo "Sanity check (MUST be non-empty before every terraform run):"
echo "  echo \$ARM_CLIENT_ID  ->  $ARM_CLIENT_ID"
echo
echo "NEXT: put TFSTATE_SA=$TFSTATE_SA into vars.env, then run 02-generate.sh"
