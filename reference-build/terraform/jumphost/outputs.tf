output "jumphost_private_ip" {
  value = azurerm_network_interface.jumphost.private_ip_address
}

output "jumphost_name" {
  value = azurerm_linux_virtual_machine.jumphost.name
}


