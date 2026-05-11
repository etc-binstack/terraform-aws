# SES — AWS-Native Email Delivery

**Pattern:** Simplest alarm notification — no external API key
**Use for:** Teams already using AWS SES for email; zero third-party dependencies
**Concepts:** SES vendor mode, pre-loaded SES template, `data.archive_file` builds zip at plan time
**Adopt for:** Internal alerts where SES is already configured, cost-sensitive setups

---

## What This Creates

- Lambda function (`ses` mode) — zipped from `ses_cw_alerts.py` at plan time
- IAM execution role with CloudWatch + SNS + SES permissions
- No external API key required

---

## Prerequisites

- SES verified domain or email address in same account
- SES template created in SES console named to match `mail_template`
- SNS topic to subscribe this Lambda to (managed by calling module)

---

## Key Concepts

**SES template vs HTML template**
SES mode uses a pre-created SES template in your AWS account (not a local HTML file). Create the template via AWS Console or CLI before deploying. `mail_template` passes the template name — not a file path.

**Zip built at plan time**
SES Lambda is the only vendor mode where Terraform builds the zip via `data.archive_file`. Other modes (SendGrid, Postmark, generic) use pre-built zips committed to the repo.

---

## Configuration

```hcl
module "alarm_notifier" {
  source = "github.com/etc-binstack/terraform-aws//modules/monitoring/cw-alarm-notifier?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  project       = "platform"
  aws_region    = "<your-region>"

  environment_configuration = {
    notification_vendor  = "ses"
    email_from           = "alerts@example.com"
    email_to             = ["oncall@example.com"]
    email_cc             = ["manager@example.com"]
    email_reply_to       = ["no-reply@example.com"]
    mail_template        = "sesTemplateCloudWatchAlerts"
  }
}
```

---

## Notes

- **SES sending limits:** New SES accounts start in sandbox mode — verify recipient emails before going live.
- **Template must exist first:** Deploy the SES template before `terraform apply` or Lambda invocation fails silently.
- **Related:** `docs/email-templates.md`

---

---

# SendGrid

**Pattern:** Transactional email via SendGrid API
**Use for:** Teams using SendGrid as their email platform; HTML template control
**Concepts:** SendGrid vendor mode, API key via Terraform variable or cross-account vault
**Adopt for:** Production alerts where email deliverability and tracking matter

---

## What This Creates

- Lambda function (`sendgrid` mode) — pre-built zip from `templates/lambda/sendgrid/`
- IAM execution role with CloudWatch + SNS permissions

---

## Prerequisites

- SendGrid account with API key (`Mail Send` permission)
- Verified sender domain in SendGrid

---

## Key Concepts

**API key delivery**
Two options:
1. Pass directly via `api_key` (injected as Lambda env var — visible in AWS console)
2. Store in cross-account Secrets Manager → Lambda fetches at runtime (see cross-account example)

**HTML template**
`mail_template = "html_template.html"` points to the HTML file bundled in the Lambda zip. Use default template or replace with customised version from `docs/html-samples/`.

---

## Configuration

```hcl
module "alarm_notifier" {
  source = "github.com/etc-binstack/terraform-aws//modules/monitoring/cw-alarm-notifier?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  project       = "platform"
  aws_region    = "<your-region>"

  environment_configuration = {
    notification_vendor = "sendgrid"
    api_key             = var.sendgrid_api_key   # pass via tfvars, never hardcode
    email_from          = "alerts@example.com"
    email_to            = ["oncall@example.com"]
    mail_template       = "html_template.html"
  }
}
```

---

## Notes

- **Never hardcode `api_key`** in `.tf` files. Pass via `*.tfvars` (gitignored) or use `crossaccount_vault`.
- **Related:** Cross-account example below, `docs/email-templates.md`

---

---

# Postmark

**Pattern:** Transactional email via Postmark API
**Use for:** High deliverability requirements; Postmark as preferred email provider
**Concepts:** Postmark vendor mode, API key injection
**Adopt for:** Production alerts, SaaS platforms where Postmark is already used

---

## What This Creates

- Lambda function (`postmark` mode) — pre-built zip from `templates/lambda/postmark/`
- IAM execution role

---

## Configuration

```hcl
module "alarm_notifier" {
  source = "github.com/etc-binstack/terraform-aws//modules/monitoring/cw-alarm-notifier?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  project       = "platform"
  aws_region    = "<your-region>"

  environment_configuration = {
    notification_vendor = "postmark"
    api_key             = var.postmark_api_key
    email_from          = "alerts@example.com"
    email_to            = ["oncall@example.com"]
    email_cc            = []
    mail_template       = "html_template.html"
  }
}
```

---

## Notes

- Same API key security rules as SendGrid apply — never hardcode.
- Postmark differentiates transactional vs broadcast streams — use transactional for alerts.

---

---

# Combined Mode (multiple vendors + Teams)

**Pattern:** Route through any provider dynamically; optionally send to Microsoft Teams
**Use for:** Teams wanting flexibility to switch providers without redeploying; Teams webhook alongside email
**Concepts:** `combine` vendor mode, `mail_provider` selects actual delivery, Teams webhook
**Adopt for:** Enterprise setups with both email and Teams notifications

---

## What This Creates

- Lambda function (`generic_mailer` mode) — pre-built zip with multi-provider support
- IAM execution role

---

## Key Concepts

**`combine` mode**
`notification_vendor = "combine"` activates the generic mailer Lambda. `mail_provider` then selects the actual email provider (`sendgrid`, `postmark`, or `ses`). This single Lambda handles all three plus Teams.

**Teams webhook**
When `enable_teams = true` and `teams_webhook_url` is set, the Lambda posts a formatted card to Teams AND sends email. Both fire on the same alarm.

---

## Configuration

