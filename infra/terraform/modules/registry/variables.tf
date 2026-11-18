variable "name" {
  type = string
}

variable "repositories" {
  type    = list(string)
  default = ["platform", "frontend"]
}

variable "kms_key_arn" {
  type = string
}

variable "keep_images" {
  type    = number
  default = 20
}

variable "force_delete" {
  type    = bool
  default = false
}
