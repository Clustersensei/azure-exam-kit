#!/bin/bash
# ============================================================
#  05 - HANDOVER  (run last, after everything works)
#
#   1. writes ~/CREDENTIALS.md  (the task deliverable)
#   2. audits the repo + VM for anything that should not be there
#   3. removes scratch files, downloaded installers, shell history
#
#  SAFE BY DEFAULT: prints what it WOULD remove and changes nothing.
#  To actually delete:  CONFIRM=yes bash 05-handover.sh
#
#  Usage: source vars.env && source ~/spn.env && bash 05-handover.sh
# ============================================================
set -u
[ -z "${P:-}" ] && { echo "run: source vars.env first"; exit 1; }
WORK="${WORK:-$HOME/work}"
KIT="${KIT:-$HOME/kit}"

hr () { echo; echo "=================== $1 ==================="; }

# ------------------------------------------------------------
hr "1. CREDENTIALS.md"
# ------------------------------------------------------------
PGPASS="(read from Key Vault: az keyvault secret show --vault-name ${KV:-<kv>} --name postgres-admin-password --query value -o tsv)"

cat > ~/CREDENTIALS.md <<EOF
# Credentials & Access — $P Employee/Todo Platform
Generated $(date -u +"%Y-%m-%d %H:%M UTC"). **Treat as secret. Not committed to git.**

## Public entry point
| What | Where |
|---|---|
| Employee app | http://${INGRESS_IP:-<ip>}/emp/ |
| Todo app | http://${INGRESS_IP:-<ip>}/to-do/ |
| Backend API | http://${INGRESS_IP:-<ip>}/emp/api/v1/employees/ |

## Azure
| Item | Value |
|---|---|
| Subscription | ${ARM_SUBSCRIPTION_ID:-<sub>} |
| Tenant | ${ARM_TENANT_ID:-<tenant>} |
| Region | $LOC |
| Workload RG | $WORK_RG |
| State RG / SA / container | $TFSTATE_RG / $TFSTATE_SA / $TFSTATE_CONTAINER |

