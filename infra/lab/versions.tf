terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  required_version = "~> 1.17"

  backend "s3" {
    bucket       = "platform-lab-tfstate-771983217432-sa-east-1-an"
    key          = "lab/terraform.tfstate"
    region       = "sa-east-1"
    encrypt      = true
    use_lockfile = true
    profile      = "platform-lab-deployer"
  }
}
