output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "cache_secret_arn" {
  value = aws_secretsmanager_secret.cache.arn
}

output "admin_secret_arn" {
  value = aws_secretsmanager_secret.admin.arn
}

output "search_secret_arn" {
  value = aws_secretsmanager_secret.search.arn
}

output "search_password" {
  value     = random_password.search.result
  sensitive = true
}

output "secret_arns" {
  value = [
    aws_secretsmanager_secret.db.arn,
    aws_secretsmanager_secret.cache.arn,
    aws_secretsmanager_secret.search.arn,
    aws_secretsmanager_secret.admin.arn,
  ]
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

output "cache_password" {
  value     = random_password.cache.result
  sensitive = true
}

output "parameter_arns" {
  value = [for p in aws_ssm_parameter.config : p.arn]
}
