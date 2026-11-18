variable "name" {
  type = string
}

variable "ecr_repository_arns" {
  type = list(string)
}

variable "log_group_arns" {
  type = list(string)
}

variable "secret_arns" {
  type = list(string)
}

variable "parameter_arns" {
  type    = list(string)
  default = []
}

variable "kms_key_arn" {
  type = string
}

variable "backup_bucket_arn" {
  type = string
}

variable "efs_file_system_arn" {
  type    = string
  default = null
}

variable "efs_access_point_arn" {
  type    = string
  default = null
}

variable "create_github_oidc" {
  type    = bool
  default = false
}

variable "github_repository" {
  description = "owner/repo allowed to deploy"
  type        = string
  default     = ""
}

variable "ecs_service_arns" {
  type    = list(string)
  default = []
}
