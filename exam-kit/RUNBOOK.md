# Exam Runbook — Employee/Todo Platform on Azure

Ordered build. `[UI]` = manual click in a browser, everything else is paste-and-run.
Estimated total: **~2.5 h**, most of it waiting on AKS, Postgres and image builds.

**Golden rule before every `terraform` command:**
```bash
echo $ARM_CLIENT_ID     # empty => Terraform silently uses your az login, not the SPN
```

**Run every long apply inside tmux.** SSH drops killed two applies during practice.
```bash
tmux new -s tf      # detach Ctrl+B D, reattach: tmux attach -t tf
```

---

## Phase -1 — Fresh subscription pre-flight (15 min)

Only needed when you are handed a bare subscription. Skip what is already true.

### -1.1  Confirm what you have
```bash
az login --use-device-code
az account show --query "{sub:name, id:id, tenant:tenantId, state:state}" -o table
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --all -o table
```
You need **Owner**. Contributor cannot create role assignments or policy assignments.
`az login` blocked by `AADSTS530035` → Entra ID → Properties → Manage security
defaults → Disabled.

### -1.2  Register resource providers — DO THIS FIRST, it is async
A fresh subscription has these unregistered and Terraform fails with
`MissingSubscriptionRegistration`. Takes 2–5 min, so start it before anything else.
```bash
for ns in Microsoft.ContainerService Microsoft.ContainerInstance \
          Microsoft.ContainerRegistry Microsoft.DBforPostgreSQL \
          Microsoft.KeyVault Microsoft.Network Microsoft.Storage \
          Microsoft.Compute Microsoft.ManagedIdentity \
          Microsoft.OperationalInsights Microsoft.PolicyInsights; do
  az provider register --namespace $ns
done
```
Verify later — anything listed here is still not ready:
```bash
az provider list --query "[?registrationState!='Registered'].{ns:namespace, state:registrationState}" -o table
```

### -1.3  Check quotas — they decide the architecture
```bash
az vm list-usage --location $LOC -o table | grep -iE "Total Regional|Standard D|Standard B"
az network list-usages --location $LOC -o table | grep -i "Public IP"
```
- **Public IP (Standard) = 3** is the common trial cap. AKS silently takes one for
  outbound SNAT → only two left: NAT gateway + ingress. **Build no Bastion.**
- **vCPU**: AKS node D2s_v5 (2) + jump host B2s_v2 (2) = 4. At a cap of 4 there is no
  headroom. If a VM size is refused, the error lists the allowed ones — read it.

### -1.4  Workstation
Given a Linux VM? Use it. Not given one? Use **Azure Cloud Shell** (`>_` in the
Portal) — az / terraform / kubectl / helm / git preinstalled and already
authenticated. It cannot reach the private AKS API server, but the jump host does
that job anyway. Do not hand-build a workstation VM.

### -1.5  Azure DevOps `[UI]`
dev.azure.com → create **organization** → create **project** (Git, private) →
Repos → copy clone URL → avatar → **Personal access tokens**:
Agent Pools *Read & manage* + Code *Read & write*. Copy it — shown once.

### -1.6  Prove you can create a service principal
Directory permission is separate from Azure RBAC. Test it cheaply before you depend
on it:
```bash
az ad sp create-for-rbac --name test-delete-me --role Reader \
  --scopes /subscriptions/$(az account show --query id -o tsv)
az ad sp delete --id <appId>     # substitute the real appId
```
Insufficient privileges → Entra ID → User settings → "Users can register
applications" = Yes, or request the **Application Administrator** role.

### -1.7  Tools
```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
curl -sL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform git tmux
df -h /
```
RHEL/CentOS: no `apt` — use `dnf`; if `azure-cli` will not install (python version),
fall back to `curl -L https://aka.ms/InstallAzureCli | bash`.

---

## Phase 0 — Prepare (10 min)

| Step | Action |
|---|---|
| 0.1 `[UI]` | Create ADO **organization** and **project** |
| 0.2 `[UI]` | Repos → clone URL. Generate a **PAT**: Agent Pools *Read & manage* + Code *Read & write*. Copy it — shown once |
| 0.3 | `az login --use-device-code` on the exam VM |
| 0.4 | Clone this kit + your repo onto the VM |
| 0.5 | **Edit `vars.env`** — org, project, prefix. Then `source vars.env` |

If `az login` is blocked by `AADSTS530035`, disable Security Defaults:
Entra ID → Properties → Manage security defaults → Disabled.

---

## Phase 1 — Bootstrap (5 min)

```bash
source vars.env
bash 01-bootstrap.sh
```

