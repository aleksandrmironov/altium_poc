# modules/compute/main.tf
# EC2 app + MySQL — imported from initial_state, SGs updated in-place via rules.
# Import: bash scripts/import_fixed.sh
#
# PCI fix is in security_groups module (rules inside app-sg / mysql-sg).
# The instances remain associated with the SAME SGs — membership unchanged.
#
# lifecycle ignore_changes rationale:
#   vpc_security_group_ids — SG membership unchanged; same IDs pre- and post-fix.
#                            Terraform computes a spurious diff on import due to
#                            MiniStack state representation. Nothing to update.
#   associate_public_ip_address — immutable after launch (MiniStack + real AWS)
#   subnet_id                   — immutable; stays in original subnet
#   user_data                   — immutable without replacement
#   ami                         — immutable without replacement

resource "aws_instance" "app" {
  ami                         = var.ami_id
  instance_type               = "t3.micro"
  subnet_id                   = var.app_subnet_id
  vpc_security_group_ids      = [var.app_sg_id]
  associate_public_ip_address = false

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y curl
    curl -fsSL https://example.com/install.sh | bash
  EOF

  tags = {
    Name        = "app-instance-fixed"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "fixed"
  }

  lifecycle {
    ignore_changes = [
      vpc_security_group_ids,
      associate_public_ip_address,
      subnet_id,
      user_data,
      ami,
    ]
  }
}

resource "aws_instance" "mysql" {
  ami                         = var.ami_id
  instance_type               = "t3.micro"
  subnet_id                   = var.data_subnet_id
  vpc_security_group_ids      = [var.mysql_sg_id]
  associate_public_ip_address = false

  tags = {
    Name        = "mysql-instance-fixed"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "fixed"
  }

  lifecycle {
    ignore_changes = [
      vpc_security_group_ids,
      associate_public_ip_address,
      subnet_id,
      user_data,
      ami,
    ]
  }
}
