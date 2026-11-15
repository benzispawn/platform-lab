resource "aws_s3_bucket" "platform_lab_bucket" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_versioning" "platform_lab_bucket" {
  bucket = aws_s3_bucket.platform_lab_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "platform_lab_bucket" {
  bucket = aws_s3_bucket.platform_lab_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "platform_lab_bucket" {
  bucket = aws_s3_bucket.platform_lab_bucket.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "platform_lab_bucket" {
  bucket = aws_s3_bucket.platform_lab_bucket.id
  policy = data.aws_iam_policy_document.deny_insecure_transport.json
}

resource "aws_ecr_repository" "platform_lab_repository" {
  name                 = local.repository_name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}


resource "aws_ecr_lifecycle_policy" "platform_lab_repository" {
  repository = aws_ecr_repository.platform_lab_repository.name
  policy     = <<EOF
  {
    "rules": [
        {
            "rulePriority": 1,
            "selection": {
                "tagStatus": "tagged",
                "tagPatternList": [
                    "*"
                ],
                "countType": "imageCountMoreThan",
                "countNumber": 10
            },
            "action": {
                "type": "expire"
            }
        }
    ]
  }
  EOF
}
