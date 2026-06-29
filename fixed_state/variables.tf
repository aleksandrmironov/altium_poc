variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "fixed"
}

variable "ami_id" {
  type    = string
  default = "ami-12345678"
}

variable "vpc_id" {
  type        = string
  description = "From initial_state: cd initial_state && tflocal output -raw vpc_id"
}

variable "subnet_ids" {
  type        = list(string)
  description = "3 subnet IDs [public, private-app, private-data] — written by import_fixed.sh"
}

variable "allowed_ingress_ips" {
  type        = list(string)
  description = "Reserved for future use — e.g. restricting alb-sg port 80/443 to a finite IP allowlist. See docs/fixed_state.md §Extras."
  default     = ["10.0.0.0/8"]
}

variable "app_egress_cidrs" {
  type = list(string)
  description = <<-EOT
    Destination CIDRs allowed for app EC2 outbound (port 443 only).
    MiniStack-testable IP-based proxy for FQDN control — Network Firewall
    enforces FQDN restriction on real AWS. IPs are illustrative placeholders
    (domains rotate IPs). See docs/fixed_state.md §Extras for upgrade path.
  EOT
  default = [
    "93.184.216.34/32", # example.com   — illustrative, may drift
    "203.0.113.10/32",  # secureweb.com — RFC 5737 TEST-NET placeholder
  ]
}

variable "alb_sg_description" {
  type        = string
  description = "Auto-populated by import_fixed.sh"
}

variable "app_sg_description" {
  type        = string
  description = "Auto-populated by import_fixed.sh"
}

variable "mysql_sg_description" {
  type        = string
  description = "Auto-populated by import_fixed.sh"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM cert ARN from imported HTTPS listener — auto-populated by import_fixed.sh"
}
