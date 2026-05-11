## File: vars.tf
##============================
## Variable: Common
##============================

variable "enable_module" {
  description = "Toggle to enable or disable this module"
  type        = bool
  default     = false
}

variable "environment" {
  type = string
}

variable "tags" {
  description = "Tags to be applied to all resources"
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "Primary AWS region"
  type        = string
}

variable "project" {
  description = "Name or identifier of the person or system creating the infrastructure"
  type        = string
}

##============================
## Variable: Lambda Function
##============================

variable "lambda_function" {
  description = "Configuration for alarm notifications (SNS, Email, SMS, Webhooks)"
  type = object({

    # Lambda Configuration
    create        = optional(bool, false)
    function_name = optional(string)
    timeout       = optional(number)
    role_name     = optional(string)
    runtime       = optional(string)
  })
  default = {
    # Lambda Configuration
    create        = false
    function_name = "cw-alerts-email-formatter"
    timeout       = 30
    role_name     = "lambda-cw-alerts-email-formatter-role"
    runtime       = "python3.13"
  }
}

##==============================
## Variable: Nofification emails
##==============================

# Notification Configuration (configure_notification)
# ---------------------------------------------------
# If notification_vendor contains sendgrid or postmark, api_key must be provided.
# If it contains ses, ses_template_name must be provided.
# If multiple vendors are used (e.g., "sendgrid,ses,postmark"), both must be set.

variable "crossaccount_vault" {
  description = "Enable/Disable Secretmanager to pull secret"
  type = object({

    # Lambda crossvault configuration
    enabled    = optional(bool, false)
    account_id = optional(string)
    region     = optional(string)
  })
  default = {
    # Lambda Configuration
    enabled    = false
    account_id = null
    region     = null
  }
}

variable "environment_configuration" {
  description = "Configuration for alarm notifications (SNS, Email, SMS, Webhooks)"
  type = object({
    notification_vendor = optional(string, null) # Comma-separated values: sendgrid,ses,postmark,combine
    api_key             = optional(string, null) # For Sendgrid/Postmark only
    mail_template       = optional(string, null) # For SES/SendGrid/Postmark/Combine
    mail_provider       = optional(string, null) # For Combine mode: sendgrid, postmark, ses
    email_from          = optional(string, null)
    email_to            = optional(list(string), [])
    email_cc            = optional(list(string), [])
    email_reply_to      = optional(list(string), [])
    enable_teams        = optional(bool, false)
    teams_webhook_url   = optional(string, null)
  })

  default = {
    notification_vendor = null
    mail_template       = null
    api_key             = null
    mail_provider       = null
    email_from          = null
    email_to            = []
    email_cc            = []
    email_reply_to      = []
    enable_teams        = false
    teams_webhook_url   = null
  }

  validation {
    condition = (
      var.environment_configuration.notification_vendor == null ||
      alltrue([
        for vendor in split(",", lower(var.environment_configuration.notification_vendor)) :
        contains(["sendgrid", "ses", "postmark", "combine"], trim(vendor, " "))
      ])
    )
    error_message = "notification_vendor must contain only: sendgrid, ses, postmark, or combine (comma-separated if multiple)."
  }

  validation {
    condition = (
      var.environment_configuration.notification_vendor == null ||
      !contains([for v in split(",", lower(var.environment_configuration.notification_vendor)) : trim(v, " ")], "combine") ||
      (var.environment_configuration.mail_provider != null && contains(["sendgrid", "postmark", "ses"], lower(var.environment_configuration.mail_provider)))
    )
    error_message = "When using 'combine' notification_vendor, mail_provider must be specified as one of: sendgrid, postmark, or ses."
  }
}

# variable "environment_configuration" {
#   description = "Configuration for alarm notifications (SNS, Email, SMS, Webhooks)"
#   type = object({
#     notification_vendor = optional(string, null) # Comma-separated values: sendgrid,ses,postmark
#     api_key             = optional(string, null) # For Sendgrid/Postmark only
#     mail_template       = optional(string, null) # For SES/SendGrid/Postmark only    
#     email_from          = optional(string, null)
#     email_to            = optional(list(string), [])
#     email_cc            = optional(list(string), [])
#     email_reply_to      = optional(list(string), [])
#   })

#   default = {
#     notification_vendor = null
#     mail_template       = null
#     api_key             = null
#     mail_template       = "sesTemplateCloudWatchAlerts"    
#     email_from          = null
#     email_to            = []
#     email_cc            = []
#     email_reply_to      = []
#   }

#   validation {
#     condition = (
#       var.environment_configuration.notification_vendor == null ||
#       alltrue([
#         for vendor in split(",", lower(var.environment_configuration.notification_vendor)) :
#         contains(["sendgrid", "ses", "postmark"], trim(vendor, " "))
#       ])
#     )
#     error_message = "notification_vendor must contain only: sendgrid, ses, or postmark (comma-separated if multiple)."
#   }
# }

