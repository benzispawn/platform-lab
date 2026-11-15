output "repository_url" {
  description = "The URL to access or push images"
  value       = aws_ecr_repository.platform_lab_repository.repository_url
}

output "bucket_name" {
  description = "The name of the bucket"
  value       = aws_s3_bucket.platform_lab_bucket.bucket
}

output "account_id" {
  description = "Account id of the current user"
  value       = data.aws_caller_identity.current.account_id
}

output "caller_arn" {
  description = "ARN of the current user"
  value       = data.aws_caller_identity.current.arn
}
