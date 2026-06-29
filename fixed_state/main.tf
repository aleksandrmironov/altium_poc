# fixed_state/main.tf

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
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

module "vpc" {
  source      = "./modules/vpc"
  vpc_id      = var.vpc_id
  subnet_ids  = var.subnet_ids
  aws_region  = var.aws_region
  environment = var.environment
}

module "security_groups" {
  source               = "./modules/security_groups"
  vpc_id               = module.vpc.vpc_id
  allowed_ingress_ips  = var.allowed_ingress_ips
  app_egress_cidrs     = var.app_egress_cidrs
  environment          = var.environment
  alb_sg_description   = var.alb_sg_description
  app_sg_description   = var.app_sg_description
  mysql_sg_description = var.mysql_sg_description
}

module "compute" {
  source         = "./modules/compute"
  ami_id         = var.ami_id
  app_subnet_id  = module.vpc.app_subnet_id
  data_subnet_id = module.vpc.mysql_subnet_id
  app_sg_id      = module.security_groups.app_sg_id
  mysql_sg_id    = module.security_groups.mysql_sg_id
  environment    = var.environment
}

module "alb" {
  source              = "./modules/alb"
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.subnet_ids
  alb_sg_id           = module.security_groups.alb_sg_id
  acm_certificate_arn = var.acm_certificate_arn
  environment         = var.environment
}
