variable "vpc_id" {
  type        = string
  description = "VPC ID — from initial_state output"
}

variable "subnet_ids" {
  type        = list(string)
  description = <<-EOT
    List of 3 existing subnet IDs for AZ spread — no public/private segregation.
    All three are flat subnets. Routing distinction is route-table-only:
      [0] ALB + NAT GW subnet — keeps IGW route (required for internet-facing ALB)
      [1] App EC2 subnet      — assigned rt-app-fixed (NAT GW egress)
      [2] MySQL EC2 subnet    — assigned rt-app-fixed (NAT GW egress)
    Populated by scripts/import_fixed.sh from awslocal query.
  EOT
}

variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "environment" {
  type        = string
  description = "Environment tag value"
}
