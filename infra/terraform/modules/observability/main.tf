# Log groups, an SNS topic for alerts and the alarms that matter most.
# Alarms for ALB / RDS / ECS are switched on with enable_* flags. Flags are
# plain booleans (not "is the ARN null?") because ARNs are only known after
# apply and count/for_each must be known at plan time.

resource "aws_cloudwatch_log_group" "this" {
  for_each          = toset(var.log_groups)
  name              = "/${var.name}/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# Custom metric pushed by scripts/monitor.sh (local) or a synthetic check
resource "aws_cloudwatch_metric_alarm" "unhealthy_services" {
  alarm_name          = "${var.name}-unhealthy-services"
  alarm_description   = "One or more Virto services failed the health check"
  namespace           = "Virto/${var.name}"
  metric_name         = "UnhealthyServices"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count               = var.enable_alb_alarms ? 1 : 0
  alarm_name          = "${var.name}-alb-5xx"
  alarm_description   = "More than 20 5xx responses from targets in 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each            = var.enable_alb_alarms ? toset(["frontend", "platform"]) : toset([])
  alarm_name          = "${var.name}-${each.key}-unhealthy-targets"
  alarm_description   = "${each.key} target group has unhealthy targets"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffixes[each.key] }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  count               = var.enable_alb_alarms ? 1 : 0
  alarm_name          = "${var.name}-alb-p95-latency"
  alarm_description   = "p95 response time above 2 seconds"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 2
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count               = var.enable_rds_alarms ? 1 : 0
  alarm_name          = "${var.name}-rds-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  count               = var.enable_rds_alarms ? 1 : 0
  alarm_name          = "${var.name}-rds-free-storage"
  alarm_description   = "Less than 5 GB free on the database volume"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5368709120
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  for_each            = var.enable_ecs_alarms ? toset(["platform", "frontend"]) : toset([])
  alarm_name          = "${var.name}-${each.value}-memory"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = { ClusterName = var.ecs_cluster_name, ServiceName = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
