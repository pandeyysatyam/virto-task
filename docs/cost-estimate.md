# Estimated AWS monthly cost

> Estimate only. Nothing was deployed, so there is no bill to compare with.
> Prices are AWS public on-demand list prices for **us-east-1** (the region
> with the most published price data), 730 hours per month, before tax and
> before any free tier. ap-south-1 (Mumbai) prices for these services are
> within roughly 5 to 15 percent. Recheck in the AWS Pricing Calculator
> before asking for budget approval.

## Production layout (as in `envs/aws-prod`)

| Item | Sizing | Calculation | USD / month |
|---|---|---|---|
| ECS Fargate, platform | 2 tasks x 2 vCPU, 4 GB | 2 x 730 x (2 x 0.04048 + 4 x 0.004445) | 144 |
| ECS Fargate, frontend | 2 tasks x 0.25 vCPU, 0.5 GB | 2 x 730 x (0.25 x 0.04048 + 0.5 x 0.004445) | 18 |
| RDS PostgreSQL | db.t4g.medium, Multi AZ, 50 GB gp3 | 730 x 0.130 + 50 x 0.23 | 107 |
| OpenSearch | 2 x t3.medium.search, 2 x 20 GB gp3 | 2 x 730 x 0.073 + 40 x 0.122 | 112 |
| ElastiCache Valkey | 2 x cache.t4g.small | 2 x 730 x 0.0256 | 37 |
| Application Load Balancer | 1 ALB, about 2 LCU average | 730 x 0.0225 + 730 x 2 x 0.008 | 28 |
| NAT gateway | 1 (single NAT), 50 GB processed | 730 x 0.045 + 50 x 0.045 | 35 |
| Public IPv4 addresses | ALB (2) + NAT (1) | 3 x 730 x 0.005 | 11 |
| CloudWatch | 20 GB logs, Container Insights, 9 alarms | 20 x 0.50 + about 13 + 0.9 | 25 |
| Data transfer out | 100 GB to internet | 100 x 0.09 | 9 |
| AWS Backup + RDS snapshots | about 60 GB | | 6 |
| EFS | 10 GB elastic | 10 x 0.30 + requests | 4 |
| Secrets Manager + KMS | 4 secrets, 1 key | 4 x 0.40 + 1 + requests | 3 |
| S3 backups | 50 GB with lifecycle to IA | | 2 |
| ECR | 5 GB | 5 x 0.10 | 1 |
| Route 53 | 1 zone + queries | | 1 |
| **Total** | | | **about 543** |

## Biggest cost drivers

1. **Fargate for the platform (27%)**. Virto needs real memory (the .NET host
   with 60 modules uses about 1.5 to 2 GB at idle). Two tasks are for
   availability, not load.
2. **OpenSearch (21%)** and **RDS Multi AZ (20%)**. Both doubled for high
   availability.
3. **Network**: NAT + public IPv4 + ALB together are about 74 USD even with no
   traffic.

## Ways to reduce it

| Change | Saving / month | Trade-off |
|---|---|---|
| Compute Savings Plan 1 year (Fargate) | about 30 | commitment |
| RDS reserved instance 1 year, no upfront | about 35 | commitment |
| OpenSearch 1 node | about 55 | search goes down during node failure or upgrade |
| Staging / test: single AZ RDS, 1 task each, 1 cache node, no OpenSearch (1 platform task with Lucene on the task disk), Fargate Spot | staging total about 150 | no HA, index rebuilt on every task start |
| Schedule staging off nights and weekends | about 60% of staging | only for non-prod |
| VPC interface endpoints instead of NAT | small, and adds 7 USD per endpoint per AZ | worth it only with heavy ECR/CloudWatch traffic |

## Assumptions

- Low to medium B2B traffic (tens of thousands of page views per day), which
  fits inside 2 LCU and 100 GB egress.
- No CloudFront or WAF in this estimate. WAF with managed rules would add about
  10 to 15 USD plus 0.60 USD per million requests. CloudFront for static
  frontend files would cut ALB and Fargate load for a busy shop.
- Prices change. This table was written on 18 Nov 2026 from list prices I
  know; they must be confirmed in the Pricing Calculator.
