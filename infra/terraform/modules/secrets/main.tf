# Application secrets in Secrets Manager plus non-secret settings in SSM.
#
# Passwords are generated here with random_password. That means they are
# also in the Terraform state, so the state bucket must be encrypted and
# access to it limited (see envs/aws-prod/backend.tf).

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "_-."
}

resource "random_password" "cache" {
  length  = 40
  special = false
}

# Virto password policy needs upper, lower, digit and a special character
resource "random_password" "admin" {
  length           = 20
  special          = true
  override_special = "_-!"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 1
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.prefix}/db"
  description             = "Virto database credentials and connection string"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username          = var.db_username
    password          = random_password.db.result
    host              = var.db_host
    port              = 5432
    dbname            = var.db_name
    connection_string = "Host=${var.db_host};Port=5432;Database=${var.db_name};Username=${var.db_username};Password=${random_password.db.result};SSL Mode=${var.db_ssl_mode}"
  })
}

resource "aws_secretsmanager_secret" "cache" {
  name                    = "${var.prefix}/cache"
  description             = "Valkey auth token and connection string"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret_version" "cache" {
  secret_id = aws_secretsmanager_secret.cache.id
  secret_string = jsonencode({
    password          = random_password.cache.result
    connection_string = "${var.cache_host}:6379,password=${random_password.cache.result},ssl=${var.cache_tls},abortConnect=false"
  })
}

resource "random_password" "search" {
  length           = 32
  special          = true
  override_special = "_-!"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_secretsmanager_secret" "search" {
  name                    = "${var.prefix}/search"
  description             = "OpenSearch master user for the Virto OpenSearch module"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret_version" "search" {
  secret_id = aws_secretsmanager_secret.search.id
  secret_string = jsonencode({
    username = "virto"
    password = random_password.search.result
  })
}

resource "aws_secretsmanager_secret" "admin" {
  name                    = "${var.prefix}/platform-admin"
  description             = "Virto back office admin login"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.admin.result
  })
}

# Non-secret configuration
resource "aws_ssm_parameter" "config" {
  for_each = var.parameters
  name     = "/${var.prefix}/config/${each.key}"
  type     = "String"
  value    = each.value
}
