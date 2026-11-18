# Security groups reference each other instead of CIDRs, so only the tier
# directly in front can reach the next one:
#   internet -> alb -> frontend -> platform -> db / cache / efs

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public load balancer"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each          = toset(var.allowed_ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each          = toset(var.allowed_ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "HTTP, redirected to HTTPS by the listener"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_frontend" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.frontend.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_platform" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.platform.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "frontend" {
  name        = "${var.name}-frontend"
  description = "Frontend nginx tasks"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-frontend" }
}

resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  security_group_id            = aws_security_group.frontend.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "frontend_all" {
  security_group_id = aws_security_group.frontend.id
  description       = "To platform and AWS APIs (ECR, CloudWatch) through NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "platform" {
  name        = "${var.name}-platform"
  description = "Virto platform tasks"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-platform" }
}

resource "aws_vpc_security_group_ingress_rule" "platform_from_alb" {
  security_group_id            = aws_security_group.platform.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "platform_from_frontend" {
  security_group_id            = aws_security_group.platform.id
  referenced_security_group_id = aws_security_group.frontend.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "platform_all" {
  security_group_id = aws_security_group.platform.id
  description       = "To data tier and AWS APIs through NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "RDS PostgreSQL, platform only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_platform" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.platform.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "cache" {
  name        = "${var.name}-cache"
  description = "ElastiCache Valkey, platform only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-cache" }
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_platform" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = aws_security_group.platform.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "efs" {
  name        = "${var.name}-efs"
  description = "EFS for platform assets, platform only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-efs" }
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_platform" {
  security_group_id            = aws_security_group.efs.id
  referenced_security_group_id = aws_security_group.platform.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "search" {
  name        = "${var.name}-search"
  description = "OpenSearch domain, platform only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-search" }
}

resource "aws_vpc_security_group_ingress_rule" "search_from_platform" {
  security_group_id            = aws_security_group.search.id
  referenced_security_group_id = aws_security_group.platform.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}
