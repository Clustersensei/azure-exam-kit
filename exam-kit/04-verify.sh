#!/bin/bash
# ============================================================
#  04 - VERIFY / DIAGNOSE
#  Run any time. Prints the state of every layer, in the order
#  you should check them when something breaks.
#  Usage: source vars.env && bash 04-verify.sh
# ============================================================
[ -z "$P" ] && { echo "run: source vars.env first"; exit 1; }

kube () { az vm run-command invoke -g "$WORK_RG" -n "$VM" --command-id RunShellScript \
          --scripts "export HOME=/root; export KUBECONFIG=/root/.kube/config; $1" \
          --query 'value[0].message' -o tsv; }

echo "=============== IDENTITY ==============="
echo "ARM_CLIENT_ID = ${ARM_CLIENT_ID:-(EMPTY - terraform will silently use your az login!)}"
az account show --query "{sub:name, user:user.name}" -o tsv

echo
echo "=============== POLICY ================="
az policy assignment list --query "[].{name:name, display:displayName}" -o table

echo
echo "=============== NETWORK ================"
az network vnet subnet list -g "$WORK_RG" --vnet-name "$VNET" \
  --query "[].{name:name, prefix:addressPrefix, delegation:delegations[0].serviceName, nsg:networkSecurityGroup.id}" -o table

echo
echo "--- NSG rules (rule 100 MUST allow 80,443 from Internet) ---"
az network nsg rule list -g "$WORK_RG" --nsg-name "nsg-${P}-aks-node" \
  --query "[].{name:name, pri:priority, ports:destinationPortRanges, port:destinationPortRange, src:sourceAddressPrefix, access:access}" -o table 2>/dev/null

echo
echo "=============== PUBLIC IPs (cap is 3 per region!) ==============="
az network public-ip list --query "[].{name:name, ip:ipAddress, rg:resourceGroup}" -o table

echo
echo "=============== ACR IMAGES ============="
if [ -n "$ACR" ]; then
  for r in backend frontend todo; do
    echo -n "$r: "; az acr repository show-tags --name "$ACR" --repository "$r" -o tsv 2>/dev/null | tr '\n' ' '; echo
  done
fi

echo
echo "=============== POSTGRES ==============="
az postgres flexible-server show -g "$WORK_RG" -n "$PG" \
  --query "{fqdn:fullyQualifiedDomainName, public:network.publicNetworkAccess, state:state}" -o table 2>/dev/null

echo
echo "=============== ACI ===================="
az container show -g "$WORK_RG" -n "aci-${P}-backend" \
  --query "{prov:provisioningState, state:containers[0].instanceView.currentState.state, ip:ipAddress.ip}" -o table 2>/dev/null
echo "--- env var NAMES (must be DBUSERNAME, not DBUSER) ---"
az container show -g "$WORK_RG" -n "aci-${P}-backend" \
  --query "containers[0].environmentVariables[].name" -o tsv 2>/dev/null | tr '\n' ' '; echo

echo
echo "=============== CLUSTER ================"
kube "kubectl get nodes -o wide; echo; kubectl get all,ingress -n employee-todo; echo; flux get kustomizations -A"

echo
echo "=============== LOAD BALANCER =========="
MCRG=$(az aks show -g "$WORK_RG" -n "$AKS" --query nodeResourceGroup -o tsv 2>/dev/null)
if [ -n "$MCRG" ]; then
  echo "--- probes: path MUST return 200 on the NodePort (/healthz and / both 404!) ---"
  az network lb probe list -g "$MCRG" --lb-name kubernetes \
    --query "[].{proto:protocol, port:port, path:requestPath}" -o table 2>/dev/null
fi

echo
echo "=============== END TO END ============="
if [ -n "$INGRESS_IP" ]; then
  for p in /to-do/ /emp/; do
    echo -n "$p -> "; curl -s -m 10 -o /dev/null -w "%{http_code}\n" "http://$INGRESS_IP$p"
  done
  echo -n "backend  -> "
  curl -s -m 10 -X POST "http://$INGRESS_IP/emp/api/v1/employees/findEmployees" \
    -H "Content-Type: application/json" -d '{}'; echo
else
  echo "(set INGRESS_IP in vars.env)"
fi

cat <<'TIPS'

=============== IF SOMETHING IS BROKEN ===============
000 / hangs from the public IP  -> load balancer. Split the path:
    curl http://<nodeIP>:<nodePort>/to-do/     from the jumphost
    200 there + 000 publicly = LB probe is failing. Check the probe PATH
    returns 200 by curling it yourself. /healthz and / both 404 on nginx.

EXTERNAL-IP <pending>           -> kubectl describe svc ... -n ingress-nginx | tail -30
                                   (PublicIPCountLimitReached = the 3-IP cap)

Pod ImagePullBackOff            -> AcrPull on kubelet_identity, not the cluster identity

Postgres 28P01 auth_failed      -> could be the USERNAME, not the password.
                                   Test the credential directly, bypassing the app:
    docker run --rm -e PGPASSWORD="$PW" postgres:14 psql -h <fqdn> -U pgadminuser -d employeeapp -c 'select 1;'
                                   Then read config/dbConfig.js for the real env var names.

Key Vault 403 as yourself       -> az runs as your personal login (appid 04b07795-...),
                                   which has no data-plane role. Grant it:
    az role assignment create --assignee-object-id $(az ad signed-in-user show --query id -o tsv) \
      --assignee-principal-type User --role "Key Vault Secrets Officer" \
      --scope $(az keyvault show -n <kv> --query id -o tsv)

kubectl "localhost:8080 refused" -> export HOME=/root AND export KUBECONFIG=/root/.kube/config

Flux applied but object missing  -> it isn't listed in kustomization.yaml resources:

terraform state lock stuck       -> ps aux | grep terraform  FIRST, then force-unlock <ID>

RequestDisallowedByPolicy        -> missing tags. AKS needs a tags block INSIDE
                                    default_node_pool (cluster tags don't reach the VMSS).
TIPS
