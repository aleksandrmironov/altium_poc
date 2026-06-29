output "app_instance_id" {
  description = "EC2 app instance ID"
  value       = aws_instance.app.id
}

output "mysql_instance_id" {
  description = "EC2 MySQL instance ID"
  value       = aws_instance.mysql.id
}
