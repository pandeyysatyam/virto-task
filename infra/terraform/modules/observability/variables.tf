variable "name" {
  type = string
}

variable "log_groups" {
  type    = list(string)
  default = ["platform", "frontend"]
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "kms_key_arn" {
  description = "Key for log and SNS encryption. The key policy must allow the logs service."
  type        = string
  default     = null
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "alb_arn_suffix" {
  type    = string
  default = null
}

variable "target_group_arn_suffixes" {
  type    = map(string)
  default = {}
}

variable "rds_instance_id" {
  type    = string
  default = null
}

variable "ecs_cluster_name" {
  type    = string
  default = null
}


variable "enable_alb_alarms" {
  type    = bool
  default = false
}

variable "enable_rds_alarms" {
  type    = bool
  default = false
}

variable "enable_ecs_alarms" {
  type    = bool
  default = false
}
