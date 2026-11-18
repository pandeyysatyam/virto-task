variable "name" {
  type = string
}

variable "backup_retention_days" {
  type    = number
  default = 90
}

variable "kms_deletion_window_days" {
  type    = number
  default = 30
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete a non-empty bucket. Only for throwaway environments."
  type        = bool
  default     = false
}

variable "enforce_tls_bucket_policy" {
  type    = bool
  default = true
}

variable "enable_efs" {
  type    = bool
  default = false
}

variable "efs_subnet_ids" {
  type    = list(string)
  default = []
}

variable "efs_security_group_id" {
  type    = string
  default = null
}
