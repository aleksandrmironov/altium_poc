variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Environment tag value"
  default     = "initial-violation"
}

variable "ami_id" {
  type        = string
  description = "AMI ID for EC2 instances — any value works in MiniStack"
  default     = "ami-12345678"
}
