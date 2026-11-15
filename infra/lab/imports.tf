import {
  to = aws_s3_bucket.platform_lab_bucket
  id = local.bucket_name
}

import {
  to = aws_s3_bucket_versioning.platform_lab_bucket
  id = local.bucket_name
}

import {
  to = aws_s3_bucket_public_access_block.platform_lab_bucket
  id = local.bucket_name
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.platform_lab_bucket
  id = local.bucket_name
}

import {
  to = aws_s3_bucket_policy.platform_lab_bucket
  id = local.bucket_name
}

import {
  to = aws_ecr_repository.platform_lab_repository
  id = local.repository_name
}

import {
  to = aws_ecr_lifecycle_policy.platform_lab_repository
  id = local.repository_name
}
