output "alb_sg_id" {
  description = "ALB security group ID"
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "App EC2 security group ID"
  value       = aws_security_group.app.id
}

output "mysql_sg_id" {
  description = "MySQL EC2 security group ID"
  value       = aws_security_group.mysql.id
}
