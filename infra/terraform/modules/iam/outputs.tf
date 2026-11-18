output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "platform_task_role_arn" {
  value = aws_iam_role.platform_task.arn
}

output "frontend_task_role_arn" {
  value = aws_iam_role.frontend_task.arn
}

output "deploy_role_arn" {
  value = try(aws_iam_role.deploy[0].arn, null)
}
