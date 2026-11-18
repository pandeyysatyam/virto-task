# Managed data services: RDS PostgreSQL, ElastiCache (Valkey) and OpenSearch.

# PostgreSQL 18 is required by Virto Commerce 3.1076 (the platform health
# check fails on 17, see docs/troubleshooting.md issue 2).
resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.data_subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-pg18"
  family = "postgres18"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  multi_az               = var.db_multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.db_security_group_id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.this.name

  backup_retention_period   = var.db_backup_retention_days
  backup_window             = "02:00-03:00"
  maintenance_window        = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.name}-db-final" : null

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql"]
  auto_minor_version_upgrade            = true
}

# Valkey: Redis compatible, cheaper than Redis OSS on ElastiCache.
# Virto uses it for distributed cache invalidation and SignalR between tasks.
resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-cache"
  subnet_ids = var.data_subnet_ids
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = "${var.name}-cache"
  description                = "Virto platform cache"
  engine                     = "valkey"
  engine_version             = var.cache_engine_version
  node_type                  = var.cache_node_type
  num_cache_clusters         = var.cache_nodes
  automatic_failover_enabled = var.cache_nodes > 1
  multi_az_enabled           = var.cache_nodes > 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [var.cache_security_group_id]
  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = true
  auth_token                 = var.cache_password
  snapshot_retention_limit   = 1
}

# OpenSearch replaces Lucene on AWS. Lucene keeps its index on local disk,
# which does not work when two or more platform tasks run behind the ALB.
resource "aws_opensearch_domain" "this" {
  count          = var.enable_opensearch ? 1 : 0
  domain_name    = "${var.name}-search"
  engine_version = var.opensearch_engine_version

  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = var.opensearch_instance_count
    zone_awareness_enabled = var.opensearch_instance_count > 1
    dynamic "zone_awareness_config" {
      for_each = var.opensearch_instance_count > 1 ? [1] : []
      content {
        availability_zone_count = 2
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 20
  }

  vpc_options {
    subnet_ids         = slice(var.data_subnet_ids, 0, var.opensearch_instance_count > 1 ? 2 : 1)
    security_group_ids = [var.search_security_group_id]
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = var.kms_key_arn
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  # The Virto OpenSearch module authenticates with user + password (basic
  # auth), not SigV4, so fine grained access control uses the internal user
  # database. The password lives in Secrets Manager (secrets module).
  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = var.opensearch_master_user
      master_user_password = var.opensearch_master_password
    }
  }
}
