# initial_state/main.tf
# ============================================================
# BROKEN PRE-REMEDIATION INFRASTRUCTURE
# Purpose: demonstrate PCI-DSS 1.3.1 and 1.3.2 violations
# DO NOT use as a template — every violation is intentional
# ============================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

# ── Self-signed TLS certificate ───────────────────────────────────────────────

resource "tls_private_key" "self_signed" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self_signed" {
  private_key_pem = tls_private_key.self_signed.private_key_pem

  subject {
    common_name  = "poc.example.com"
    organization = "PCI POC Initial State"
  }

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "self_signed" {
  private_key      = tls_private_key.self_signed.private_key_pem
  certificate_body = tls_self_signed_cert.self_signed.cert_pem

  tags = {
    Name        = "poc-cert-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "172.31.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "default-vpc-simulated"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "igw-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

# ── Default SG — neutralised ──────────────────────────────────────────────────
# MiniStack assigns the default SG to instances regardless of configuration.
# ingress=[] egress=[] removes all rules — deny all traffic through default SG.
# null_resource below also calls modify-network-interface-attribute to replace
# the full SG list, which detaches default and attaches the correct SG atomically.

resource "aws_default_security_group" "default" {
  vpc_id  = aws_vpc.main.id
  ingress = []
  egress  = []
}

# ── Subnets ───────────────────────────────────────────────────────────────────
# VIOLATION CKV_AWS_130: map_public_ip_on_launch = true on all subnets.

resource "aws_subnet" "a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.31.0.0/20"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true # VIOLATION CKV_AWS_130

  tags = {
    Name        = "subnet-a-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

resource "aws_subnet" "b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.31.16.0/20"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true # VIOLATION CKV_AWS_130

  tags = {
    Name        = "subnet-b-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

resource "aws_subnet" "c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.31.32.0/20"
  availability_zone       = "${var.aws_region}c"
  map_public_ip_on_launch = true # VIOLATION CKV_AWS_130

  tags = {
    Name        = "subnet-c-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "rt-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.a.id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.b.id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "c" {
  subnet_id      = aws_subnet.c.id
  route_table_id = aws_route_table.main.id
}

# ── Security Groups — VIOLATIONS ──────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "alb-sg"
  description = "ALB security group — INITIAL STATE VIOLATIONS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "VIOLATION PCI-1.3.1: HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # VIOLATION CKV_AWS_23
  }

  ingress {
    description = "VIOLATION PCI-1.3.1: HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # VIOLATION CKV_AWS_23
  }

  egress {
    description = "VIOLATION PCI-1.3.2: allow-all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # VIOLATION CKV_AWS_25
  }

  tags = {
    Name        = "alb-sg-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

resource "aws_security_group" "app" {
  name        = "app-sg"
  description = "App EC2 security group — INITIAL STATE VIOLATIONS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "VIOLATION PCI-1.3.1: HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # VIOLATION CKV_AWS_23
  }

  egress {
    description = "VIOLATION PCI-1.3.2: allow-all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # VIOLATION CKV_AWS_25
  }

  tags = {
    Name        = "app-sg-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

resource "aws_security_group" "mysql" {
  name        = "mysql-sg"
  description = "MySQL EC2 security group — INITIAL STATE VIOLATIONS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "VIOLATION PCI-1.3.1: MySQL from anywhere"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # VIOLATION CKV_AWS_23
  }

  egress {
    description = "VIOLATION PCI-1.3.2: allow-all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # VIOLATION CKV_AWS_25
  }

  tags = {
    Name        = "mysql-sg-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

# ── EC2 Instances ─────────────────────────────────────────────────────────────
# Instances attach explicit ENIs via network_interface block.
# ENI IDs are known at plan time — null_resource uses them directly.

resource "aws_instance" "app" {
  ami           = var.ami_id
  instance_type = "t3.micro"

  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y curl
    curl -fsSL https://example.com/install.sh | bash
  EOF

  tags = {
    Name        = "app-instance-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

resource "aws_instance" "mysql" {
  ami           = var.ami_id
  instance_type = "t3.micro"

  vpc_security_group_ids = [aws_security_group.mysql.id]

  tags = {
    Name        = "mysql-instance-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

# ── ALB ───────────────────────────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "alb-initial"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.a.id, aws_subnet.b.id, aws_subnet.c.id]

  tags = {
    Name        = "alb-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "app-tg-initial"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 10
  }

  tags = {
    Name        = "app-tg-initial"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "initial-violation"
  }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 80
}

# VIOLATION CKV_AWS_92: port 80 listener forwards instead of redirecting to HTTPS.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward" # VIOLATION CKV_AWS_92
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.self_signed.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
