output "pg_fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "pg_admin_login" {
  value = azurerm_postgresql_flexible_server.main.administrator_login
}

output "pg_database_name" {
  value = azurerm_postgresql_flexible_server_database.employeeapp.name
}

