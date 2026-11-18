# Encryption key, backup bucket and (optionally) EFS for platform assets.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Key policy: the account administers the key (IAM policies decide who uses it),
# CloudWatch Logs may encrypt log groups and CloudWatch alarms may publish to
# the encrypted SNS topic.
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.name}/*"]
    }
  }
  statement {
    sid       = "CloudWatchAlarmsToSns"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${var.name} data encryption (S3 backups, secrets, logs)"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}

# Backups: database dumps and asset archives
resource "aws_s3_bucket" "backups" {
  bucket        = "${var.name}-backups-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "tiering-and-expiry"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Refuse plain HTTP access to the bucket
data "aws_iam_policy_document" "backups" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  count  = var.enforce_tls_bucket_policy ? 1 : 0
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.backups.json
}

# EFS: shared, persistent folder for uploaded catalog images and CMS content.
# Every platform task mounts the same file system, so images survive task
# replacement and work with more than one task.
resource "aws_efs_file_system" "assets" {
  count            = var.enable_efs ? 1 : 0
  encrypted        = true
  kms_key_id       = aws_kms_key.this.arn
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = { Name = "${var.name}-assets" }
}

resource "aws_efs_mount_target" "assets" {
  count           = var.enable_efs ? length(var.efs_subnet_ids) : 0
  file_system_id  = aws_efs_file_system.assets[0].id
  subnet_id       = var.efs_subnet_ids[count.index]
  security_groups = [var.efs_security_group_id]
}

# Access point forces the uid/gid of the "app" user in the platform image
resource "aws_efs_access_point" "assets" {
  count          = var.enable_efs ? 1 : 0
  file_system_id = aws_efs_file_system.assets[0].id

  posix_user {
    uid = 1654
    gid = 1654
  }

  root_directory {
    path = "/virto"
    creation_info {
      owner_uid   = 1654
      owner_gid   = 1654
      permissions = "0750"
    }
  }
}

resource "aws_efs_backup_policy" "assets" {
  count          = var.enable_efs ? 1 : 0
  file_system_id = aws_efs_file_system.assets[0].id
  backup_policy {
    status = "ENABLED"
  }
}
