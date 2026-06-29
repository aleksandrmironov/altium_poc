# modules/vpc/main.tf
# No data sources — subnet IDs and VPC ID passed as variables.
# MiniStack data source filters are unreliable (ID normalization issues).
# Resource IDs are resolved by scripts/import_fixed.sh via awslocal.
#
# Subnet layout (all three are flat — no public/private segregation):
#   subnet_ids[0] — ALB + NAT GW. Must retain IGW route (AWS requires IGW
#                   route for internet-facing ALB subnets). rt-initial covers this.
#   subnet_ids[1] — App EC2. Routed via NAT GW (rt-app-fixed).
#   subnet_ids[2] — MySQL EC2. Routed via NAT GW (rt-app-fixed).
#
# True public/private subnet segregation is a Phase 3 item (new custom VPC).
# See FUTURE_STATE.md §Phase 3.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "nat-eip-fixed"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "fixed"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = var.subnet_ids[0] # ALB subnet — NAT GW must be in a subnet with IGW route

  tags = {
    Name        = "nat-gw-fixed"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "fixed"
  }
}

# Route table for compute subnets: outbound via NAT GW.
# Associated with subnet_ids[1] (app EC2) and subnet_ids[2] (MySQL EC2).
# Additive — does not modify initial_state's IGW route table.
resource "aws_route_table" "app" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name        = "rt-app-fixed"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "fixed"
  }
}

resource "aws_route_table_association" "app" {
  subnet_id      = var.subnet_ids[1] # app EC2 subnet
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table_association" "mysql" {
  subnet_id      = var.subnet_ids[2] # MySQL EC2 subnet
  route_table_id = aws_route_table.app.id
}

# Note: firewall subnet + endpoint route are extras (real AWS only).
