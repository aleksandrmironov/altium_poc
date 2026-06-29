variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "All 3 subnet IDs for ALB — needs ≥2 subnets across AZs"
}

variable "alb_sg_id" {
  type        = string
  description = "ALB security group ID — from security_groups module"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN — read from imported HTTPS listener by import_fixed.sh"
}

variable "environment" {
  type = string
}
