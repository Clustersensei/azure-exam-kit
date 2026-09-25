# Reference build — verbatim working code

This is the code exactly as it ran in a build verified end to end: Employee CRUD
persisting to Postgres, Todo add/finish/delete, both served from one public ingress IP.

Generated names from that run (yours will differ — ACR/Key Vault get a random suffix):

| Thing | Value |
|---|---|
| Region | `centralindia` |
| State backend | `lne-employee-to-do-rg` / `tfstate300` / `tfstate` |
| Workload RG | `rg-lne-employee-todo` |
| ACR / Key Vault | `acrlnehpvmb5` / `kv-lne-hpvmb5` |
| AKS / Postgres | `aks-lne-employee-todo` / `psql-lne-employee-todo` |
| Ingress IP / ACI IP | `20.235.200.160` / `10.0.3.4` |
| Image tags | frontend `15`, backend `13`, todo `14` |

---

## Prefer the generator

`exam-kit/02-generate.sh` produces this same code from `vars.env`, with every name
substituted for you. Using it removes a whole class of "I renamed nine of the ten
places" errors. Use this directory when you want to read the code, diff against it, or
when the generator is not behaving.

## Two known bugs in this code

Both were found by planning the generator's output against this build's live state.
**The generator fixes them; this directory does not.**

**1. The private DNS zone and its VNet link have no tags.**
They were created before the policy module was applied, so the tag policy never
evaluated them. If you apply **policy first** — which the runbook does, and which the
spec implies — this code fails with `RequestDisallowedByPolicy`. Fix before using:

```hcl
resource "azurerm_private_dns_zone" "postgres" {
  # ...
  tags = local.tags          # <-- ADD
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  # ...
  tags = local.tags          # <-- ADD
}
```

**2. `default_node_pool` does not declare `upgrade_settings`.**
Harmless, but every future `plan` proposes an in-place change, which hides real diffs.

```hcl
default_node_pool {
  # ...
  upgrade_settings {
    drain_timeout_in_minutes      = 0
    max_surge                     = "10%"
    node_soak_duration_in_minutes = 0
  }
}
```

---

## Using it in a new environment

### 1. Backend blocks — six files, one edit each

Every module's `terraform { backend "azurerm" { ... } }` points at the old state
account. Change `storage_account_name` (and `resource_group_name` if you renamed it)
in all six, plus the `terraform_remote_state` blocks that read other modules.

```bash
grep -rn 'tfstate300\|lne-employee-to-do-rg' terraform/
sed -i 's/tfstate300/<your-new-sa>/g; s/lne-employee-to-do-rg/<your-new-rg>/g' \
  $(find terraform -name '*.tf')
grep -rn 'tfstate300\|lne-employee-to-do-rg' terraform/    # must be empty
```

**Always grep after a sed.** `sed` exits 0 when it matches nothing.

### 2. Resource names

```bash
grep -rn '"rg-lne-\|"vnet-lne-\|"aks-lne-\|"psql-lne-\|"vm-lne-\|"nsg-lne-\|"natgw-lne\|"pip-lne-\|"id-lne-\|"aci-lne-' terraform/
```

Change them or keep them — they only need to be unique within the resource group.
**ACR and Key Vault names are globally unique**, but both use a `random_string` suffix,
so they take care of themselves.

### 3. Values you must supply as you go

| File | Value | Where it comes from |
|---|---|---|
| `pipelines/*.yml` | `acrName` | `terraform -chdir=terraform/platform output -raw acr_name` |
| `pipelines/*.yml` | `pool`, `azureSubscription` | your agent pool and service connection names |
| `terraform/aci/terraform.tfvars` | `backend_image_tag` | `az acr repository show-tags` — **read it, never assume** |
| `terraform/aci/terraform.tfvars` | `ingress_public_ip` | the nginx pipeline |
| `apps/employee-todo/frontend-deployment.yaml` | `API_BASE_URL` | `http://<ingress-ip>/emp` — **no `/api` suffix** |
| `apps/employee-todo/*-deployment.yaml` | image tags | ACR |
| `apps/employee-todo/backend-endpoints.yaml` | `ip:` | `terraform -chdir=terraform/aci output -raw aci_private_ip` |
| `clusters/aks-*/` | path | must match `flux bootstrap --path` |

### 4. Apply order

```
policy → network → platform → postgres → jumphost → (agent, pipelines, ingress) → aci → flux
```

`terraform_remote_state` reads a module's **state file**, so a module must be applied
before anything that reads it. Terraform cannot enforce this across directories — the
ordering is your discipline.

### 5. The manual bits this code cannot do for you

- ADO organization, project, repo
- Agent pool (self-hosted) + PAT
- ARM service connection — **App registration (manual)**, reusing the same SPN
- Registering each pipeline YAML as a pipeline
- `flux bootstrap` (needs the PAT and the right branch — check whether it is `master`)

See `exam-kit/RUNBOOK.md` for all of these with commands.

---

## Sanity check before you trust an edit

If you still have a working deployment, plan this code against its state. `No changes`
is a far stronger statement than "the code looks right" — it is how both bugs above
were found.

```bash
cd terraform/<module> && terraform init && terraform plan -lock=false -no-color
```
