#!/bin/bash
# ============================================================
#  03 - JUMPHOST SETUP
#  Installs tooling, wires kubeconfig, registers the ADO agent.
#  Runs entirely through `az vm run-command` - no Bastion, no SSH,
#  no network path to the VM required.
#
#  Usage:
#     source vars.env
#     source ~/spn.env
#     read -s -p "PAT: " ADO_PAT; echo      # <-- RUN THIS LINE ALONE
#     bash 03-jumphost.sh
# ============================================================
set -e
[ -z "$P" ]           && { echo "run: source vars.env first"; exit 1; }
[ -z "$ARM_CLIENT_ID" ] && { echo "run: source ~/spn.env first"; exit 1; }
[ -z "$ADO_PAT" ]     && { echo "run: read -s -p 'PAT: ' ADO_PAT   (on its own line)"; exit 1; }

run () { az vm run-command invoke -g "$WORK_RG" -n "$VM" --command-id RunShellScript --scripts "$@"; }

# ---- 0. outbound works? (NAT gateway test - everything depends on it) ----
echo ">>> outbound check (want 200)"
run "curl -sS -m 10 -o /dev/null -w '%{http_code}' https://packages.microsoft.com"

# ---- 1. tooling -----------------------------------------------------
cat > /tmp/tools.sh <<'EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl unzip git apt-transport-https ca-certificates gnupg lsb-release

curl -sL https://aka.ms/InstallAzureCLIDeb | bash

curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl

curl -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -sL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
apt-get update && apt-get install -y terraform

curl -fsSL https://get.docker.com | sh
usermod -aG docker azureuser

# Node is NOT preinstalled on a self-hosted agent; the backend pipeline needs npm
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

curl -sL https://fluxcd.io/install.sh | bash

echo "=== versions ==="
az version --query '"azure-cli"' -o tsv
kubectl version --client -o yaml | head -3
helm version --short
terraform version | head -1
docker --version
node --version; npm --version
flux --version
EOF
echo ">>> installing tooling (3-5 min, silent)"
run @/tmp/tools.sh

# ---- 2. kubeconfig for the private cluster --------------------------
cat > /tmp/kube.sh <<EOF
#!/bin/bash
set -e
az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID" >/dev/null
az account set -s "$ARM_SUBSCRIPTION_ID"
az aks get-credentials -g $WORK_RG -n $AKS --overwrite-existing
export KUBECONFIG=/root/.kube/config
kubectl get nodes -o wide
EOF
echo ">>> wiring kubeconfig"
run @/tmp/kube.sh
rm -f /tmp/kube.sh

# ---- 3. ADO agent ---------------------------------------------------
# Get the download URL from ADO itself. The old vstsagentpackage.azurewebsites.net
# host 404s, and curl|tar hides that as a bogus gzip error.
AGENT_URL=$(curl -s -u ":$ADO_PAT" \
  "https://dev.azure.com/$ADO_ORG/_apis/distributedtask/packages/agent?platform=linux-x64&api-version=7.1" \
  | grep -o '"downloadUrl":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -z "$AGENT_URL" ] && { echo "could not resolve agent URL - check the PAT"; exit 1; }
echo ">>> agent: $AGENT_URL"

cat > /tmp/agent.sh <<EOF
#!/bin/bash
set -e
export AGENT_ALLOW_RUNASROOT="1"   # run-command executes as root
rm -rf /opt/azagent && mkdir -p /opt/azagent && cd /opt/azagent
curl -sL "$AGENT_URL" -o agent.tar.gz
file agent.tar.gz                  # must say "gzip compressed data"
tar xzf agent.tar.gz && rm -f agent.tar.gz

./config.sh --unattended \
  --url "https://dev.azure.com/$ADO_ORG" \
  --auth pat --token "$ADO_PAT" \
  --pool "$AGENT_POOL" --agent "$AGENT_NAME" \
  --work "_work" --acceptTeeEula --replace

./svc.sh install && ./svc.sh start && ./svc.sh status | head -5
EOF
echo ">>> registering agent"
run @/tmp/agent.sh
rm -f /tmp/agent.sh /tmp/tools.sh

echo
echo "DONE. Check ADO -> Project settings -> Agent pools -> $AGENT_POOL shows Online."
echo "If you later install a tool on the VM, RESTART the agent or it won't see it:"
echo "  az vm run-command invoke -g $WORK_RG -n $VM --command-id RunShellScript \\"
echo "    --scripts 'cd /opt/azagent && ./svc.sh stop && ./svc.sh start'"
