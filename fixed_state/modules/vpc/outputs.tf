output "vpc_id" {
  description = "VPC ID (passed through from variable)"
  value       = var.vpc_id
}

output "subnet_ids" {
  description = "All subnet IDs — [alb_nat, app, mysql]"
  value       = var.subnet_ids
}

output "alb_nat_subnet_id" {
  description = "Subnet for ALB + NAT Gateway — retains IGW route"
  value       = var.subnet_ids[0]
}

output "app_subnet_id" {
  description = "Subnet for EC2 app instance — routed via NAT GW"
  value       = var.subnet_ids[1]
}

output "mysql_subnet_id" {
  description = "Subnet for EC2 MySQL instance — routed via NAT GW"
  value       = var.subnet_ids[2]
}

output "nat_gw_id" {
  description = "NAT Gateway ID"
  value       = aws_nat_gateway.main.id
}
