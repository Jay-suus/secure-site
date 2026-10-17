# Inputs for the project. Defaults are set so you can run it as-is;
# override any of them in a terraform.tfvars file (which .gitignore excludes).

variable "project" {
  description = "Short name used for tagging and naming resources."
  type        = string
  default     = "secure-site"
}

variable "region" {
  description = "The one AWS region this project uses."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile name from `aws configure sso`."
  type        = string
  default     = "lab"
}
