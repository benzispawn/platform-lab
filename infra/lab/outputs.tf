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

output "vpc_id" {
  description = "The vpc_id output"
  value       = aws_vpc.platform_lab_vpc.id
}

output "public_subnet_ids" {
  description = "A list of public subnet ids"
  value = [
    aws_subnet.platform_lab_vpc_public_1,
    aws_subnet.platform_lab_vpc_public_2
  ]
}

output "private_subnet_ids" {
  description = "A list of private subnet ids"
  value = [
    aws_subnet.platform_lab_vpc_private_1,
    aws_subnet.platform_lab_vpc_private_2
  ]
}
