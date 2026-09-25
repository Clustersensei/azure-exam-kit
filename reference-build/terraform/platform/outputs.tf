output "acr_name" {
  value = azurerm_container_registry.main.name
}

output "acr_id" {
  value = azurerm_container_registry.main.id
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "key_vault_id" {
  value = azurerm_key_vault.main.id
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "aks_id" {
  value = azurerm_kubernetes_cluster.main.id
}

