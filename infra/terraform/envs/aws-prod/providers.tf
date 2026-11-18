# REAL AWS. Nothing in this folder has been applied as part of the assignment.
# It is validated in CI (fmt, validate, tflint, checkov) and reviewed as code.
# Credentials come from the environment (SSO profile or the GitHub OIDC role),
# never from this repository.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project     = "virto-commerce"
      Environment = var.environment
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}
