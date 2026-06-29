variable "vpc_id" {
  type = string
}

variable "allowed_ingress_ips" {
  type        = list(string)
  description = "Reserved for future use — restricting alb-sg inbound to a finite IP allowlist. See docs/fixed_state.md §Extras."
}

variable "app_egress_cidrs" {
  type = list(string)
  description = <<-EOT
    Destination CIDRs for app EC2 outbound (port 443 only).
    IP-based proxy for FQDN control in MiniStack — Network Firewall enforces
    FQDN restriction on real AWS. Does not apply to alb-sg or mysql-sg.
  EOT
}

variable "environment" {
  type = string
}

variable "alb_sg_description" {
  type        = string
  description = "Actual description of imported alb-sg — prevents description-forced replacement"
}

variable "app_sg_description" {
  type        = string
  description = "Actual description of imported app-sg"
}

variable "mysql_sg_description" {
  type        = string
  description = "Actual description of imported mysql-sg"
}
