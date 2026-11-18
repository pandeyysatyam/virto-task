variable "prefix" {
  description = "Path prefix for secrets and parameters, for example virto/prod"
  type        = string
}

variable "kms_key_arn" {
  type = string
}

variable "recovery_window_days" {
  description = "0 deletes immediately (local only). Use 7 to 30 on AWS."
  type        = number
  default     = 7
}

variable "db_username" {
  type    = string
  default = "virto"
}

variable "db_name" {
  type    = string
  default = "virto"
}

variable "db_host" {
  type = string
}

variable "db_ssl_mode" {
  type    = string
  default = "Require"
}

variable "cache_host" {
  type = string
}

variable "cache_tls" {
  type    = bool
  default = true
}

variable "parameters" {
  description = "Plain settings stored in SSM Parameter Store"
  type        = map(string)
  default     = {}
}
