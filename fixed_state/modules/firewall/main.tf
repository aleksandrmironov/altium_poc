# modules/firewall/main.tf
# AWS Network Firewall — FQDN-based egress control for EC2 app outbound
#
# Scope: inspects only EC2 app → internet traffic (via NAT GW path)
# MySQL egress is blocked by mysql-sg before reaching this layer
# ALB inbound is unaffected — different path (IGW, not NAT GW)
#
# Resources:
#   aws_networkfirewall_rule_group
#     - Type: STATEFUL
#     - FQDN ALLOWLIST via TLS_SNI (no decryption required)
#     - Targets: example.com (startup), secureweb.com (daily ops)
#     - Implicit deny-all for all other destinations
#     - STRICT_ORDER rule evaluation
#
#   aws_networkfirewall_firewall_policy
#     - References rule group
#     - ASYMMETRIC_ROUTING = true
#       Required because return traffic bypasses firewall:
#       outbound: EC2 → FW endpoint → NAT GW → IGW → Internet
#       inbound:  Internet → NAT GW → EC2 (direct, no FW)
#
#   aws_networkfirewall_firewall
#     - Placed in var.firewall_subnet_id (/28 subnet in existing VPC)
#     - Output: firewall endpoint ID (used by vpc module route table)
#
# IMPORTANT: MiniStack does not support aws_networkfirewall_* resources
# Tier 1 (Checkov) and syntax validation work locally
# Tier 3 FQDN smoke tests require a real AWS environment
#
# TODO: implement
