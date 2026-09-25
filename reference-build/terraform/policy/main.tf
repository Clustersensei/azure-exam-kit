terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "lne-employee-to-do-rg"
    storage_account_name = "tfstate300"
    container_name       = "tfstate"
    key                  = "policy.tfstate"
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_subscription" "current" {}

output "subscription_id" {
  value = data.azurerm_subscription.current.subscription_id
} 

resource "azurerm_subscription_policy_assignment" "require_tag" {
  for_each             = toset(var.mandatory_tags)
  name                 = "req-tag-${replace(lower(each.value), " ", "-")}"
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99"
  subscription_id      = data.azurerm_subscription.current.id
  display_name         = "Require ${each.value} tag"

  parameters = jsonencode({
    tagName = {
      value = each.value
    }
  })
}

resource "azurerm_subscription_policy_assignment" "deny_nic_public_ip" {
  name                 = "deny-nic-public-ip"
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/83a86a26-fd1f-447c-b59d-e51f44264114"
  subscription_id      = data.azurerm_subscription.current.id
  display_name         = "Deny public IP on NIC"
}

resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
  subscription_id      = data.azurerm_subscription.current.id
  display_name         = "Allowed locations - India regions"

  parameters = jsonencode({
    listOfAllowedLocations = {
      value = var.allowed_locations
    }
  })
}

