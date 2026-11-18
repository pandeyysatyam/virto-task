# Dummy values for planning the production stack against Floci
account_id          = "000000000000"
region              = "us-east-1"
environment         = "prodsim"
shop_domain         = "shop.virto.test"
admin_domain        = "admin.virto.test"
route53_zone_id     = "REPLACED_BY_SCRIPT"
admin_allowed_cidrs = ["10.0.0.0/8"]
alert_emails        = []
github_repository   = "example/virto-commerce-devops"
platform_image      = "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/virto-local/platform:3.1076.13-b16.0.13"
frontend_image      = "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/virto-local/frontend:2.59.1"
