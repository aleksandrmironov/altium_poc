# modules/security_groups/main.tf
# Core PCI 1.3.1 + 1.3.2 fix.
# Imported from initial_state via: make import-fixed
#
# Inline ingress/egress blocks are authoritative — on apply Terraform adds new
# compliant rules and removes old violating ones from the imported SG in a
# single operation. aws_security_group_rule resources are additive only and
# cannot remove existing rules, so they are not used here.
#
# Cycle break: cross-SG references use data source IDs (lookup by name) rather
# than resource refs. Data sources resolve from existing AWS state (post-import)
# and create no resource-to-resource dependency — no cycle possible.
#
# alb-sg port 443 + 80: both open to 0.0.0.0/0.
#   443 — public HTTPS endpoint, unrestricted by design.
#   80  — redirect path only; TCP established, then 301 redirect to HTTPS.
# PCI 1.3.1: port 80 acceptable paired with mandatory redirect. See docs §Extras
# for allowed_ingress_ips restriction if auditor requires further tightening.

# ── Data sources — SG lookup by name for cross-SG rule references ─────────────

data "aws_security_group" "alb" {
  name   = "alb-sg"
  vpc_id = var.vpc_id
}

data "aws_security_group" "app" {
  name   = "app-sg"
  vpc_id = var.vpc_id
}

data "aws_security_group" "mysql" {
  name   = "mysql-sg"
  vpc_id = var.vpc_id
}

# ── Security Groups — inline rules (authoritative) ────────────────────────────

resource "aws_security_group" "alb" {
  name        = "alb-sg"
  description = var.alb_sg_description
  vpc_id      = var.vpc_id

  ingress {
    description = "PCI 1.3.1: HTTPS public endpoint"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP redirect to HTTPS at ALB listener"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # PCI 1.3.2: ALB→EC2 is ALB-initiated — explicit egress required.
  # Uses data source ID (not resource ref) to avoid cycle with app-sg.
  egress {
    description     = "PCI 1.3.2: ALB to app targets only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [data.aws_security_group.app.id]
  }

  tags = {
    Name        = "alb-sg-fixed"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "fixed"
  }
}

resource "aws_security_group" "app" {
  name        = "app-sg"
  description = var.app_sg_description
  vpc_id      = var.vpc_id

  # PCI 1.3.1: inbound from alb-sg by name only — no CIDR sources.
  ingress {
    description     = "PCI 1.3.1: inbound from ALB only via SG name"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [data.aws_security_group.alb.id]
  }

  # PCI 1.3.2: outbound to internet — port 443 to known CIDRs only.
  # IP-based proxy for FQDN control in MiniStack.
  # Network Firewall enforces FQDN restriction on real AWS.
  egress {
    description = "PCI 1.3.2: app EC2 internet egress to known CIDRs only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.app_egress_cidrs
  }

  # PCI 1.3.2: outbound to MySQL — port 3306 to mysql-sg ref only.
  # Uses data source ID to avoid cycle with mysql-sg resource.
  egress {
    description     = "PCI 1.3.2: app EC2 to MySQL only via SG ref"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [data.aws_security_group.mysql.id]
  }

  tags = {
    Name        = "app-sg-fixed"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "fixed"
  }
}

resource "aws_security_group" "mysql" {
  name        = "mysql-sg"
  description = var.mysql_sg_description
  vpc_id      = var.vpc_id

  # PCI 1.3.1: inbound from app-sg by name only — no CIDR sources.
  ingress {
    description     = "PCI 1.3.1: inbound from app EC2 only via SG name"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [data.aws_security_group.app.id]
  }

  # PCI 1.3.2: loopback placeholder — forces Terraform to own egress, removing
  # the AWS default allow-all rule that is injected on every new SG.
  # AWS always adds allow-all egress on SG creation; Terraform removes it only
  # when at least one explicit egress block is declared. 127.0.0.1/32 (loopback)
  # is unreachable from EC2 network interfaces — no real traffic can egress.
  # MiniStack limitation: injects the default allow-all regardless of config;
  # the loopback rule is enforced correctly on real AWS.
  egress {
    description = "PCI 1.3.2: deny-all via loopback (overrides AWS default allow-all)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["127.0.0.1/32"]
  }

  tags = {
    Name        = "mysql-sg-fixed"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "fixed"
  }
}
