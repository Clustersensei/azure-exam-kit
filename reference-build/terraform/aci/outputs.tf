output "aci_private_ip" {
  value = azurerm_container_group.backend.ip_address
}
