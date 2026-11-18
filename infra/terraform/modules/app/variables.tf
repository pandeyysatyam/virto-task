variable "name" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "app_subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = map(string)
}

variable "certificate_arn" {
  description = "ACM certificate covering shop_domain and admin_domain"
  type        = string
}

variable "shop_domain" {
  type = string
}

variable "admin_domain" {
  type = string
}

variable "admin_allowed_cidrs" {
  description = "Office or VPN ranges allowed to open the admin UI"
  type        = list(string)
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "alb_logs_bucket" {
  type    = string
  default = null
}

variable "platform_image" {
  description = "Full image reference, for example <account>.dkr.ecr.<region>.amazonaws.com/virto-prod/platform:3.1076.13-b16.0.13"
  type        = string
}

variable "frontend_image" {
  type = string
}

variable "platform_cpu" {
  type    = number
  default = 2048
}

variable "platform_memory" {
  type    = number
  default = 4096
}

variable "platform_min_tasks" {
  type    = number
  default = 2
}

variable "platform_max_tasks" {
  type    = number
  default = 4
}

variable "frontend_min_tasks" {
  type    = number
  default = 2
}

variable "frontend_max_tasks" {
  type    = number
  default = 4
}

variable "execution_role_arn" {
  type = string
}

variable "platform_task_role_arn" {
  type = string
}

variable "frontend_task_role_arn" {
  type = string
}

variable "secret_arns" {
  description = "Map with keys db, cache and search"
  type        = map(string)
}

variable "log_group_names" {
  description = "Map with keys platform and frontend"
  type        = map(string)
}

variable "opensearch_endpoint" {
  type    = string
  default = null
}

variable "efs_file_system_id" {
  type    = string
  default = null
}

variable "efs_access_point_id" {
  type    = string
  default = null
}
