#!/bin/bash
# ============================================================
#  02 - GENERATE ALL CODE
#  Writes every .tf, pipeline .yml and k8s manifest into $REPO,
#  substituted from vars.env. Idempotent - safe to re-run.
#  Usage: source vars.env && REPO=~/work/<repo> bash 02-generate.sh
# ============================================================
set -e
[ -z "$P" ] && { echo "run: source vars.env first"; exit 1; }
REPO="${REPO:-$PWD}"
cd "$REPO"

mkdir -p terraform/{policy,network,platform,postgres,jumphost,aci} pipelines apps/employee-todo

# --- shared header written into every module -------------------
hdr () {  # $1 = state key, $2 = extra providers
cat <<'HDREOF'
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.0" }
HDREOF
[ -n "$2" ] && echo "$2"
cat <<HDREOF
  }
  backend "azurerm" {
    resource_group_name  = "__TFSTATE_RG__"
    storage_account_name = "__TFSTATE_SA__"
    container_name       = "__TFSTATE_CONTAINER__"
    key                  = "$1"
  }
}

provider "azurerm" {
  features {}
}
HDREOF
}

# --- remote-state reader ---------------------------------------
rstate () {  # $1 = module name
cat <<RSEOF

data "terraform_remote_state" "$1" {
  backend = "azurerm"
  config = {
    resource_group_name  = "__TFSTATE_RG__"
    storage_account_name = "__TFSTATE_SA__"
    container_name       = "__TFSTATE_CONTAINER__"
    key                  = "$1.tfstate"
  }
}
RSEOF
}

tagsblock () {
cat <<'TEOF'

locals {
  tags = {
    "Business Unit" = "__BU__"
    "Cost Center"   = "__CC__"
  }
}
TEOF
}

# ===============================================================
# 1. POLICY
# ===============================================================
{ hdr "policy.tfstate"
cat <<'EOF'

data "azurerm_subscription" "current" {}

# Definition = the rule (inert). Assignment = definition + scope + params (has teeth).
# The built-in "require a tag" takes ONE tagName, so N tags = N assignments.
resource "azurerm_subscription_policy_assignment" "require_tag" {
  for_each             = toset(var.mandatory_tags)
  name                 = "req-tag-${replace(lower(each.value), " ", "-")}"   # 24 char API limit
  display_name         = "Require ${each.value} tag"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99"
  parameters           = jsonencode({ tagName = { value = each.value } })    # {value=} is Azure's shape
}

resource "azurerm_subscription_policy_assignment" "deny_nic_public_ip" {
  name                 = "deny-nic-public-ip"
  display_name         = "Deny public IP on NIC"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/83a86a26-fd1f-447c-b59d-e51f44264114"
}

resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  display_name         = "Allowed locations - India regions"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
  parameters           = jsonencode({ listOfAllowedLocations = { value = var.allowed_locations } })
}
EOF
} > terraform/policy/main.tf

cat > terraform/policy/variables.tf <<'EOF'
variable "mandatory_tags"    { type = list(string) }
variable "allowed_locations" { type = list(string) }
EOF

cat > terraform/policy/terraform.tfvars <<'EOF'
mandatory_tags    = ["Business Unit", "Cost Center"]
allowed_locations = ["centralindia", "southindia", "westindia"]
EOF

