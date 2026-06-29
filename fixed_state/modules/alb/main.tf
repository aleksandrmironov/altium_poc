# modules/alb/main.tf
# ALB with PCI-compliant configuration.
# Imported from initial_state via: make import-fixed
#
# Key changes vs initial_state:
#   alb-sg: port 80 open 0.0.0.0/0 for redirect path (see security_groups module)
#   http listener: forward → 301 redirect to HTTPS
#
# Not managed here:
#   TLS/ACM cert — acm_certificate_arn from import_fixed.sh (existing cert kept)
#   TGA          — initial_state owns it, no change needed

resource "aws_lb" "main" {
  name               = "alb-initial"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.subnet_ids

  tags = {
    Name        = "alb-fixed"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "fixed"
  }

  lifecycle {
    ignore_changes = [name]
  }
}

resource "aws_lb_target_group" "app" {
  name     = "app-tg-initial"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 10
  }

  tags = {
    Name        = "app-tg-fixed"
    Environment = var.environment
    ManagedBy   = "terraform"
    State       = "fixed"
  }

  lifecycle {
    ignore_changes = [name]
  }
}

# Port 80: 301 redirect to HTTPS.
# Existing forward listener is deleted by import_fixed.sh before apply
# so Terraform creates this fresh (avoids forward→redirect provider validation error).
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Port 443: cert ARN from import_fixed.sh matches imported state — no diff.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
