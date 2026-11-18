# EMULATOR ONLY. Every AWS call in this folder goes to Floci on localhost:4566.
# The credentials are Floci's dummy "test" keys, not real AWS keys.
# Real AWS configuration lives in ../aws-prod and shares only the modules.

terraform {
  required_version = ">= 1.6"

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

  # Local state on purpose: this environment is disposable.
  backend "local" {
    path = "terraform.tfstate"
  }
}

locals {
  floci = var.floci_endpoint
}

provider "aws" {
  region     = var.region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    cloudwatch     = local.floci
    ec2            = local.floci
    ecr            = local.floci
    iam            = local.floci
    kms            = local.floci
    logs           = local.floci
    s3             = local.floci
    secretsmanager = local.floci
    sns            = local.floci
    ssm            = local.floci
    sts            = local.floci
  }

  default_tags {
    tags = {
      Project     = "virto-commerce"
      Environment = "local"
      ManagedBy   = "terraform"
      Emulated    = "floci"
    }
  }
}
