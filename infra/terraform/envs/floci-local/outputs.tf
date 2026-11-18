output "vpc_id" {
  value = module.network.vpc_id
}

output "subnets" {
  value = {
    public = module.network.public_subnet_ids
    app    = module.network.app_subnet_ids
    data   = module.network.data_subnet_ids
  }
}

output "security_group_ids" {
  value = module.network.security_group_ids
}

output "backup_bucket" {
  value = module.storage.backup_bucket_name
}

output "kms_key_arn" {
  value = module.storage.kms_key_arn
}

output "secret_ids" {
  value = {
    db     = module.secrets.db_secret_arn
    cache  = module.secrets.cache_secret_arn
    admin  = module.secrets.admin_secret_arn
    search = module.secrets.search_secret_arn
  }
}

output "ecr_repositories" {
  value = module.registry.repository_urls
}

output "log_groups" {
  value = module.observability.log_group_names
}

output "alerts_topic_arn" {
  value = module.observability.alerts_topic_arn
}

output "metric_namespace" {
  value = module.observability.metric_namespace
}

output "iam_roles" {
  value = {
    execution     = module.iam.execution_role_arn
    platform_task = module.iam.platform_task_role_arn
    frontend_task = module.iam.frontend_task_role_arn
  }
}
