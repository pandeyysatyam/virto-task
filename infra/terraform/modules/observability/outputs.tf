output "log_group_names" {
  value = { for k, g in aws_cloudwatch_log_group.this : k => g.name }
}

output "log_group_arns" {
  value = [for g in aws_cloudwatch_log_group.this : g.arn]
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "metric_namespace" {
  value = "Virto/${var.name}"
}
