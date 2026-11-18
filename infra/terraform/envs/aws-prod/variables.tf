variable "account_id" {
  description = "Target AWS account. The provider refuses to run against any other account."
  type        = string
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "cost_center" {
  type    = string
  default = "ecommerce"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "single_nat_gateway" {
  description = "true saves about 32 USD/month, false removes the NAT as a single point of failure"
  type        = bool
  default     = true
}

variable "shop_domain" {
  type = string
}

variable "admin_domain" {
  type = string
}

variable "route53_zone_id" {
  type = string
}

variable "admin_allowed_cidrs" {
  type = list(string)
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "github_repository" {
  description = "owner/repo that may deploy through GitHub OIDC"
  type        = string
}

variable "platform_image" {
  type = string
}

variable "frontend_image" {
  type = string
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "deletion_protection" {
  description = "Protects RDS and the ALB from terraform destroy. Set false only to tear the environment down."
  type        = bool
  default     = true
}
