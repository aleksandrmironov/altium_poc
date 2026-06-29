variable "ami_id" {
  type        = string
  description = "AMI ID — any value works in MiniStack"
}

variable "app_subnet_id" {
  type        = string
  description = "Subnet ID for EC2 app instance"
}

variable "data_subnet_id" {
  type        = string
  description = "Subnet ID for EC2 MySQL instance"
}

variable "app_sg_id" {
  type        = string
  description = "App security group ID — from security_groups module"
}

variable "mysql_sg_id" {
  type        = string
  description = "MySQL security group ID — from security_groups module"
}

variable "environment" {
  type        = string
  description = "Environment tag value"
}
