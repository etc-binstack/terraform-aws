## =============================================================================
## Example: Minimal — SES only, no external API key
## Demonstrates: simplest possible usage, AWS-native delivery
## =============================================================================

provider "aws" {
  region = var.aws_region
}

variable "aws_region"   { type = string; default = "us-east-1" }
variable "environment"  { type = string; default = "staging" }
variable "project"      { type = string; default = "platform" }
variable "email_from"   { type = string }
variable "email_to"     { type = list(string) }

module "alarm_notifier" {
  source = "../../"

  enable_module = true
  environment   = var.environment
  project       = var.project
  aws_region    = var.aws_region

  environment_configuration = {
    notification_vendor = "ses"
    email_from          = var.email_from
    email_to            = var.email_to
    mail_template       = "sesTemplateCloudWatchAlerts"
  }
}

output "lambda_arn" { value = module.alarm_notifier.lambda_arn }
