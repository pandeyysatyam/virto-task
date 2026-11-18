variable "name" {
  type = string
}

variable "data_subnet_ids" {
  type = list(string)
}

variable "db_security_group_id" {
  type = string
}

variable "cache_security_group_id" {
  type = string
}

variable "search_security_group_id" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "db_engine_version" {
  type    = string
  default = "18"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "db_allocated_storage" {
  type    = number
  default = 50
}

variable "db_max_allocated_storage" {
  type    = number
  default = 200
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 14
}

variable "db_name" {
  type    = string
  default = "virto"
}

variable "db_username" {
  type    = string
  default = "virto"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "cache_engine_version" {
  type    = string
  default = "8.1"
}

variable "cache_node_type" {
  type    = string
  default = "cache.t4g.small"
}

variable "cache_nodes" {
  type    = number
  default = 2
}

variable "cache_password" {
  type      = string
  sensitive = true
}

variable "enable_opensearch" {
  type    = bool
  default = true
}

variable "opensearch_engine_version" {
  type    = string
  default = "OpenSearch_2.19"
}

variable "opensearch_instance_type" {
  type    = string
  default = "t3.medium.search"
}

variable "opensearch_instance_count" {
  type    = number
  default = 2
}

variable "opensearch_master_user" {
  type    = string
  default = "virto"
}

variable "opensearch_master_password" {
  type      = string
  sensitive = true
  default   = null
}
