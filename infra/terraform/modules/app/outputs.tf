output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "target_group_arn_suffixes" {
  value = {
    frontend = aws_lb_target_group.frontend.arn_suffix
    platform = aws_lb_target_group.platform.arn_suffix
  }
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_names" {
  value = [aws_ecs_service.platform.name, aws_ecs_service.frontend.name]
}

output "service_arns" {
  value = [aws_ecs_service.platform.id, aws_ecs_service.frontend.id]
}
