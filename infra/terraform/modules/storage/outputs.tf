output "kms_key_arn" {
  value = aws_kms_key.this.arn
}

output "backup_bucket_name" {
  value = aws_s3_bucket.backups.bucket
}

output "backup_bucket_arn" {
  value = aws_s3_bucket.backups.arn
}

output "efs_file_system_id" {
  value = try(aws_efs_file_system.assets[0].id, null)
}

output "efs_file_system_arn" {
  value = try(aws_efs_file_system.assets[0].arn, null)
}

output "efs_access_point_id" {
  value = try(aws_efs_access_point.assets[0].id, null)
}

output "efs_access_point_arn" {
  value = try(aws_efs_access_point.assets[0].arn, null)
}
