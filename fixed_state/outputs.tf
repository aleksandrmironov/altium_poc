output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.alb.alb_dns_name
}

output "alb_arn" {
  description = "ALB ARN — used for validate_fixed_state.sh"
  value       = module.alb.alb_arn
}

output "app_instance_id" {
  description = "EC2 app instance ID"
  value       = module.compute.app_instance_id
}

output "mysql_instance_id" {
  description = "EC2 MySQL instance ID"
  value       = module.compute.mysql_instance_id
}
