variable "environment" {
  type    = string
  default = "staging"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_account_id" {
  type = string
}

variable "project_name" {
  type    = string
  default = "sample-app"
}

variable "ecr_base_url" {
  type        = string
  description = "ECR base URL e.g. 111122223333.dkr.ecr.us-east-1.amazonaws.com"
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "oncall_email" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "db_host" {
  type = string
}
