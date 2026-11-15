variable "project" {
  description = "Name of the project"
  type        = string
  default     = "platform-lab"
}

variable "aws_region" {
  description = "AWS region where will create the infra"
  type        = string
  default     = "sa-east-1"
}

variable "owner" {
  description = "This is the name of the owner of the project"
  type        = string
  default     = "benzi"
}

variable "aws_account_id" {
  description = "This is the account if of an AWS account"
  type        = string
  default     = "771983217432"
}

variable "aws_profile" {
  type        = string
  description = "The environment aws profile name"
  default     = null
}

variable "vpc_cidr" {
  type        = string
  description = "The CIDR that we will use"
  default     = "10.0.0.0/20"
}
