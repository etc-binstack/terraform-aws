## =============================================================================
## Example: Complete — SendGrid + cross-account Secrets Manager + Teams
## Demonstrates: SendGrid delivery, cross-account vault, Teams webhook
## Prerequisites: SNS topic to subscribe Lambda to (managed by calling module)
## =============================================================================

provider "aws" {
  region = var.aws_region
}

module "alarm_notifier" {
  source = "../../"

  enable_module = true
  environment   = var.environment
  project       = var.project
  aws_region    = var.aws_region

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  lambda_function = {
    function_name = "cw-alerts-notifier"
    role_name     = "cw-alerts-notifier-role"
    runtime       = "python3.13"
    timeout       = 30
  }

  environment_configuration = {
    notification_vendor = "sendgrid"
    api_key             = null          # fetched from cross-account vault at runtime
    email_from          = var.email_from
    email_to            = var.email_to
    email_cc            = []
    mail_template       = "html_template.html"
    enable_teams        = var.enable_teams
    teams_webhook_url   = var.teams_webhook_url
  }

  ## API key stored in a separate AWS account (central secrets account)
  crossaccount_vault = {
    enabled    = true
    account_id = var.vault_account_id
    region     = var.vault_region
  }
}