Creates the tfstate RG + storage + container, the SPN (**Owner**, not Contributor),
and `~/spn.env`. Copy the printed `TFSTATE_SA` back into `vars.env`.

```bash
source ~/spn.env
echo $ARM_CLIENT_ID          # must be a GUID
```

**Why Owner:** Contributor excludes `Microsoft.Authorization/*`, which blocks both
policy assignments and role assignments. Least-privilege alternative is
`Contributor` + `User Access Administrator`.

---

## Phase 2 — Generate all code (instant)

```bash
source vars.env
REPO=~/<your-repo-dir> bash 02-generate.sh
```

Writes all six Terraform modules, four pipelines, nine K8s manifests and `.gitignore`,
substituted from `vars.env`. **Idempotent — re-run it whenever you learn a new value**
(ACR name, image tags, ingress IP, ACI IP) after updating `vars.env`.

```bash
cd ~/<your-repo-dir>
git add -A && git commit -m "infra" && git push
```

---

## Phase 3 — Terraform, in dependency order

Each module: `terraform init && terraform fmt && terraform validate && terraform plan && terraform apply`

| # | Module | Time | Expect |
|---|---|---|---|
| 3.1 | `policy` | 1 min | 4 assignments (2 tags + 2) |
| 3.2 | `network` | 2 min | RG, VNet, 5 subnets, NSG + assoc, DNS zone + link |
| 3.3 | `platform` | **10 min** | ACR, Key Vault, private AKS |
| 3.4 | `postgres` | **10 min** | server + `employeeapp` db + 2 KV secrets |
| 3.5 | `jumphost` | 3 min | NAT gw, NIC, VM, SSH key → KV |

After 3.3:
```bash
export ACR=$(terraform -chdir=terraform/platform output -raw acr_name)
export KV=$(terraform -chdir=terraform/platform output -raw key_vault_name)
# put both into vars.env
```

**From 3.1 onward every resource needs both tags.** The one that catches people:
AKS needs a `tags` block **inside `default_node_pool`** — cluster tags do not reach the
auto-created `MC_*` resource group, and the VMSS is rejected by the policy.

---

## Phase 4 — Jump host + agent (10 min)

`[UI]` **Project settings → Agent pools → Add pool → Self-hosted → `lne-vnet-agents`**
(tick "Grant access permission to all pipelines")

```bash
source vars.env && source ~/spn.env
read -s -p "PAT: " ADO_PAT; echo     # <-- ON ITS OWN LINE. In a pasted block,
                                     #     read eats the next pasted line.
bash 03-jumphost.sh
```

`[UI]` Confirm the agent shows **Online**.

**Why a self-hosted agent:** the AKS API server is private. A Microsoft-hosted agent is
on the public network and physically cannot reach it, however good its credentials.
The SPN is *credentials*; the NAT gateway is *connectivity*.

---

## Phase 5 — Service connection `[UI]`

Project settings → Service connections → New → **Azure Resource Manager** →
**App registration or managed identity (manual)** → Credential: **Secret**

| Field | Value |
|---|---|
| Subscription Id / Name | `$SUB_ID` / `az account show --query name -o tsv` |
| Service Principal Id | `$ARM_CLIENT_ID` |
| Service principal key | `$ARM_CLIENT_SECRET` |
| Tenant Id | `$ARM_TENANT_ID` |
| Connection name | `lne-azure-connection` |

Verify and save, grant access to all pipelines.

**Not "automatic"** — that creates a *new* app registration without your role
assignments, giving "works locally, 403 in pipeline".

---

## Phase 6 — Build images (10 min)

`[UI]` For each of the four YAMLs: **Pipelines → New → Azure Repos Git → repo →
Existing Azure Pipelines YAML file → `/pipelines/<name>.yml` → Save**

Run `backend`, `frontend`, `todo`. Then:

```bash
for r in backend frontend todo; do
  echo -n "$r: "; az acr repository show-tags --name $ACR --repository $r -o tsv
done
```

Put the three tags into `vars.env`. **Read them from ACR — never assume.**

---

## Phase 7 — Ingress controller (5 min)

Run `nginx-ingress-pipeline`. Grab the IP:

```bash
az vm run-command invoke -g $WORK_RG -n $VM --command-id RunShellScript \
  --scripts "export KUBECONFIG=/root/.kube/config; kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
```

Put it in `vars.env` as `INGRESS_IP`.

