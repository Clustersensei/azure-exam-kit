terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.0" }
  }
  backend "azurerm" {
    resource_group_name  = "lne-employee-to-do-rg"
    storage_account_name = "tfstate300"
    container_name       = "tfstate"
    key                  = "aci.tfstate"
  }
}

provider "azurerm" {
  features {}
}

data "terraform_remote_state" "network" {
  backend = "azurerm"
  config = {
    resource_group_name  = "lne-employee-to-do-rg"
    storage_account_name = "tfstate300"
    container_name       = "tfstate"
    key                  = "network.tfstate"
  }
}

data "terraform_remote_state" "platform" {
  backend = "azurerm"
  config = {
    resource_group_name  = "lne-employee-to-do-rg"
    storage_account_name = "tfstate300"
    container_name       = "tfstate"
    key                  = "platform.tfstate"
  }
}

data "terraform_remote_state" "postgres" {
  backend = "azurerm"
  config = {
    resource_group_name  = "lne-employee-to-do-rg"
    storage_account_name = "tfstate300"
    container_name       = "tfstate"
    key                  = "postgres.tfstate"
  }
}

data "azurerm_key_vault_secret" "pg_password" {
  name         = "postgres-admin-password"
  key_vault_id = data.terraform_remote_state.platform.outputs.key_vault_id
}

locals {
  rg_name  = data.terraform_remote_state.network.outputs.resource_group_name
  location = data.terraform_remote_state.network.outputs.location

  tags = {
    "Business Unit" = "Engineering"
    "Cost Center"   = "CC-1001"
  }
}

# Backend accepts traffic ONLY from the AKS node subnet
resource "azurerm_network_security_group" "aci" {
  name                = "nsg-lne-aci"
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
    source_address_prefix      = "10.0.1.0/24"
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
  name                = "id-lne-aci"
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
  name                = "aci-lne-backend"
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

  depends_on = [azurerm_role_assignment.aci_acr_pull]
}