## Service principal (used by Terraform AND the ADO service connection)
| Item | Value |
|---|---|
| Name | $SPN_NAME |
| Client ID | ${ARM_CLIENT_ID:-<appid>} |
| Client secret | stored in \`~/spn.env\` (chmod 600) — rotate with \`az ad sp credential reset --id ${ARM_CLIENT_ID:-<appid>}\` |
| Role | Owner @ subscription scope |

## Resources
| Item | Value |
|---|---|
| ACR | ${ACR:-<acr>}.azurecr.io (admin account **disabled** — use \`az acr login\`) |
| Key Vault | ${KV:-<kv>} (RBAC mode) |
| AKS | $AKS (**private** API server) |
| Postgres | $PG (**no public access**, VNet-integrated) |
| Postgres DB / user | employeeapp / pgadminuser |
| Postgres password | $PGPASS |
| ACI backend | aci-$P-backend @ ${ACI_IP:-<ip>}:8000 (private, NSG-locked to $SNET_AKS) |
| Jump host | $VM (no public IP; reach it with \`az vm run-command\`) |
| Jump host SSH key | Key Vault secret \`jumphost-ssh-private-key\` |

## Key Vault secrets
| Name | Contents |
|---|---|
| postgres-admin-password | Postgres admin password |
| postgres-fqdn | Postgres FQDN |
| jumphost-ssh-private-key | Jump host SSH private key (PEM) |

Read one:
\`\`\`bash
az keyvault secret show --vault-name ${KV:-<kv>} --name <name> --query value -o tsv
\`\`\`
403 as yourself? The vault is RBAC-mode and only the SPN was granted access:
\`\`\`bash
az role assignment create --assignee-object-id \$(az ad signed-in-user show --query id -o tsv) \\
  --assignee-principal-type User --role "Key Vault Secrets Officer" \\
  --scope \$(az keyvault show -n ${KV:-<kv>} --query id -o tsv)
\`\`\`

## Azure DevOps
| Item | Value |
|---|---|
| Org / project | $ADO_ORG / $ADO_PROJECT |
| Service connection | $SERVICE_CONNECTION (SPN above) |
| Agent pool / agent | $AGENT_POOL / $AGENT_NAME (self-hosted on $VM) |
| PAT | **not stored** — regenerate in ADO if needed |

## Cluster access
Only from the jump host — the AKS API server has no public endpoint.
\`\`\`bash
az vm run-command invoke -g $WORK_RG -n $VM --command-id RunShellScript \\
  --scripts "export KUBECONFIG=/root/.kube/config; kubectl get pods -A"
\`\`\`
EOF
chmod 600 ~/CREDENTIALS.md
echo "wrote ~/CREDENTIALS.md (chmod 600)"
[ -n "${INGRESS_IP:-}" ] || echo "  WARNING: INGRESS_IP empty in vars.env — fill it and re-run"

# ------------------------------------------------------------
hr "2. AUDIT — anything sensitive that got committed?"
# ------------------------------------------------------------
if [ -d "$WORK/.git" ]; then
  cd "$WORK"
  echo "--- tracked files that should never be tracked ---"
  git ls-files | grep -Ei '(^|/)(spn\.env|.*\.tfstate|.*\.pem|CREDENTIALS\.md|.*\.tfvars\.secret)$' \
    && echo "  ^^ REMOVE THESE: git rm --cached <file>" || echo "  clean"

  echo "--- secret-shaped strings in tracked content ---"
  git grep -nIE '(ARM_CLIENT_SECRET|password[[:space:]]*=[[:space:]]*"[^"$]|[A-Za-z0-9_~.-]{34,}~[A-Za-z0-9_.-]{6,})' -- \
    ':!*.md' 2>/dev/null | head -20 || echo "  clean"

  echo "--- unresolved placeholders ---"
  grep -rho '__[A-Z_]*__\|<[a-z-]*>' terraform pipelines apps 2>/dev/null | sort -u | head || echo "  clean"
  cd - >/dev/null
else
  echo "no git repo at $WORK — skipping audit"
fi

# ------------------------------------------------------------
hr "3. SCRATCH TO REMOVE"
# ------------------------------------------------------------
CANDIDATES=$(ls -d 2>/dev/null \
  /tmp/tools.sh /tmp/kube.sh /tmp/agent.sh /tmp/flux.sh /tmp/pgtest.sh /tmp/rb.md \
  ~/install-tools.sh ~/install-agent.sh ~/install-node.sh ~/setup-kube.sh \
  ~/flux-bootstrap.sh ~/pgtest.sh ~/agent.tar.gz ~/get-docker.sh ~/kubectl \
  ~/sample-node-app ~/sample-react-app ~/Todo-List-Dockerized-Flask-WebApp)

if [ -z "$CANDIDATES" ]; then
  echo "nothing to remove"
else
  echo "$CANDIDATES" | sed 's/^/  /'
fi

echo
echo "--- also consider (NOT auto-removed, decide yourself) ---"
echo "  $KIT                  the runbook/crib. Remove if the VM is being handed in."
echo "  ~/.terraform.d/plugin-cache   ~250MB, safe to delete, costs a re-download"
echo "  ~/spn.env             KEEP if you may need to re-apply. chmod 600, gitignored."
echo "                        Delete only after rotating: az ad sp credential reset --id ${ARM_CLIENT_ID:-<appid>}"

# ------------------------------------------------------------
hr "4. SHELL HISTORY"
# ------------------------------------------------------------
echo "lines in ~/.bash_history mentioning a token/secret:"
grep -cniE 'ADO_PAT|ARM_CLIENT_SECRET|--admin-password|--password|PGPASSWORD|secret show' ~/.bash_history 2>/dev/null || echo "0"

# ------------------------------------------------------------
if [ "${CONFIRM:-no}" != "yes" ]; then
  hr "DRY RUN"
  echo "Nothing was deleted. To apply:  CONFIRM=yes bash 05-handover.sh"
  exit 0
fi

hr "DELETING"
[ -n "$CANDIDATES" ] && rm -rf $CANDIDATES && echo "removed scratch files"

# scrub history, keep the file so the shell doesn't recreate a stale one
if [ -f ~/.bash_history ]; then
  sed -i -E '/ADO_PAT|ARM_CLIENT_SECRET|--admin-password|--password|PGPASSWORD|secret show/d' ~/.bash_history
  echo "scrubbed ~/.bash_history"
fi
history -c 2>/dev/null || true

# docker build cache on the JUMP HOST, not here — images were built there
echo
echo "Optional, on the jump host (frees several GB of image layers):"
echo "  az vm run-command invoke -g $WORK_RG -n $VM --command-id RunShellScript \\"
echo "    --scripts 'docker image prune -af; docker builder prune -af; df -h /'"

hr "DONE"
echo "Left in place deliberately:"
echo "  $WORK            your code (the deliverable)"
echo "  ~/CREDENTIALS.md  chmod 600, gitignored"
echo "  ~/spn.env         chmod 600, gitignored — delete after rotating if handing the VM in"
echo
echo "Final check:  source vars.env && bash 04-verify.sh"
