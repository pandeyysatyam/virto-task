output "db_address" {
  value = aws_db_instance.this.address
}

output "db_instance_id" {
  value = aws_db_instance.this.identifier
}

output "cache_primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "opensearch_endpoint" {
  value = try("https://${aws_opensearch_domain.this[0].endpoint}", null)
}
