variable "name" {
  description = "Prefix for resource names, for example virto-prod"
  type        = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  description = "Availability zones. Empty list means the first two in the region."
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  type    = bool
  default = true
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "enable_s3_endpoint" {
  type    = bool
  default = true
}

variable "allowed_ingress_cidrs" {
  description = "Who can reach the ALB. 0.0.0.0/0 for a public shop."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
