locals {
  name   = "virto-${var.environment}"
  prefix = "virto/${var.environment}"
}

module "network" {
  source                = "../../modules/network"
  name                  = local.name
  region                = var.region
  vpc_cidr              = var.vpc_cidr
  enable_nat_gateway    = true
  single_nat_gateway    = var.single_nat_gateway
  allowed_ingress_cidrs = ["0.0.0.0/0"]
}

module "storage" {
  source                = "../../modules/storage"
  name                  = local.name
  backup_retention_days = 90
  enable_efs            = true
  efs_subnet_ids        = module.network.data_subnet_ids
  efs_security_group_id = module.network.security_group_ids.efs
}

module "secrets" {
  source               = "../../modules/secrets"
  prefix               = local.prefix
  kms_key_arn          = module.storage.kms_key_arn
  recovery_window_days = 30
  db_host              = module.data.db_address
  db_ssl_mode          = "Require"
  cache_host           = module.data.cache_primary_endpoint
  cache_tls            = true

  parameters = {
    platform_image  = var.platform_image
    frontend_image  = var.frontend_image
    module_bundle   = "16.0.13"
    search_provider = "OpenSearch"
    backup_bucket   = module.storage.backup_bucket_name
  }
}

module "registry" {
  source      = "../../modules/registry"
  name        = local.name
  kms_key_arn = module.storage.kms_key_arn
}

module "data" {
  source                   = "../../modules/data"
  name                     = local.name
  data_subnet_ids          = module.network.data_subnet_ids
  db_security_group_id     = module.network.security_group_ids.db
  cache_security_group_id  = module.network.security_group_ids.cache
  search_security_group_id = module.network.security_group_ids.search
  kms_key_arn              = module.storage.kms_key_arn

  db_instance_class   = var.db_instance_class
  deletion_protection = var.deletion_protection
  db_multi_az         = true
  db_password         = module.secrets.db_password
  cache_password      = module.secrets.cache_password
  cache_nodes         = 2
  enable_opensearch   = true

  opensearch_master_password = module.secrets.search_password
}

module "observability" {
  source             = "../../modules/observability"
  name               = local.name
  log_retention_days = 30
  kms_key_arn        = module.storage.kms_key_arn
  alert_emails       = var.alert_emails

  alb_arn_suffix            = module.app.alb_arn_suffix
  target_group_arn_suffixes = module.app.target_group_arn_suffixes
  rds_instance_id           = module.data.db_instance_id
  ecs_cluster_name          = module.app.cluster_name
  enable_alb_alarms         = true
  enable_rds_alarms         = true
  enable_ecs_alarms         = true
}

module "iam" {
  source               = "../../modules/iam"
  name                 = local.name
  ecr_repository_arns  = values(module.registry.repository_arns)
  log_group_arns       = module.observability.log_group_arns
  secret_arns          = module.secrets.secret_arns
  parameter_arns       = module.secrets.parameter_arns
  kms_key_arn          = module.storage.kms_key_arn
  backup_bucket_arn    = module.storage.backup_bucket_arn
  efs_file_system_arn  = module.storage.efs_file_system_arn
  efs_access_point_arn = module.storage.efs_access_point_arn
  create_github_oidc   = true
  github_repository    = var.github_repository
  ecs_service_arns     = module.app.service_arns
}

# TLS certificate for both host names, validated through Route 53
resource "aws_acm_certificate" "this" {
  domain_name               = var.shop_domain
  subject_alternative_names = [var.admin_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.this.domain_validation_options : o.domain_name => o
  }
  zone_id = var.route53_zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

module "app" {
  source              = "../../modules/app"
  name                = local.name
  environment         = var.environment
  region              = var.region
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  app_subnet_ids      = module.network.app_subnet_ids
  security_group_ids  = module.network.security_group_ids
  certificate_arn     = aws_acm_certificate_validation.this.certificate_arn
  shop_domain         = var.shop_domain
  admin_domain        = var.admin_domain
  admin_allowed_cidrs = var.admin_allowed_cidrs
  deletion_protection = var.deletion_protection

  platform_image = var.platform_image
  frontend_image = var.frontend_image

  execution_role_arn     = module.iam.execution_role_arn
  platform_task_role_arn = module.iam.platform_task_role_arn
  frontend_task_role_arn = module.iam.frontend_task_role_arn

  secret_arns = {
    db     = module.secrets.db_secret_arn
    cache  = module.secrets.cache_secret_arn
    search = module.secrets.search_secret_arn
  }
  log_group_names     = module.observability.log_group_names
  opensearch_endpoint = module.data.opensearch_endpoint
  efs_file_system_id  = module.storage.efs_file_system_id
  efs_access_point_id = module.storage.efs_access_point_id
}

resource "aws_route53_record" "shop" {
  zone_id = var.route53_zone_id
  name    = var.shop_domain
  type    = "A"
  alias {
    name                   = module.app.alb_dns_name
    zone_id                = module.app.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "admin" {
  zone_id = var.route53_zone_id
  name    = var.admin_domain
  type    = "A"
  alias {
    name                   = module.app.alb_dns_name
    zone_id                = module.app.alb_zone_id
    evaluate_target_health = true
  }
}

# AWS Backup: daily RDS + EFS snapshots kept 35 days, monthly kept 1 year
resource "aws_backup_vault" "this" {
  name        = "${local.name}-vault"
  kms_key_arn = module.storage.kms_key_arn
}

resource "aws_backup_plan" "this" {
  name = "${local.name}-plan"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 1 * * ? *)"
    lifecycle {
      delete_after = 35
    }
  }

  rule {
    rule_name         = "monthly"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 2 1 * ? *)"
    lifecycle {
      cold_storage_after = 30
      delete_after       = 365
    }
  }
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${local.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "this" {
  name         = "${local.name}-data"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn
  resources = [
    "arn:aws:rds:${var.region}:${var.account_id}:db:${module.data.db_instance_id}",
    module.storage.efs_file_system_arn,
  ]
}
