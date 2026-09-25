# Command Log — lne_* rebuild

Running log of every command used, in order. Bootstrap steps are manual (Terraform
can't create its own state backend); everything after is Terraform/pipelines.

Naming convention: `lne` prefix. Note underscores/hyphens are illegal in some
Azure resource names (storage accounts, ACR = lowercase alphanumeric only).

Subscription: `bbd5fc57-18a7-434d-92fd-7e1543095ede`
Region: `centralindia`

---

## 0. Discovery techniques (no-AI, closed-book)

```bash
az --help                          # walk the command tree
az storage --help
az storage account create --help   # required params + Examples section at bottom
az find "storage container"        # search commands by keyword
```

Naming pattern is regular: `az <service> <object> <verb>`.

---

## 1. Terraform state backend (manual bootstrap)

```bash
# Resource group
az group create \
  --name lne-employee-to-do-rg \
  --location centralindia

# Storage account (name: 3-24 chars, lowercase letters + numbers ONLY)
az storage account create \
  --name tfstate300 \
  --resource-group lne-employee-to-do-rg

# Interactive default was Standard_RAGRS (geo-redundant). Downgrade to LRS.
az storage account update \
  -n tfstate300 \
  -g lne-employee-to-do-rg \
  --sku Standard_LRS

# Data-plane key (this becomes ARM_ACCESS_KEY for the Terraform backend)
KEY=$(az storage account keys list \
  -g lne-employee-to-do-rg \
  -n tfstate300 \
  --query '[0].value' -o tsv)

# Blob container to hold the *.tfstate blobs
az storage container create \
  --name tfstate \
  --account-name tfstate300 \
  --account-key "$KEY"
```

### Notes
- **Control plane vs data plane.** `az group create` / `az storage account create`
  hit `management.azure.com` (ARM) — your `az login` identity is authorized there.
  `az storage container create` hits `tfstate300.blob.core.windows.net` — a
  separate authorization system. Being subscription Owner does NOT grant blob
  access. Hence `--account-key` (or `--auth-mode login` + the
  `Storage Blob Data Contributor` role).
- **Always read the defaults Azure picked.** The create succeeded but silently
  chose a geo-redundant SKU.
- `--n` is not a real flag; it's `-n` or `--name` (worked only by prefix match).

### Backend values for Terraform
| Terraform arg          | Value                   |
|------------------------|-------------------------|
| `resource_group_name`  | `lne-employee-to-do-rg` |
| `storage_account_name` | `tfstate300`            |
| `container_name`       | `tfstate`               |
| `key`                  | `<module>.tfstate`      |
| `ARM_ACCESS_KEY`       | value of `$KEY` above   |

---

## 2. Azure DevOps

- Organization: `galaxyblaster`
- Project: `lne-employee-todo`
- Repo cloned onto the working VM; `terraform/` directory created inside it.

---

<!-- Append new sections below as work proceeds. -->

## 3. Service principal (manual bootstrap)

Create BEFORE any `terraform apply` — building as your personal `az login` user and
switching later leaves wrong-principal role assignments behind.

```bash
az ad sp create-for-rbac \
  --name "sp-lne-employee-todo" \
  --role "Owner" \
  --scopes "/subscriptions/bbd5fc57-18a7-434d-92fd-7e1543095ede"
```

Output (password shown ONCE, unrecoverable):
`appId` → ARM_CLIENT_ID, `password` → ARM_CLIENT_SECRET, `tenant` → ARM_TENANT_ID

### Notes
- `create-for-rbac` does **two** things: creates the app registration + SPN
  (identity), and creates a role assignment (authorization). Independent — an SPN
  with no role assignment authenticates fine and 403s on everything.
- **Why `Owner`, not `Contributor`:** Contributor excludes `Microsoft.Authorization/*`
  via NotActions. We need `policyAssignments/write` (policy module) and
  `roleAssignments/write` (AcrPull → kubelet identity, AcrPull → ACI identity,
  Key Vault Secrets Officer). Least-privilege alternative =
  `Contributor` + `User Access Administrator`.
- **Why subscription scope:** `azurerm_subscription_policy_assignment` writes at
  subscription level. RG scope would be enough for everything else.
- "Insufficient privileges" here is usually an **Entra ID directory** setting
  ("Users can register applications"), not Azure RBAC — separate permission system.

### Env file

```bash
cat > ~/spn.env << 'ENVEOF'
export ARM_CLIENT_ID="<appId>"
export ARM_CLIENT_SECRET="<password>"
export ARM_TENANT_ID="<tenant>"
export ARM_SUBSCRIPTION_ID="bbd5fc57-18a7-434d-92fd-7e1543095ede"
export ARM_ACCESS_KEY="<storage key from phase 1>"
ENVEOF

chmod 600 ~/spn.env
echo 'source ~/spn.env' >> ~/.bashrc
source ~/spn.env
echo $ARM_CLIENT_ID          # MUST be non-empty before every apply
```

- `ARM_*` vars steer **Terraform's azurerm provider only** — they have zero effect
  on the `az` CLI, whose identity comes solely from `az login`. The two can
  disagree, which is exactly how the silent-fallback bug hides.
- `ARM_ACCESS_KEY` authenticates the **backend** (state blob, data plane); the
  other four authenticate the **provider** (resource creation, control plane).

---

## 4. Terraform — network module

```hcl
locals {
  location = "centralindia"
  tags = {
    "Business Unit" = "Engineering"
    "Cost Center"   = "CC-1001"
  }
}

resource "azurerm_resource_group" "main" {
  name     = "rg-lne-employee-todo"
  location = local.location
  tags     = local.tags
}
```

- Workload RG is **separate** from the tfstate RG so `terraform destroy` can never
  delete the state it is reading from.
- **Tags do not inherit** from RG to resources — every resource needs its own block.
- `locals` are per-directory; each module needs its own copy.

### VNet

```hcl
resource "azurerm_virtual_network" "main" {
  name                = "vnet-lne-employee-todo"
  address_space       = ["10.0.0.0/16"]
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}
```

- `/16` chosen for clean `/24` carving, not capacity.
- **AKS `service_cidr` must NOT overlap the VNet.** Reserved for platform module:
  `service_cidr = "10.1.0.0/16"`, `dns_service_ip = "10.1.0.10"`.
- Address space can be added to later, but never changed/shrunk once subnets exist.

### Subnet address plan

| Subnet               | CIDR           | Special |
|----------------------|----------------|---------|
| `snet-aks-node`      | 10.0.1.0/24    | — |
| `snet-pe`            | 10.0.2.0/24    | PE network policies disabled |
| `snet-aci`           | 10.0.3.0/24    | delegated: ContainerInstance |
| `snet-postgres`      | 10.0.4.0/24    | delegated: DBforPostgreSQL |
| `AzureBastionSubnet` | 10.0.5.0/26    | name is API-enforced, /26 minimum |

### NSG (the port-80 lesson)

```hcl
resource "azurerm_network_security_group" "aks_node" {
  # rule 100: allow 80,443 from Internet   <-- THE critical one
  # rule 200: allow 30000-32767 (NodePort, for jump-host debugging)
}

resource "azurerm_subnet_network_security_group_association" "aks_node" {
  subnet_id                 = azurerm_subnet.aks_node.id
  network_security_group_id = azurerm_network_security_group.aks_node.id
}
```

- AKS LB sets **`EnableFloatingIP = True`** (DSR) → the LB does **not** rewrite the
  destination port. Real traffic reaches the node on **80**; health probes reach it
  on the **NodePort**. Allowing only 30000-32767 → probes green, LB "healthy",
  every real request silently dropped. Cost hours last build.
- Generalised lesson: **a passing health check proves the health-check path, not the
  data path.** Different port/protocol/source = genuinely independent paths.
- NSG and association are **separate resources**; an unattached NSG filters nothing.
- Invisible default rules: 65000 `AllowVnetInBound` (why intra-VNet just works),
  65001 `AllowAzureLoadBalancerInBound`, 65500 `DenyAllInBound`. Lower number wins.
- AKS also creates its **own NIC-level NSG** in the `MC_*` RG. Both must pass.
- No NSG on `AzureBastionSubnet` (needs a precise rule set; a wrong one breaks it).

### Verify

```bash
az network vnet subnet list -g rg-lne-employee-todo \
  --vnet-name vnet-lne-employee-todo \
  --query "[].{name:name, prefix:addressPrefix, delegation:delegations[0].serviceName}" \
  -o table
```

---

## 5. Terraform — policy module (`policy.tfstate`)

Three definitions → four assignments. Uses `variables.tf` + `terraform.tfvars`
(commit the tfvars — it is config, not secrets; the pipeline needs it).

```hcl
resource "azurerm_subscription_policy_assignment" "require_tag" {
  for_each             = toset(var.mandatory_tags)
  name                 = "req-tag-${replace(lower(each.value), " ", "-")}"
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99"
  subscription_id      = data.azurerm_subscription.current.id
  parameters = jsonencode({ tagName = { value = each.value } })
}
```

Built-in definition GUIDs:
| Policy | GUID |
|---|---|
| Require a tag on resources | `871b6d14-10aa-478d-b590-94f262ecfa99` |
| NICs should not have public IPs | `83a86a26-fd1f-447c-b59d-e51f44264114` |
| Allowed locations | `e56962a6-4747-49cd-b67b-bf8b01975c4c` |

### Notes
- **Definition** (the rule, inert) vs **initiative** (a bundle) vs **assignment**
  (definition + scope + parameters — the thing with teeth). We create assignments
  only; the definitions are Microsoft built-ins.
- **Two tags = two assignments.** The built-in takes a single `tagName` param, no
  list form. Hence `for_each = toset(...)`.
- Azure's parameter shape is `{"param": {"value": X}}` — the `{ value = }` wrapper
  is the API's, not Terraform's. Omitting it gives a misleading type error.
- Assignment `name` caps at **24 characters** (API-enforced).
- Assignments evaluate **at write time, not retroactively** — existing resources
  survive but report non-compliant. Propagation delay: minutes, up to ~30.
- Find a GUID closed-book:
  `az policy definition list --query "[?contains(displayName,'Require a tag')].{name:name,display:displayName}" -o table`

### Coming trap
Once live, everything needs both tags. AKS is the non-obvious one: **cluster-level
`tags` do NOT propagate to the auto-created `MC_*` node resource group / VMSS** —
needs its own `tags` block inside `default_node_pool`.

### Verify
```bash
az policy assignment list --query "[].{name:name, display:displayName}" -o table
```
(`SecurityCenterBuiltIn` / "ASC Default" is Azure's own, not ours.)

---

## 6. Disk exhaustion — Terraform plugin cache

**Symptom:** `terraform init` → `Error while installing hashicorp/azurerm: no space
left on device`. The VM root disk was 6.7 G, 100% full.

**Cause:** the azurerm provider binary is ~223 MB and Terraform downloads a
**private copy per module directory**. Nine `.terraform` dirs across two repos =
~1.9 GB of identical binaries.

```bash
# diagnose
df -h /
du -sh ~/* 2>/dev/null | sort -h | tail -20
find ~ -type d -name ".terraform" -exec du -sh {} \;

# reclaim (safe — state lives in Azure Blob, .terraform is disposable cache)
find ~ -type d -name ".terraform" -prune -exec rm -rf {} +

# prevent recurrence: one shared copy, hard-linked into each module
mkdir -p ~/.terraform.d/plugin-cache
cat > ~/.terraformrc << 'RCEOF'
plugin_cache_dir = "$HOME/.terraform.d/plugin-cache"
RCEOF
# ($HOME stays literal in the file; Terraform expands it)

# re-init each module
cd terraform/network && terraform init
cd ../policy && terraform init
cd ../platform && terraform init
```

Result: cache 241 MB once; each module's `.terraform` drops to ~32 KB.

### Notes
- Disk exhaustion rarely announces itself — it surfaces as failed writes, corrupt
  downloads, agents dropping offline. **Make `df -h` an early reflex** when
  something behaves inexplicably.
- Exam VMs are small and will also carry Docker images, the self-hosted ADO agent,
  and Helm charts. Set the plugin cache up on day one.

---

## 7. Terraform — platform, postgres, jumphost

Names generated this run: ACR `acrlnehpvmb5`, Key Vault `kv-lne-hpvmb5`,
AKS `aks-lne-employee-todo`, Postgres `psql-lne-employee-todo`.

### Platform traps
- `default_node_pool` needs its **own `tags` block** — cluster tags do NOT reach the
  auto-created `MC_*` RG / VMSS, so the tag policy rejects the VMSS.
- `AcrPull` goes to **`kubelet_identity[0].object_id`**, not `identity[0].principal_id`.
  Kubelet pulls images; the cluster identity manages LBs/routes. Wrong one =
  `ImagePullBackOff` with a role assignment that looks correct.
- `private_dns_zone_id = "System"` → AKS manages its own `privatelink.<region>.azmk8s.io`.
- Three CIDRs must not overlap: VNet `10.0.0.0/16`, pod `10.244.0.0/16` (kubenet
  default), service `10.1.0.0/16` (+ `dns_service_ip = 10.1.0.10`).
- `Standard_D2s_v3` is often quota-blocked → `Standard_D2s_v5`. The error lists the
  allowed sizes; read it rather than guessing.
- Key Vault: `enable_rbac_authorization = true` → creating the vault grants NO data
  access. Needs an explicit `Key Vault Secrets Officer` assignment (Officer = rw,
  User = read-only; `User` cannot delete secrets, which breaks `destroy`).
- `purge_protection_enabled = false` for a rebuildable practice env.
- ACR/KV/storage names are **globally unique** → `random_string` suffix.

### Postgres traps
- `administrator_login` cannot be `admin`/`root`/`guest`/`public` or start with `pg_`.
- VNet-integrated mode = `public_network_access_enabled = false` +
  `delegated_subnet_id` + `private_dns_zone_id`, all three together.
- Azure Postgres **forces SSL** → the Node backend needs `dialectOptions.ssl` later.
- Password lands in `postgres.tfstate` in plaintext → state container stays private.

### Jumphost
- Bastion needs a **Standard + Static** public IP (standalone, not on a NIC, so the
  "no public IP on NIC" policy allows it). `timeouts { create = "45m" }`.
- **NAT gateway** (public IP + gateway + 2 associations) gives the no-public-IP VM
  outbound internet. Azure retired default outbound access; without it the VM cannot
  `apt install`, pull images, or register as an ADO agent.
- `vm_agent_platform_updates_enabled = true` — Azure sets it, provider defaults to
  false → perpetual 1-change diff. Declare the real value in config.

### Recovering a killed apply

```bash
ps aux | grep terraform                    # ALWAYS first
az network bastion show -g <rg> -n <name> --query provisioningState -o tsv
terraform state list                       # reads need no lock
terraform force-unlock <ID>                # ID comes from the failed command
terraform import azurerm_bastion_host.main "<full azure resource id>"
terraform plan                             # want: No changes
```

- Terraform writes state **per resource as each completes** — a killed process
  leaves state accurate but incomplete. It never resumes; waiting does nothing.
- **Run every long apply inside `tmux`** (`tmux new -s tf`, detach `Ctrl+B D`,
  `tmux attach -t tf`). AKS, Postgres and Bastion are all long enough to lose.

---

## 8. Jump host tooling + self-hosted ADO agent

### Prove outbound (NAT gateway test)
```bash
az vm run-command invoke -g rg-lne-employee-todo -n vm-lne-jumphost \
  --command-id RunShellScript \
  --scripts "curl -sS -m 10 -o /dev/null -w '%{http_code}' https://packages.microsoft.com"
```
Want `200`. Everything downstream depends on it.

### Install tooling
`~/install-tools.sh` installs az, kubectl, helm, terraform, docker, flux, then prints
a versions block. Run with `--scripts @~/install-tools.sh`.

### kubeconfig for the private cluster
```bash
az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID"
az aks get-credentials -g rg-lne-employee-todo -n aks-lne-employee-todo --overwrite-existing
export KUBECONFIG=/root/.kube/config
kubectl get nodes -o wide
```

### Agent registration
ADO UI first: Project settings → Agent pools → Add pool → **Self-hosted** →
`lne-vnet-agents`. Then a PAT with **Agent Pools: Read & manage** + **Code: Read & write**.

Get the agent URL from ADO itself, never guess it:
```bash
curl -s -u ":$ADO_PAT" \
  "https://dev.azure.com/galaxyblaster/_apis/distributedtask/packages/agent?platform=linux-x64&api-version=7.1"
```
→ `https://download.agent.dev.azure.com/agent/5.279.0/vsts-agent-linux-x64-5.279.0.tar.gz`

```bash
export AGENT_ALLOW_RUNASROOT="1"
mkdir -p /opt/azagent && cd /opt/azagent
curl -sL "$AGENT_URL" -o agent.tar.gz && file agent.tar.gz && tar xzf agent.tar.gz
./config.sh --unattended --url "https://dev.azure.com/galaxyblaster" --auth pat \
  --token "$ADO_PAT" --pool "lne-vnet-agents" --agent "lne-jumphost-agent" \
  --work "_work" --acceptTeeEula --replace
./svc.sh install && ./svc.sh start && ./svc.sh status
```

### Notes / gotchas
- **Why self-hosted:** the AKS API server is private. Microsoft-hosted agents are on
  the public network and physically cannot run kubectl/helm/flux against it.
- `az vm run-command` reaches the VM through the **Azure control plane + VM agent** —
  no network path, no Bastion, no SSH key, no open port. Use Bastion only for an
  interactive shell.
- **Heredoc quoting:** `<< 'EOF'` = literal (no expansion); `<< EOF` = expand local
  vars now. Getting it backwards gives silently empty values.
- **`read -s` inside a pasted multi-line block eats the next pasted line** as its
  input. Run `read` alone, then paste the rest. This silently broke a command.
- `curl | tar xz` hides HTTP failures — curl streams a 404 page and tar reports it as
  corruption. Download to a file, run `file` on it, then extract.
- The stale URL `vstsagentpackage.azurewebsites.net` 404s; the live host is
  `download.agent.dev.azure.com`. Query the ADO packages API instead of hardcoding.
- `AGENT_ALLOW_RUNASROOT=1` needed because run-command executes as root. Running as
  root also gives the agent `/root/.kube/config` and the Docker socket for free.
- `--replace` makes re-registration idempotent.
- **`HOME` is not reliably `/root`** in run-command or agent contexts → kubectl falls
  back to `localhost:8080` ("connection refused"). Always
  `export KUBECONFIG=/root/.kube/config` explicitly in scripts and pipelines.

---

## 9. Build pipelines → ACR

Three pipelines, same shape: `checkout: none` → `git clone` upstream into a throwaway
dir → `sed` patches → `AzureCLI@2` runs `az acr login` + `docker build/push`.

- **Patch the disposable clone, never the upstream repo.** The fix stays versioned in
  YOUR repo and is replayable.
- **End every `sed` step with `grep`.** sed exits 0 when it matches nothing — a failed
  patch is invisible until it surfaces as a runtime bug hours later.
- `AzureCLI@2` not `Docker@2`: ACR admin account is disabled, so there is no
  username/password — `az acr login` uses the service connection's `AcrPush`.
- Tag with `$(Build.BuildId)`, never `latest` — K8s can't detect that `latest` changed,
  so rollouts silently do nothing.

### Self-hosted agent reality
A hosted agent ships with Node/Python/Docker. Yours is bare Ubuntu — every tool must be
installed first, and you find out one `command not found` at a time. `npm` was missing:

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs
cd /opt/azagent && ./svc.sh stop && ./svc.sh start
```
**Restart the agent after installing a tool** — it caches its environment at start, so a
newly installed binary is invisible to running jobs until then.

### Which pipelines need the self-hosted agent
| Pipeline | Needs VNet? |
|---|---|
| frontend / backend / todo build | no — GitHub + ACR are public |
| nginx ingress (Helm), Flux | **yes** — private AKS API server |

The SPN is **credentials**; the NAT gateway is **connectivity**. Permission to call the
API server does not create a network path to it.

---

## 10. Ingress controller + the public IP quota

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz
```

- `export HOME=/root` **and** `export KUBECONFIG=/root/.kube/config` in every pipeline
  step — otherwise kubectl falls back to `localhost:8080` ("connection refused"), which
  reads like a cluster fault but is a path fault.
- Health-probe annotation: Azure LB probes `/` by default; nginx 404s that when no
  ingress matches → backend marked unhealthy → all traffic dropped. `/healthz` is
  nginx's always-200 endpoint.
- Poll for the IP; the LB takes 30-90 s to allocate one.

### `EXTERNAL-IP <pending>` — always read the events
```bash
kubectl describe svc ingress-nginx-controller -n ingress-nginx | tail -30
```
Real cause here: **`PublicIPCountLimitReached` — max 3 public IPs per subscription per
region** on a trial subscription. The three were Bastion, the NAT gateway, and **AKS's
own auto-created outbound SNAT IP in the `MC_*` RG** (the surprise one).

Resolution: delete Bastion (never used — `az vm run-command` did every job and needs no
network path). NAT gateway is load-bearing (agent polls `dev.azure.com`); AKS's IP
can't be removed while the cluster exists. Proper fix = quota increase (free, hours).

```bash
sed -i '/^resource "azurerm_bastion_host" "main" {/,/^}/d' main.tf
sed -i '/^resource "azurerm_public_ip" "bastion" {/,/^}/d' main.tf
sed -i '/^output "bastion_public_ip" {/,/^}/d' outputs.tf
grep -n "bastion" main.tf outputs.tf        # must be empty
terraform apply -auto-approve
kubectl delete svc ingress-nginx-controller -n ingress-nginx   # forces re-allocation
```

- Deleting the public IP failed once with `PublicIPAddressCannotBeDeleted` — Azure
  reported the Bastion gone before releasing its IP association. **Re-apply; it's lag,
  not an error.**
- **Architect around the 3-IP cap from the start** on a trial subscription.

### This run's values
| Thing | Value |
|---|---|
| ACR | `acrlnehpvmb5` |
| Key Vault | `kv-lne-hpvmb5` |
| Image tags | backend `13`, frontend `15`, todo `14` |
| Ingress public IP | `20.235.200.160` |
| Jumphost private IP | `10.0.2.4` |

---

## 11. ACI backend, K8s manifests, Flux

### ACI (`aci.tfstate`)
- NSG rule priority 100: allow **only** `10.0.1.0/24` (AKS node subnet) → port 8000,
  plus a deny-all at 4000. This IS the "backend accepts requests only from the
  frontend" requirement.
- `azurerm_user_assigned_identity` + `AcrPull` + `image_registry_credential {
  user_assigned_identity_id = ... }` → ACI pulls from ACR with no admin creds.
- `depends_on = [azurerm_role_assignment.aci_acr_pull]` — without it ACI starts
  pulling before it has permission.
- `ip_address_type = "Private"` + `subnet_ids` = the delegated subnet.
- Postgres password read from Key Vault via `data "azurerm_key_vault_secret"`;
  passed as `secure_environment_variables` (not plain `environment_variables`).
- **ACI is not Kubernetes** — `kubectl logs` cannot see it. Use
  `az container logs -g <rg> -n aci-lne-backend`.

### The selector-less Service trick
A client-side React SPA's API calls originate from the **user's browser**, which can
never reach a VNet-private ACI. Solution: route backend traffic through the same
public ingress.

- `backend-service.yaml` has **no `selector`** → K8s does not auto-generate Endpoints.
- `backend-endpoints.yaml` supplies them manually: `ip: 10.0.3.4`, `port: 8000`.
- Result: a normal K8s Service fronting a workload that is not in the cluster at all.

### Kustomize
`kustomization.yaml` must list **every** file in `resources:`. Kustomize silently
ignores anything unlisted — that is how the Ingress objects went missing last build
while Flux reported success.

### Flux
```bash
flux bootstrap git \
  --url=https://dev.azure.com/galaxyblaster/lne-employee-todo/_git/lne-employee-todo \
  --branch=master --username=git --password="$ADO_PAT" --token-auth=true \
  --path=clusters/aks-lne
```
- **Check the branch first** (`git rev-parse --abbrev-ref HEAD`) — ADO defaulted to
  `master`; bootstrap fails with `couldn't find remote ref "refs/heads/main"`.
- Bootstrap creates a GitRepository + a Kustomization watching only `clusters/...`.
  App manifests need a **second Kustomization** (`apps-sync.yaml`) pointing at
  `./apps/employee-todo`, reusing `sourceRef: GitRepository/flux-system`.
- `flux reconcile kustomization <name> --with-source` to force, instead of waiting.

---

## 12. THE LOAD BALANCER HEALTH PROBE (cost the most time this run)

**Symptom:** every request to the public IP hangs and returns `000`. No reset, no
error, nothing in any log.

### Layered diagnosis — split the path
```bash
# from inside the VNet, against the node
curl http://10.0.1.5:31766/to-do/        # NodePort  -> 200  (app+svc+nginx fine)
curl http://<clusterIP>/to-do/           # 000, and MEANINGLESS — ClusterIP is not
                                         # routable from a VM under kubenet
# from the internet
curl http://20.235.200.160/to-do/        # 000       -> break is at the LB
```

### Root cause
The Azure LB health probe was set to `/healthz`. **nginx-ingress serves `/healthz` on
its status port 10254, not on port 80** — on port 80 it is just an unmatched request
→ 404. Probe fails → LB marks the only node unhealthy → every packet dropped, while
a direct NodePort curl keeps returning 200.

Removing the path made it default to `/`, which nginx also 404s. The
`azure-load-balancer-health-probe-protocol: tcp` annotation was **silently ignored**
by this AKS version (probe stayed `Http`).

### Fix — probe a path that actually returns 200
```bash
# find one first
for p in / /healthz /to-do /to-do/ /emp/; do
  curl -s -m 5 -o /dev/null -w "$p -> %{http_code}\n" http://10.0.1.5:31766$p
done
# / -> 404, /healthz -> 404, /to-do -> 200

kubectl annotate svc ingress-nginx-controller -n ingress-nginx \
  service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path=/to-do \
  --overwrite
```
Verify Azure actually reconciled — the annotation alone is not proof:
```bash
az network lb probe list -g $MCRG --lb-name kubernetes \
  --query "[].{proto:protocol, port:port, path:requestPath}" -o table
```

### Standing lesson
**A passing health check proves the health-check path, not the data path — and a
failing one silently kills the data path.** Both of this project's worst bugs
(port-80 NSG last build, probe path this build) are the same shape: probe and real
traffic taking different routes, with only the probe's verdict controlling delivery.
Always verify the probe target returns 200 *by curling it yourself*.

---

## 13. App-layer debugging (after infra was green)

### `28P01` — SequelizeConnectionError
Postgres error `28P01` = `auth_failed`. Everyone reads it as "wrong password"; it
equally means **wrong (or empty) username**.

Isolation that found it — bypass the app entirely:
```bash
docker run --rm -e PGPASSWORD="$PW" postgres:14 \
  psql -h psql-lne-employee-todo.postgres.database.azure.com \
       -U pgadminuser -d employeeapp -c 'select 1;'
```
psql **succeeded** → credentials fine → the app was sending something different.

Root cause, found only by reading `config/dbConfig.js`:
```js
username: process.env.DBUSERNAME ? ... : config?.DBUSERNAME
password: process.env.DBPASSWORD ? ... : config?.PASSWORD
```
We had set **`DBUSER`**, the app reads **`DBUSERNAME`** → `undefined` → 28P01.
Every other var name (`DBPASSWORD`, `DBNAME`, `DBHOST`, `DBPORT`, `DBDIALECT`) was right.

**Lesson: when env vars "don't work", read the code that consumes them.** Never trust
a README or your own assumption about the names. The fallback chain
(`process.env.X → config?.X → undefined`) fails silently — no log would have shown it.

### Key Vault 403 as yourself
`az keyvault secret show` → `ForbiddenByRbac`, caller
`appid=04b07795-8ddb-461a-bbee-02f9e1bf7b46` — that is the **Azure CLI's own well-known
app ID**, i.e. your personal `az login`. Only the SPN was granted Secrets Officer.
```bash
az role assignment create --assignee-object-id $(az ad signed-in-user show --query id -o tsv) \
  --assignee-principal-type User --role "Key Vault Secrets Officer" \
  --scope $(az keyvault show -n kv-lne-hpvmb5 --query id -o tsv)
```
Recognising that appid instantly tells you Terraform/CLI fell back to the human identity.

### This app returns HTTP 200 for errors
The real status is inside the body (`{"statusCode":"500",...}`). A green 200 in DevTools
proves nothing — **read the response body**.

### Route shapes are not guessable
`app.use("/api/v1/employees", routers.employee)` but the router only defines
`POST /addEmployee`, `POST /findEmployees`, `POST /findEmployeeById`,
`PUT /updateEmployee`, `DELETE /deleteEmployee?Id=`. So `GET /api/v1/employees`
correctly 404s — my test URL was wrong, not the ingress. Model columns are
`firstName`/`lastName`/`emailAddress`, not `name`/`email`/`phone`.

### Final "delete doesn't work"
API proven correct (`data: 1` rows deleted, list then empty) — the row stayed on screen
because the React app never re-fetches after a delete. **Upstream app bug, not infra.**
Verify state at the API, not in the UI.

### Recurring self-inflicted bug
Pasting a placeholder literally (`<appId>`, `<NEW_IP>`, `<paste-an-Id-here>`) happened
**three times** this run. Substitute before running; `cat`/`grep` the file back after
any templated write.

---

## 14. Final state — verified working

| Component | Value |
|---|---|
| Ingress public IP | `20.235.200.160` |
| `/emp/` (React frontend) | 200 |
| `/to-do/` (Flask todo) | 200 |
| `/emp/api/v1/employees/*` | → ACI backend `10.0.3.4:8000` |
| Employee CRUD | create / read / delete all persist to Postgres |

Path: browser → public LB → nginx ingress → rewrite → selector-less Service →
manual Endpoints → ACI private IP → Express → Sequelize (SSL) → private Postgres.
