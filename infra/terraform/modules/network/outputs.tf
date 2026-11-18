output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}

output "security_group_ids" {
  value = {
    alb      = aws_security_group.alb.id
    frontend = aws_security_group.frontend.id
    platform = aws_security_group.platform.id
    db       = aws_security_group.db.id
    cache    = aws_security_group.cache.id
    efs      = aws_security_group.efs.id
    search   = aws_security_group.search.id
  }
}
