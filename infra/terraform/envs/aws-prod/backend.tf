# Remote state in S3 with native lock file (Terraform 1.10+), no DynamoDB table needed.
# The bucket is created once by hand or by a bootstrap stack, with versioning,
# SSE-KMS and a bucket policy that only allows the platform team and the CI role.
# Values are passed at init time so no account details are committed:
#
#   terraform init -backend-config=backend.hcl
#
# backend.hcl (not committed):
#   bucket       = "<state-bucket>"
#   key          = "virto/prod/terraform.tfstate"
#   region       = "ap-south-1"
#   encrypt      = true
#   use_lockfile = true

terraform {
  backend "s3" {}
}