```hcl
module "alarm_notifier" {
  source = "github.com/etc-binstack/terraform-aws//modules/monitoring/cw-alarm-notifier?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  project       = "platform"
  aws_region    = "<your-region>"

  environment_configuration = {
    notification_vendor = "combine"
    mail_provider       = "sendgrid"           # actual delivery: sendgrid | postmark | ses
    api_key             = var.sendgrid_api_key
    email_from          = "alerts@example.com"
    email_to            = ["oncall@example.com"]
    mail_template       = "html_template.html"
    enable_teams        = true
    teams_webhook_url   = var.teams_webhook_url
  }
}
```

---

## Notes

- Only one Lambda is created in combine mode (`generic_mailer`) — not one per provider.
- `api_key` is used by whichever `mail_provider` is selected.
- Teams webhook fires regardless of email success/failure.

---

---

# Cross-Account Secrets Manager (API Key in Separate Account)

**Pattern:** API key stored in a centralised secrets account; Lambda fetches at runtime
**Use for:** Multi-account setups where a dedicated secrets/security account holds all API keys
**Concepts:** `crossaccount_vault`, `sts:AssumeRole`-less approach (IAM policy + same-account role), runtime secret fetch
**Adopt for:** Compliance-driven environments; central secrets management across AWS accounts

---

## What This Creates

- Lambda function (any vendor mode)
- IAM policy: `secretsmanager:GetSecretValue` + `kms:Decrypt` on cross-account secret ARNs
- The Lambda fetches the API key from cross-account Secrets Manager at invocation time

---

## Key Concepts

**How cross-account secret access works**
```
Lambda (app account)
  └── IAM policy: secretsmanager:GetSecretValue on secrets-account ARN
  └── Secrets account: resource-based policy allows app account role
  └── Lambda reads secret at invocation → uses API key → sends email
```

No static API key in Lambda env vars. No Secrets Manager secret in app account.

**`VAULT_REGION` and `VAULT_ACCOUNT_ID`**
The module injects these as Lambda environment variables from `crossaccount_vault.region` and `crossaccount_vault.account_id`. Lambda uses them to construct the cross-account secret ARN at runtime.

---

## Configuration

```hcl
module "alarm_notifier" {
  source = "github.com/etc-binstack/terraform-aws//modules/monitoring/cw-alarm-notifier?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  project       = "platform"
  aws_region    = "<your-region>"

  environment_configuration = {
    notification_vendor = "sendgrid"
    api_key             = null          # null = fetch from cross-account vault at runtime
    email_from          = "alerts@example.com"
    email_to            = ["oncall@example.com"]
  }

  crossaccount_vault = {
    enabled    = true
    account_id = "SECRETS_ACCOUNT_ID"   # account holding the API key secret
    region     = "<secrets-region>"
  }
}
```

---

## Secrets Account Setup (outside this module)

In the secrets account, the secret resource-based policy must allow the Lambda role:

```json
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::APP_ACCOUNT_ID:root" },
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": "*"
  }]
}
```

---

## Notes

- `api_key = null` — the `api_key` variable is ignored when cross-account vault is enabled.
- Lambda must have network access to Secrets Manager endpoint — VPC endpoint or NAT Gateway required if running in private subnet.
- **Related:** `crossaccount_vault` variable in `vars.tf`

---

---

# Wire to ECS Service Alerts

**Pattern:** Connect this Lambda to ECS service CloudWatch alarms via SNS
**Use for:** Receiving formatted email/Teams alerts when ECS CPU, memory, or custom alarms fire
**Concepts:** Lambda ARN passed to `service-awsvpc` module `configure_alerts.lambda_arns`
**Adopt for:** Any `service-awsvpc` deployment that needs rich HTML email notifications

---

## What This Creates

This pattern creates NO resources by itself. It shows how to wire outputs from `cw-alarm-notifier` into `service-awsvpc`.

---

## Key Concepts

**SNS → Lambda flow**
```
CloudWatch Alarm fires
    ↓
SNS Topic (created by service-awsvpc configure_alerts)
    ↓  lambda_arns subscription
Lambda (this module)
    ↓
HTML email → SendGrid / SES / Postmark / Teams
```

`service-awsvpc` creates the SNS topic and subscribes this Lambda ARN. The Lambda is triggered by SNS, not invoked directly.

---

## Configuration

```hcl
## Step 1 — deploy the notifier
module "alarm_notifier" {
  source = "github.com/etc-binstack/terraform-aws//modules/monitoring/cw-alarm-notifier?ref=v1.0.0"

  enable_module = true
  environment   = var.environment
  project       = "platform"
  aws_region    = "<your-region>"

  environment_configuration = {
    notification_vendor = "ses"
    email_from          = "alerts@example.com"
    email_to            = ["oncall@example.com"]
    mail_template       = "sesTemplateCloudWatchAlerts"
  }
}

## Step 2 — pass Lambda ARN to ECS service alerts
module "api_service" {
  source = "github.com/etc-binstack/terraform-aws//modules/ecs/service-awsvpc?ref=v1.0.0"

  configure_alerts = {
    enabled     = true
    topic_name  = "production-alerts"
    lambda_arns = [module.alarm_notifier.lambda_arn]  # SNS subscribes this Lambda
    enabled_alerts = {
      cpu_high    = true
      cpu_low     = false
      memory_high = true
      memory_low  = false
    }
  }

  # ... rest of service config
}
```

## Notes

- **`lambda_arn` output** returns the primary Lambda ARN (first active vendor). Use `all_lambda_arns` if multiple vendors enabled.
- **SNS permission:** The module creates `aws_lambda_permission` to allow SNS to invoke the Lambda — no manual permission needed.
- Deploy `alarm_notifier` before `api_service` or use `depends_on`.
