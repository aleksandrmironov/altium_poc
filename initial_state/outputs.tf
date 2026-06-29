output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ALB ARN — used for awslocal listener validation"
  value       = aws_lb.main.arn
}

output "app_instance_id" {
  description = "EC2 app instance ID"
  value       = aws_instance.app.id
}

output "mysql_instance_id" {
  description = "EC2 MySQL instance ID"
  value       = aws_instance.mysql.id
}

output "violations_summary" {
  description = "Summary of PCI violations present in this configuration"
  value       = <<-EOF

  ╔══════════════════════════════════════════════════════════════╗
  ║         INITIAL STATE — PCI VIOLATIONS SUMMARY              ║
  ╠══════════════════════════════════════════════════════════════╣
  ║  PCI 1.3.1 — Inbound not restricted:                        ║
  ║    alb-sg:   port 80  from 0.0.0.0/0                        ║
  ║    alb-sg:   port 443 from 0.0.0.0/0                        ║
  ║    app-sg:   port 80  from 0.0.0.0/0                        ║
  ║    mysql-sg: port 3306 from 0.0.0.0/0                       ║
  ║  PCI 1.3.2 — Outbound not restricted:                       ║
  ║    alb-sg:   egress allow-all                                ║
  ║    app-sg:   egress allow-all                                ║
  ║    mysql-sg: egress allow-all                                ║
  ║  Additional:                                                  ║
  ║    EC2 app:   public IP assigned       (CKV_AWS_8)           ║
  ║    EC2 MySQL: public IP assigned       (CKV_AWS_8)           ║
  ║    Subnets:   auto-assign public IP    (CKV_AWS_130)         ║
  ║    ALB:       port 80 forwards, no redirect (CKV_AWS_92)     ║
  ╠══════════════════════════════════════════════════════════════╣
  ║  Run: make test-static   to see all Checkov failures         ║
  ╚══════════════════════════════════════════════════════════════╝
  EOF
}
