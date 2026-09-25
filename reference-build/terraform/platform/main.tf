terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "lne-employee-to-do-rg"
    storage_account_name = "tfstate300"
    container_name       = "tfstate"
    key                  = "platform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

data "terraform_remote_state" "network" {
  backend = "azurerm"
  config = {
    resource_group_name  = "lne-employee-to-do-rg"
    storage_account_name = "tfstate300"
    container_name       = "tfstate"
    key                  = "network.tfstate"
  }
}

locals {
  rg_name  = data.terraform_remote_state.network.outputs.resource_group_name
  location = data.terraform_remote_state.network.outputs.location

  tags = {
    "Business Unit" = "Engineering"
    "Cost Center"   = "CC-1001"
  }
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

resource "azurerm_container_registry" "main" {
  name                = "acrlne${random_string.suffix.result}"
  resource_group_name = local.rg_name
  location            = local.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

resource "azurerm_key_vault" "main" {
  name                       = "kv-lne-${random_string.suffix.result}"
  resource_group_name        = local.rg_name
  location                   = local.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = false
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
  name                = "aks-lne-employee-todo"
  location            = local.location
  resource_group_name = local.rg_name
  dns_prefix          = "aks-lne"
  sku_tier            = "Free"

  private_cluster_enabled = true
  private_dns_zone_id     = "System"
  oidc_issuer_enabled     = true

  default_node_pool {
    name           = "system"
    node_count     = 1
    vm_size        = "Standard_D2s_v5"
    vnet_subnet_id = data.terraform_remote_state.network.outputs.aks_subnet_id
    tags           = local.tags
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "kubenet"
    service_cidr   = "10.1.0.0/16"
    dns_service_ip = "10.1.0.10"
  }

  tags = local.tags
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

