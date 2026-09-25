output "subscription_id" {
  value = data.azurerm_subscription.current.subscription_id
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "location" {
  value = azurerm_resource_group.main.location
}

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "vnet_name" {
  value = azurerm_virtual_network.main.name
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks_node.id
}

output "pe_subnet_id" {
  value = azurerm_subnet.pe.id
}

output "aci_subnet_id" {
  value = azurerm_subnet.aci.id
}

output "postgres_subnet_id" {
  value = azurerm_subnet.postgres.id
}

output "bastion_subnet_id" {
  value = azurerm_subnet.bastion.id
}

output "postgres_dns_zone_id" {
  value = azurerm_private_dns_zone.postgres.id
}


