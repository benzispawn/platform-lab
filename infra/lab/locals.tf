locals {
  default_tags = {
    "Project" = var.project
    "Owner"   = var.owner
  }
  bucket_name     = "${var.project}-${var.aws_account_id}-${var.aws_region}-an"
  repository_name = "${var.project}-repository"
}
