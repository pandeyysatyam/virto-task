# Same modules as production, sized and switched for the emulator:
#   - no NAT gateway, EFS, RDS, ElastiCache, OpenSearch, ALB or ECS here.
#     The app itself runs in docker compose; these resources are the AWS
#     side that the local scripts use (secrets, backups, images, logs, alarms).
#   - secrets point to the compose service names (db, cache) without TLS.

locals {
  name   = "virto-local"
  prefix = "virto/local"
}

module "network" {
  source             = "../../modules/network"
  name               = local.name
  region             = var.region
  vpc_cidr           = "10.30.0.0/16"
  azs                = ["${var.region}a", "${var.region}b"]
  enable_nat_gateway = false
  enable_s3_endpoint = false
}

module "storage" {
  source                    = "../../modules/storage"
  name                      = local.name
  force_destroy             = true
  kms_deletion_window_days  = 7
  backup_retention_days     = 30
  enforce_tls_bucket_policy = false # Floci listens on plain http
}

module "secrets" {
  source               = "../../modules/secrets"
  prefix               = local.prefix
  kms_key_arn          = module.storage.kms_key_arn
  recovery_window_days = 0
  db_host              = "db"
  db_ssl_mode          = "Disable"
  cache_host           = "cache"
  cache_tls            = false

  parameters = {
    platform_image   = "ghcr.io/virtocommerce/platform:3.1076.13"
    module_bundle    = "16.0.13"
    frontend_version = "2.59.1"
    search_provider  = "Lucene"
    backup_bucket    = module.storage.backup_bucket_name
  }
}

module "registry" {
  source       = "../../modules/registry"
  name         = local.name
  kms_key_arn  = module.storage.kms_key_arn
  force_delete = true
}

module "observability" {
  source             = "../../modules/observability"
  name               = local.name
  log_retention_days = 7
  kms_key_arn        = module.storage.kms_key_arn
}

module "iam" {
  source              = "../../modules/iam"
  name                = local.name
  ecr_repository_arns = values(module.registry.repository_arns)
  log_group_arns      = module.observability.log_group_arns
  secret_arns         = module.secrets.secret_arns
  parameter_arns      = module.secrets.parameter_arns
  kms_key_arn         = module.storage.kms_key_arn
  backup_bucket_arn   = module.storage.backup_bucket_arn
}
