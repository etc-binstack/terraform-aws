## ==================================
## Locals
## ==================================

## Get the Account details
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}


## IAM Policies from files
locals {

  template_vars = var.enable_module ? { // Dynamic values for template substitution
    account_id = local.account_id
    region     = var.aws_region
  } : {}

  policies = var.enable_module ? fileset("${path.module}/templates/policies", "*.json") : [] // Get all JSON policy files
}

## Lambda function
# locals {
#   lambda      = var.lambda_function
#   environment = var.environment_configuration

#   notification_vendors = var.environment_configuration.notification_vendor == null ? [] : [for v in split(",", lower(var.environment_configuration.notification_vendor)) : trim(v, " ")]

#   enable_sendgrid = contains(local.notification_vendors, "sendgrid")
#   enable_ses      = contains(local.notification_vendors, "ses")
#   enable_postmark = contains(local.notification_vendors, "postmark") # for future use

#   cross_vault = var.crossaccount_vault 
# }

## Updated local.tf
locals {
  lambda      = var.lambda_function
  environment = var.environment_configuration

  notification_vendors = var.environment_configuration.notification_vendor == null ? [] : [for v in split(",", lower(var.environment_configuration.notification_vendor)) : trim(v, " ")]

  enable_sendgrid = contains(local.notification_vendors, "sendgrid")
  enable_ses      = contains(local.notification_vendors, "ses")
  enable_postmark = contains(local.notification_vendors, "postmark")
  enable_combine  = contains(local.notification_vendors, "combine")

  # For combine mode, determine the actual provider
  combined_provider = local.enable_combine && var.environment_configuration.mail_provider != null ? lower(var.environment_configuration.mail_provider) : null

  cross_vault = var.crossaccount_vault # Support AWS Account (cross) to access Secret Manager (service)
}
