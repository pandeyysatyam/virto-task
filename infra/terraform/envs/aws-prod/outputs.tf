output "shop_url" {
  value = "https://${var.shop_domain}"
}

output "admin_url" {
  value = "https://${var.admin_domain}"
}

output "alb_dns_name" {
  value = module.app.alb_dns_name
}

output "ecr_repositories" {
  value = module.registry.repository_urls
}

output "deploy_role_arn" {
  value = module.iam.deploy_role_arn
}

output "backup_bucket" {
  value = module.storage.backup_bucket_name
}
