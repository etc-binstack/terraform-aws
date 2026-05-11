variable "environment"       { type = string; default = "staging" }
variable "aws_region"        { type = string; default = "us-east-1" }
variable "project"           { type = string; default = "platform" }
variable "email_from"        { type = string }
variable "email_to"          { type = list(string) }
variable "vault_account_id"  { type = string }
variable "vault_region"      { type = string; default = "us-east-1" }
variable "enable_teams"      { type = bool;   default = false }
variable "teams_webhook_url" { type = string; default = null }