# ===============================================================
# 2. NETWORK
# ===============================================================
{ hdr "network.tfstate"
tagsblock
cat <<'EOF'

resource "azurerm_resource_group" "main" {
  name     = "__WORK_RG__"
  location = "__LOC__"
  tags     = local.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "__VNET__"
  address_space       = ["__VNET_CIDR__"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# Standalone subnets ONLY - Azure forbids mixing with inline subnet{} blocks,
# and inline blocks cannot express delegation / service endpoints.
resource "azurerm_subnet" "aks_node" {
  name                 = "snet-aks-node"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["__SNET_AKS__"]
}

resource "azurerm_subnet" "pe" {
  name                                      = "snet-pe"
  resource_group_name                       = azurerm_resource_group.main.name
  virtual_network_name                      = azurerm_virtual_network.main.name
  address_prefixes                          = ["__SNET_PE__"]
  private_endpoint_network_policies_enabled = false   # azurerm 4.x renames this to a string
}

resource "azurerm_subnet" "aci" {
  name                 = "snet-aci"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["__SNET_ACI__"]

  delegation {
    name = "aci-delegation"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["__SNET_PG__"]
  service_endpoints    = ["Microsoft.Storage"]

  delegation {
    name = "postgres-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]   # note: /join/
    }
  }
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"   # EXACT name required by the API
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["__SNET_BASTION__"]
}

# Rule 100 is THE critical one. AKS sets EnableFloatingIP=True on the LB, so the LB
# does NOT rewrite the destination port: real traffic hits the node on 80/443 while
# the health probe hits the NodePort. Allow only 30000-32767 and probes pass while
# every real request is silently dropped.
resource "azurerm_network_security_group" "aks_node" {
  name                = "nsg-__P__-aks-node"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  security_rule {
    name                       = "allow-http-https-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-nodeport-inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "30000-32767"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks_node" {
  subnet_id                 = azurerm_subnet.aks_node.id
  network_security_group_id = azurerm_network_security_group.aks_node.id
}

# Zone must exist BEFORE the server so Azure can register the A record.
# Without the vnet link the zone answers for nobody -> silent public fallthrough.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.main.id
  tags                  = local.tags
}
EOF
} > terraform/network/main.tf

cat > terraform/network/outputs.tf <<'EOF'
output "resource_group_name"  { value = azurerm_resource_group.main.name }
output "location"             { value = azurerm_resource_group.main.location }
output "vnet_id"              { value = azurerm_virtual_network.main.id }
output "vnet_name"            { value = azurerm_virtual_network.main.name }
output "aks_subnet_id"        { value = azurerm_subnet.aks_node.id }
output "pe_subnet_id"         { value = azurerm_subnet.pe.id }
output "aci_subnet_id"        { value = azurerm_subnet.aci.id }
output "postgres_subnet_id"   { value = azurerm_subnet.postgres.id }
output "bastion_subnet_id"    { value = azurerm_subnet.bastion.id }
output "postgres_dns_zone_id" { value = azurerm_private_dns_zone.postgres.id }
EOF

# ===============================================================
# 3. PLATFORM  (ACR + Key Vault + private AKS)
# ===============================================================
{ hdr "platform.tfstate" '    random  = { source = "hashicorp/random", version = "~> 3.0" }'
rstate network
tagsblock
cat <<'EOF'

data "azurerm_client_config" "current" {}

locals {
  rg_name  = data.terraform_remote_state.network.outputs.resource_group_name
  location = data.terraform_remote_state.network.outputs.location
}

# ACR + KV names are GLOBALLY unique. ACR/storage: lowercase alnum only, no hyphen.
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

resource "azurerm_container_registry" "main" {
  name                = "acr__P__${random_string.suffix.result}"
  resource_group_name = local.rg_name
  location            = local.location
  sku                 = "Basic"
  admin_enabled       = false          # force identity-based auth, no shared password
  tags                = local.tags
}

# RBAC mode: creating the vault grants NO data access. Officer = rw, User = read only
# (a User cannot delete secrets, which breaks terraform destroy).
resource "azurerm_key_vault" "main" {
  name                       = "kv-__P__-${random_string.suffix.result}"
  resource_group_name        = local.rg_name
  location                   = local.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = false   # true makes a practice env unrebuildable
  soft_delete_retention_days = 7
  tags                       = local.tags
}

resource "azurerm_role_assignment" "acr_push" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "__AKS__"
  location            = local.location
  resource_group_name = local.rg_name
  dns_prefix          = "aks-__P__"
  sku_tier            = "Free"

  private_cluster_enabled = true
  private_dns_zone_id     = "System"   # AKS manages privatelink.<region>.azmk8s.io itself
  oidc_issuer_enabled     = true

  default_node_pool {
    name           = "system"
    node_count     = 1
    vm_size        = "Standard_D2s_v5"   # D2s_v3 is often quota-blocked
    vnet_subnet_id = data.terraform_remote_state.network.outputs.aks_subnet_id
    tags           = local.tags          # REQUIRED: cluster tags do NOT reach the MC_* VMSS
  }

  identity { type = "SystemAssigned" }

  network_profile {
    network_plugin = "kubenet"           # Azure CNI would exhaust a /24 of pod IPs
    service_cidr   = "__SERVICE_CIDR__"  # must NOT overlap the VNet
    dns_service_ip = "__DNS_SERVICE_IP__"
  }

  tags = local.tags
}

# Image pulls are done by KUBELET, not the cluster identity.
# Wrong one => ImagePullBackOff with a role assignment that looks correct.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}
EOF
} > terraform/platform/main.tf

cat > terraform/platform/outputs.tf <<'EOF'
output "acr_name"         { value = azurerm_container_registry.main.name }
output "acr_id"           { value = azurerm_container_registry.main.id }
output "acr_login_server" { value = azurerm_container_registry.main.login_server }
output "key_vault_id"     { value = azurerm_key_vault.main.id }
output "key_vault_name"   { value = azurerm_key_vault.main.name }
output "aks_name"         { value = azurerm_kubernetes_cluster.main.name }
output "aks_id"           { value = azurerm_kubernetes_cluster.main.id }
EOF

# ===============================================================
# 4. POSTGRES
# ===============================================================
{ hdr "postgres.tfstate" '    random  = { source = "hashicorp/random", version = "~> 3.0" }'
rstate network
rstate platform
tagsblock
cat <<'EOF'

locals {
  rg_name  = data.terraform_remote_state.network.outputs.resource_group_name
  location = data.terraform_remote_state.network.outputs.location
}

resource "random_password" "pg" {
  length           = 24
  special          = true
  override_special = "!#$%*-_"   # avoid @ and / which break connection strings
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                = "__PG__"
  resource_group_name = local.rg_name
  location            = local.location
  version             = "14"

  administrator_login    = "pgadminuser"   # cannot be admin/root/guest/public or start pg_
  administrator_password = random_password.pg.result

  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768
  zone       = "1"

  # These three together = VNet-integrated mode. All required as a set.
  public_network_access_enabled = false
  delegated_subnet_id           = data.terraform_remote_state.network.outputs.postgres_subnet_id
  private_dns_zone_id           = data.terraform_remote_state.network.outputs.postgres_dns_zone_id

  backup_retention_days = 7
  tags                  = local.tags
}

resource "azurerm_postgresql_flexible_server_database" "employeeapp" {
  name      = "employeeapp"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

resource "azurerm_key_vault_secret" "pg_password" {
  name         = "postgres-admin-password"
  value        = random_password.pg.result
  key_vault_id = data.terraform_remote_state.platform.outputs.key_vault_id
}

resource "azurerm_key_vault_secret" "pg_fqdn" {
  name         = "postgres-fqdn"
  value        = azurerm_postgresql_flexible_server.main.fqdn
  key_vault_id = data.terraform_remote_state.platform.outputs.key_vault_id
}
EOF
} > terraform/postgres/main.tf

cat > terraform/postgres/outputs.tf <<'EOF'
output "pg_fqdn"          { value = azurerm_postgresql_flexible_server.main.fqdn }
output "pg_admin_login"   { value = azurerm_postgresql_flexible_server.main.administrator_login }
output "pg_database_name" { value = azurerm_postgresql_flexible_server_database.employeeapp.name }
EOF

# ===============================================================
# 5. JUMPHOST  (NAT gateway + VM. NO Bastion - see RUNBOOK 3-IP cap)
# ===============================================================
{ hdr "jumphost.tfstate" '    tls     = { source = "hashicorp/tls", version = "~> 4.0" }'
rstate network
rstate platform
tagsblock
cat <<'EOF'

locals {
  rg_name  = data.terraform_remote_state.network.outputs.resource_group_name
  location = data.terraform_remote_state.network.outputs.location
}

# A VM with no public IP has NO outbound internet (Azure retired default outbound
# access). Without this the agent cannot reach dev.azure.com and goes Offline.
resource "azurerm_public_ip" "nat" {
  name                = "pip-__P__-nat"
  resource_group_name = local.rg_name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "main" {
  name                = "natgw-__P__"
  resource_group_name = local.rg_name
  location            = local.location
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "pe" {
  subnet_id      = data.terraform_remote_state.network.outputs.pe_subnet_id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

resource "tls_private_key" "jumphost" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_network_interface" "jumphost" {
  name                = "nic-__P__-jumphost"
  resource_group_name = local.rg_name
  location            = local.location
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.terraform_remote_state.network.outputs.pe_subnet_id
    private_ip_address_allocation = "Dynamic"
    # deliberately NO public_ip_address_id - the policy forbids it
  }
}

resource "azurerm_linux_virtual_machine" "jumphost" {
  name                              = "__VM__"
  resource_group_name               = local.rg_name
  location                          = local.location
  size                              = "Standard_B2s_v2"
  admin_username                    = "azureuser"
  network_interface_ids             = [azurerm_network_interface.jumphost.id]
  vm_agent_platform_updates_enabled = true   # Azure sets this; declaring it avoids perpetual drift
  tags                              = local.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.jumphost.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 64   # 30GB default fills up with docker + agent + tf plugins
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_key_vault_secret" "jumphost_ssh_key" {
  name         = "jumphost-ssh-private-key"
  value        = tls_private_key.jumphost.private_key_pem
  key_vault_id = data.terraform_remote_state.platform.outputs.key_vault_id
}
EOF
} > terraform/jumphost/main.tf

cat > terraform/jumphost/outputs.tf <<'EOF'
output "jumphost_private_ip" { value = azurerm_network_interface.jumphost.private_ip_address }
output "jumphost_name"       { value = azurerm_linux_virtual_machine.jumphost.name }
EOF

# ===============================================================
# 6. ACI  (backend container, private IP, locked to AKS subnet)
# ===============================================================
{ hdr "aci.tfstate"
rstate network
rstate platform
rstate postgres
tagsblock
cat <<'EOF'

data "azurerm_key_vault_secret" "pg_password" {
  name         = "postgres-admin-password"
  key_vault_id = data.terraform_remote_state.platform.outputs.key_vault_id
}

locals {
  rg_name  = data.terraform_remote_state.network.outputs.resource_group_name
  location = data.terraform_remote_state.network.outputs.location
}

# THIS is "backend accepts requests only from the frontend".
resource "azurerm_network_security_group" "aci" {
  name                = "nsg-__P__-aci"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags

  security_rule {
    name                       = "allow-from-aks-subnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8000"
    source_address_prefix      = "__SNET_AKS__"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-all-other-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aci" {
  subnet_id                 = data.terraform_remote_state.network.outputs.aci_subnet_id
  network_security_group_id = azurerm_network_security_group.aci.id
}

resource "azurerm_user_assigned_identity" "aci" {
  name                = "id-__P__-aci"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_role_assignment" "aci_acr_pull" {
  scope                = data.terraform_remote_state.platform.outputs.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aci.principal_id
}

resource "azurerm_container_group" "backend" {
  name                = "aci-__P__-backend"
  location            = local.location
  resource_group_name = local.rg_name
  os_type             = "Linux"
  ip_address_type     = "Private"
  subnet_ids          = [data.terraform_remote_state.network.outputs.aci_subnet_id]
  restart_policy      = "Always"
  tags                = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aci.id]
  }

  image_registry_credential {
    server                    = data.terraform_remote_state.platform.outputs.acr_login_server
    user_assigned_identity_id = azurerm_user_assigned_identity.aci.id
  }

  container {
    name   = "backend"
    image  = "${data.terraform_remote_state.platform.outputs.acr_login_server}/backend:${var.backend_image_tag}"
    cpu    = "0.5"
    memory = "1.0"

    ports {
      port     = 8000
      protocol = "TCP"
    }

    # NOTE: DBUSERNAME, not DBUSER. config/dbConfig.js reads process.env.DBUSERNAME.
    # Wrong name -> undefined -> Postgres 28P01 "auth_failed" (reads like a bad password).
    environment_variables = {
      APPLICATION_HOST = "0.0.0.0"
      APPLICATION_PORT = "8000"
      DBDIALECT        = "postgres"
      DBHOST           = data.terraform_remote_state.postgres.outputs.pg_fqdn
      DBPORT           = "5432"
      DBNAME           = data.terraform_remote_state.postgres.outputs.pg_database_name
      DBUSERNAME       = data.terraform_remote_state.postgres.outputs.pg_admin_login
      WHITELIST_URLS   = "http://${var.ingress_public_ip}"
    }

    secure_environment_variables = {
      DBPASSWORD = data.azurerm_key_vault_secret.pg_password.value
    }
  }

  # Without this ACI starts pulling before it has AcrPull
  depends_on = [azurerm_role_assignment.aci_acr_pull]
}
EOF
} > terraform/aci/main.tf

cat > terraform/aci/variables.tf <<'EOF'
variable "backend_image_tag" { type = string }
variable "ingress_public_ip" { type = string }
EOF

cat > terraform/aci/outputs.tf <<'EOF'
output "aci_private_ip" { value = azurerm_container_group.backend.ip_address }
EOF

# ===============================================================
# PIPELINES
# ===============================================================
gen_build_pipeline () {  # $1 name  $2 src url  $3 srcdir  $4 patch-steps-file
cat <<EOF
trigger: none

pool:
  name: __AGENT_POOL__

variables:
  acrName: __ACR__
  imageName: $1
  imageTag: \$(Build.BuildId)
  srcDir: \$(Build.SourcesDirectory)/$3

steps:
- checkout: none

- script: |
    rm -rf \$(srcDir)
    git clone $2 \$(srcDir)
  displayName: 'Clone $1 source'

$(cat "$4")

- task: AzureCLI@2
  displayName: 'Build and push to ACR'
  inputs:
    azureSubscription: '__SERVICE_CONNECTION__'
    scriptType: bash
    scriptLocation: inlineScript
    workingDirectory: \$(srcDir)
    inlineScript: |
      az acr login --name \$(acrName)
      docker build -t \$(acrName).azurecr.io/\$(imageName):\$(imageTag) .
      docker push \$(acrName).azurecr.io/\$(imageName):\$(imageTag)
      echo "PUSHED: \$(acrName).azurecr.io/\$(imageName):\$(imageTag)"
EOF
}

# --- patch steps. EVERY sed step ends in grep: sed exits 0 when it matches nothing.
cat > /tmp/patch_backend <<'EOF'
- script: |
    cd $(srcDir)
    npm install pg pg-hstore --save
  displayName: 'Add Postgres driver (app ships with MySQL)'

- script: |
    cd $(srcDir)
    sed -i '/dialect: process.env.DBDIALECT/a\    dialectOptions: { ssl: { require: true, rejectUnauthorized: false } },' config/dbConfig.js
    grep -A2 "dialect:" config/dbConfig.js
  displayName: 'Enable SSL (Azure Postgres requires it)'

- script: |
    cd $(srcDir)
    cat > .sequelizerc << 'RCEOF'
    const path = require('path');
    module.exports = {
      'config': path.resolve('config', 'dbConfig.js'),
      'models-path': path.resolve('models'),
      'seeders-path': path.resolve('seeders'),
      'migrations-path': path.resolve('migrations')
    };
    RCEOF
    cat .sequelizerc
  displayName: 'Point sequelize-cli at the real DB config'
EOF

cat > /tmp/patch_frontend <<'EOF'
- script: |
    cd $(srcDir)
    sed -i '/^RUN npm run build/i ENV PUBLIC_URL=/emp' Dockerfile
    sed -i 's|src="env.js"|src="%PUBLIC_URL%/env.js"|' public/index.html
    sed -i 's|href="favicon.ico"|href="%PUBLIC_URL%/favicon.ico"|' public/index.html
    sed -i 's|<Router>|<Router basename={process.env.PUBLIC_URL}>|' src/App.js
    echo "--- verify ---"
    grep -n "PUBLIC_URL" Dockerfile public/index.html src/App.js
  displayName: 'Serve the app under /emp'
EOF

cat > /tmp/patch_todo <<'EOF'
- script: |
    cd $(srcDir)
    sed -i 's|action="/add"|action="/to-do/add"|g' templates/base.html
    sed -i 's|/update/|/to-do/update/|g' templates/base.html
    sed -i 's|/delete/|/to-do/delete/|g' templates/base.html
    sed -i 's|url_for("index")|"/to-do/"|g' app.py
    echo "--- verify ---"
    grep -n "to-do" templates/base.html app.py
  displayName: 'Serve the app under /to-do'
EOF

gen_build_pipeline backend  "__SRC_BACKEND__"  backend-src  /tmp/patch_backend  > pipelines/backend-pipeline.yml
gen_build_pipeline frontend "__SRC_FRONTEND__" frontend-src /tmp/patch_frontend > pipelines/frontend-pipeline.yml
gen_build_pipeline todo     "__SRC_TODO__"     todo-src     /tmp/patch_todo     > pipelines/todo-app-pipeline.yml
rm -f /tmp/patch_backend /tmp/patch_frontend /tmp/patch_todo

cat > pipelines/nginx-ingress-pipeline.yml <<'EOF'
trigger: none

pool:
  name: __AGENT_POOL__

steps:
- checkout: none

- task: AzureCLI@2
  displayName: 'Install nginx ingress controller'
  inputs:
    azureSubscription: '__SERVICE_CONNECTION__'
    scriptType: bash
    scriptLocation: inlineScript
    inlineScript: |
      set -e
      # HOME is not reliably /root on the agent -> kubectl falls back to
      # localhost:8080 "connection refused". Set both explicitly.
      export HOME=/root
      export KUBECONFIG=/root/.kube/config

      az aks get-credentials -g __WORK_RG__ -n __AKS__ --overwrite-existing

      helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
      helm repo update

      # Probe path MUST return 200 on the NodePort. nginx serves /healthz on port
      # 10254, NOT on 80 - probing /healthz or / gives 404, LB marks the node
      # unhealthy, and every real request is silently dropped while a direct
      # NodePort curl still returns 200.
      helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.replicaCount=1 \
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/to-do

      echo "waiting for public IP..."
      for i in $(seq 1 30); do
        IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
             -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        [ -n "$IP" ] && { echo "INGRESS_PUBLIC_IP=$IP"; break; }
        sleep 10
      done

      kubectl get svc -n ingress-nginx
EOF

# ===============================================================
# KUBERNETES MANIFESTS
# ===============================================================
cat > apps/employee-todo/namespace.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: employee-todo
EOF

cat > apps/employee-todo/frontend-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: employee-todo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: frontend
        image: __ACR__.azurecr.io/frontend:__TAG_FRONTEND__
        ports:
        - containerPort: 80
        env:
        # NO /api suffix - the React code already appends /api/v1/employees
        - name: API_BASE_URL
          value: "http://__INGRESS_IP__/emp"
EOF

cat > apps/employee-todo/frontend-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: frontend-service
  namespace: employee-todo
spec:
  selector:
    app: frontend
  ports:
  - port: 80
    targetPort: 80
EOF

cat > apps/employee-todo/todo-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: todo
  namespace: employee-todo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: todo
  template:
    metadata:
      labels:
        app: todo
    spec:
      containers:
      - name: todo
        image: __ACR__.azurecr.io/todo:__TAG_TODO__
        ports:
        - containerPort: 5000
EOF

cat > apps/employee-todo/todo-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: todo-service
  namespace: employee-todo
spec:
  selector:
    app: todo
  ports:
  - port: 5000
    targetPort: 5000
EOF

# No selector => Kubernetes does NOT auto-generate Endpoints, so we supply them
# manually pointing at ACI's private IP. This is how a K8s Service fronts a
# workload that is not in the cluster at all.
cat > apps/employee-todo/backend-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: backend-service
  namespace: employee-todo
spec:
  ports:
  - port: 8000
    targetPort: 8000
EOF

cat > apps/employee-todo/backend-endpoints.yaml <<'EOF'
apiVersion: v1
kind: Endpoints
metadata:
  name: backend-service
  namespace: employee-todo
subsets:
- addresses:
  - ip: __ACI_IP__
  ports:
  - port: 8000
EOF

cat > apps/employee-todo/ingress-frontend-todo.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-frontend-todo
  namespace: employee-todo
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /emp(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: frontend-service
            port:
              number: 80
      - path: /to-do(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: todo-service
            port:
              number: 5000
EOF

cat > apps/employee-todo/ingress-backend.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-backend
  namespace: employee-todo
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /api/$2
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /emp/api(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: backend-service
            port:
              number: 8000
EOF

# Kustomize SILENTLY ignores any file not listed here.
cat > apps/employee-todo/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- namespace.yaml
- frontend-deployment.yaml
- frontend-service.yaml
- todo-deployment.yaml
- todo-service.yaml
- backend-service.yaml
- backend-endpoints.yaml
- ingress-frontend-todo.yaml
- ingress-backend.yaml
EOF

cat > .gitignore <<'EOF'
.terraform/
*.tfstate
*.tfstate.backup
crash.log
spn.env
*.pem
CREDENTIALS.md
EOF

# ===============================================================
# SUBSTITUTE
# ===============================================================
FILES=$(find terraform pipelines apps -type f \( -name '*.tf' -o -name '*.tfvars' -o -name '*.yml' -o -name '*.yaml' \))

subst () { [ -n "$2" ] && sed -i "s|$1|$2|g" $FILES || true; }

subst __TFSTATE_RG__        "$TFSTATE_RG"
subst __TFSTATE_SA__        "$TFSTATE_SA"
subst __TFSTATE_CONTAINER__ "$TFSTATE_CONTAINER"
subst __LOC__               "$LOC"
subst __P__                 "$P"
subst __WORK_RG__           "$WORK_RG"
subst __VNET__              "$VNET"
subst __AKS__               "$AKS"
subst __PG__                "$PG"
subst __VM__                "$VM"
subst __BU__                "$BU_TAG"
subst __CC__                "$CC_TAG"
subst __VNET_CIDR__         "$VNET_CIDR"
subst __SNET_AKS__          "$SNET_AKS"
subst __SNET_PE__           "$SNET_PE"
subst __SNET_ACI__          "$SNET_ACI"
subst __SNET_PG__           "$SNET_PG"
subst __SNET_BASTION__      "$SNET_BASTION"
subst __SERVICE_CIDR__      "$SERVICE_CIDR"
subst __DNS_SERVICE_IP__    "$DNS_SERVICE_IP"
subst __AGENT_POOL__        "$AGENT_POOL"
subst __SERVICE_CONNECTION__ "$SERVICE_CONNECTION"
subst __SRC_FRONTEND__      "$SRC_FRONTEND"
subst __SRC_BACKEND__       "$SRC_BACKEND"
subst __SRC_TODO__          "$SRC_TODO"
subst __ACR__               "$ACR"
subst __INGRESS_IP__        "$INGRESS_IP"
subst __ACI_IP__            "$ACI_IP"
subst __TAG_FRONTEND__      "$TAG_FRONTEND"
subst __TAG_BACKEND__       "$TAG_BACKEND"
subst __TAG_TODO__          "$TAG_TODO"

echo "Generated into $REPO"
echo
echo "Placeholders still unresolved (fill vars.env and re-run as you learn them):"
grep -rho '__[A-Z_]*__' terraform pipelines apps 2>/dev/null | sort -u || echo "  (none)"
