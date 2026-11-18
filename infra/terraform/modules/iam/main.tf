# Least privilege roles. Every policy lists exact resource ARNs, no "*" on
# resources except where the AWS API does not support resource scoping
# (ecr:GetAuthorizationToken, ecs:DescribeTaskDefinition, ecs:RegisterTaskDefinition).

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# 1. Execution role: used by the ECS agent to pull images, write logs and
#    read secrets before the container starts. The app never sees it.
resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = var.ecr_repository_arns
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for arn in var.log_group_arns : "${arn}:*"]
  }
  statement {
    sid       = "ReadAppSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }
  statement {
    sid       = "ReadAppParameters"
    actions   = ["ssm:GetParameters"]
    resources = var.parameter_arns
  }
  statement {
    sid       = "DecryptWithAppKey"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# 2. Platform task role: what the running platform code may call.
resource "aws_iam_role" "platform_task" {
  name               = "${var.name}-platform-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "platform_task" {
  statement {
    sid       = "BackupBucketList"
    actions   = ["s3:ListBucket"]
    resources = [var.backup_bucket_arn]
  }
  statement {
    sid       = "BackupBucketObjects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.backup_bucket_arn}/platform/*"]
  }
  statement {
    sid       = "UseAppKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }

  dynamic "statement" {
    for_each = var.efs_file_system_arn == null ? [] : [1]
    content {
      sid       = "MountAssets"
      actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
      resources = [var.efs_file_system_arn]
      condition {
        test     = "StringEquals"
        variable = "elasticfilesystem:AccessPointArn"
        values   = [var.efs_access_point_arn]
      }
    }
  }

  # ECS Exec for break-glass debugging, audited in CloudTrail
  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "platform_task" {
  name   = "platform"
  role   = aws_iam_role.platform_task.id
  policy = data.aws_iam_policy_document.platform_task.json
}

# 3. Frontend task role: nginx serves files and proxies, it needs no AWS access.
resource "aws_iam_role" "frontend_task" {
  name               = "${var.name}-frontend-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# 4. CI/CD deploy role assumed by GitHub Actions through OIDC (no long lived keys).
#    Only the main branch of one repository can assume it.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_assume" {
  count = var.create_github_oidc ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  count              = var.create_github_oidc ? 1 : 0
  name               = "${var.name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_assume[0].json
}

data "aws_iam_policy_document" "deploy" {
  count = var.create_github_oidc ? 1 : 0
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
    ]
    resources = var.ecr_repository_arns
  }
  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }
  statement {
    sid       = "UpdateServices"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = var.ecs_service_arns
  }
  statement {
    sid       = "PassOnlyTaskRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn, aws_iam_role.platform_task.arn, aws_iam_role.frontend_task.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  count  = var.create_github_oidc ? 1 : 0
  name   = "deploy"
  role   = aws_iam_role.deploy[0].id
  policy = data.aws_iam_policy_document.deploy[0].json
}
