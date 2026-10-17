# Pins the Terraform and AWS provider versions so the project behaves the
# same on every machine, and configures the AWS provider.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile # the SSO profile you created with `aws configure sso`

  # Every resource gets these tags automatically. Tags make it easy to find
  # (and bill-check) everything this project created.
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