**If `EXTERNAL-IP` stays `<pending>`:** read the events, never guess —
`kubectl describe svc ingress-nginx-controller -n ingress-nginx | tail -30`.
The usual cause on a trial subscription is **`PublicIPCountLimitReached` — 3 public IPs
per region**. AKS silently takes one for outbound SNAT, so you only have two to spend.
This kit therefore builds **no Bastion** (`az vm run-command` does every job it would).

---

## Phase 8 — ACI backend (5 min)

```bash
source vars.env
cat > terraform/aci/terraform.tfvars <<EOF
backend_image_tag = "$TAG_BACKEND"
ingress_public_ip = "$INGRESS_IP"
EOF
cd terraform/aci && terraform init && terraform apply -auto-approve
export ACI_IP=$(terraform output -raw aci_private_ip)      # put into vars.env
```

---

## Phase 9 — Manifests + Flux (10 min)

Re-generate now that `ACR`, tags, `INGRESS_IP` and `ACI_IP` are all known:

```bash
source vars.env
REPO=~/<your-repo-dir> bash 02-generate.sh
grep -rn '__' apps/ || echo "no placeholders left"
git add -A && git commit -m "manifests" && git push
```

Check the branch first — ADO often defaults to `master`:

```bash
git rev-parse --abbrev-ref HEAD
read -s -p "PAT: " ADO_PAT; echo        # own line
```

```bash
cat > /tmp/flux.sh <<EOF
export HOME=/root; export KUBECONFIG=/root/.kube/config
flux bootstrap git \
  --url=https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_git/$ADO_REPO \
  --branch=\$(git -C ~/<repo> rev-parse --abbrev-ref HEAD) \
  --username=git --password="$ADO_PAT" --token-auth=true \
  --path=clusters/aks-$P
EOF
az vm run-command invoke -g $WORK_RG -n $VM --command-id RunShellScript --scripts @/tmp/flux.sh
rm -f /tmp/flux.sh
```

Bootstrap only watches `clusters/…`. Add a second Kustomization for the apps:

```bash
git pull
mkdir -p clusters/aks-$P
cat > clusters/aks-$P/apps-sync.yaml <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: employee-todo-apps
  namespace: flux-system
spec:
  interval: 1m
  path: ./apps/employee-todo
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
EOF
git add -A && git commit -m "flux app sync" && git push

az vm run-command invoke -g $WORK_RG -n $VM --command-id RunShellScript \
  --scripts "export KUBECONFIG=/root/.kube/config; flux reconcile kustomization employee-todo-apps --with-source; kubectl get all,ingress -n employee-todo"
```

---

## Phase 10 — Verify

```bash
source vars.env && bash 04-verify.sh
```

Then in a browser: `http://$INGRESS_IP/emp/` and `http://$INGRESS_IP/to-do/`.

API check (this app returns **HTTP 200 even for errors** — read the body):
```bash
curl -s -X POST http://$INGRESS_IP/emp/api/v1/employees/findEmployees \
  -H "Content-Type: application/json" -d '{}'; echo
```
Want `{"statusCode":"200","statusMessage":"Document Found","data":[...]}`.

---

## The five that cost the most time

1. **LB health probe on a 404 path.** nginx serves `/healthz` on port **10254**, not 80;
   `/` and `/healthz` both 404 on the NodePort. A failing probe drops *all* data traffic
   while a direct NodePort curl still returns 200. **Curl the probe target yourself.**
2. **NSG port 80.** AKS sets `EnableFloatingIP=True`, so the LB does *not* rewrite the
   destination port — real traffic arrives on **80**, probes on the **NodePort**.
   Allowing only 30000-32767 = probes green, everything silently dropped.
3. **`DBUSER` vs `DBUSERNAME`.** Postgres `28P01` means "auth failed", which equally
   covers an empty *username*. Read the code that consumes the env vars.
4. **3 public IPs per region** on a trial subscription; AKS takes one invisibly.
5. **Node-pool tags.** Cluster-level `tags` never reach the `MC_*` VMSS.

## Habits that prevented the rest

- `grep`/`cat` the file back after any `sed` or templated write — **sed exits 0 when it
  matches nothing.** (Pasting a literal `<placeholder>` happened three times.)
- `echo $ARM_CLIENT_ID` before every apply.
- `ps aux | grep terraform` before any `force-unlock`.
- `df -h` early when anything behaves inexplicably — the azurerm provider is ~250 MB
  **per module directory** unless `plugin_cache_dir` is set (01-bootstrap sets it).
- Get the real error from the right place: browser DevTools for frontend,
  `kubectl logs` for AKS, **`az container logs`** for ACI (it is not Kubernetes),
  `kubectl describe svc` events for a pending LoadBalancer.
