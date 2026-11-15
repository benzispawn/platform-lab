# Default provider: used by every resource that doesn't set `provider`.
provider "aws" {
  region = var.aws_region

  profile = var.aws_profile

  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = local.default_tags
  }
}
