# Terraform override file. scripts/plan-prod-on-floci.sh copies envs/aws-prod
# into a temporary folder, drops this file next to it and runs plan/apply
# against Floci. The real aws-prod folder is never modified, so emulator
# settings can not leak into the production configuration.

terraform {
  backend "local" {}
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  allowed_account_ids         = ["000000000000"]
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = false # lets allowed_account_ids check against Floci STS
  s3_use_path_style           = true

  endpoints {
    acm                    = "http://localhost:4566"
    applicationautoscaling = "http://localhost:4566"
    backup                 = "http://localhost:4566"
    cloudwatch             = "http://localhost:4566"
    ec2                    = "http://localhost:4566"
    ecr                    = "http://localhost:4566"
    ecs                    = "http://localhost:4566"
    efs                    = "http://localhost:4566"
    elasticache            = "http://localhost:4566"
    elbv2                  = "http://localhost:4566"
    iam                    = "http://localhost:4566"
    kms                    = "http://localhost:4566"
    logs                   = "http://localhost:4566"
    opensearch             = "http://localhost:4566"
    rds                    = "http://localhost:4566"
    route53                = "http://localhost:4566"
    s3                     = "http://localhost:4566"
    secretsmanager         = "http://localhost:4566"
    servicediscovery       = "http://localhost:4566"
    sns                    = "http://localhost:4566"
    ssm                    = "http://localhost:4566"
    sts                    = "http://localhost:4566"
  }
}
