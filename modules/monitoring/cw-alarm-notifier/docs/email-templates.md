# Email Templates Guide

HTML email templates used by the Lambda functions to format CloudWatch alarm notifications.

---

## Template Files

Located in `docs/html-samples/`:

| File | Severity | Used When |
|---|---|---|
| `critical_sample.html` | CRITICAL | P1 alarms — immediate action |
| `high_sample.html` | HIGH | P2 alarms — degraded performance |
| `warning_sample.html` | WARNING | P3 alarms — threshold approaching |
| `base_template.html` | Generic | Base template — all severities |
| `jinja2_compatible.html` | Generic (Jinja2) | Jinja2-compatible version |

---

## How Templates Are Used

### SES mode
Pass the SES template name (pre-loaded in SES console) via `mail_template`:
```hcl
environment_configuration = {
  notification_vendor = "ses"
  mail_template       = "sesTemplateCloudWatchAlerts"  # name in SES console
}
```

### SendGrid / Postmark / Combined mode
Pass the HTML filename via `mail_template`. The Lambda reads this file from its deployment package:
```hcl
environment_configuration = {
  notification_vendor = "sendgrid"
  mail_template       = "html_template.html"   # filename inside Lambda zip
}
```

---

## Customising Templates

1. Edit the HTML in `docs/html-samples/`
2. Copy the modified file into the Lambda deployment package:
   ```
   templates/lambda/generic_mailer/html_template.html   ← generic/combine mode
   ```
3. Rebuild the zip:
   ```bash
   cd templates/lambda/generic_mailer/
   zip alerts_generic.zip alerts_generic.py html_template.html
   ```
4. Commit the updated zip

---

## Template Variables

The Lambda injects these values into the email body at send time:

| Variable | Description |
|---|---|
| Alarm name | CloudWatch alarm that triggered |
| State | `ALARM` \| `OK` \| `INSUFFICIENT_DATA` |
| Reason | Why the alarm fired |
| Timestamp | When it fired |
| Region | AWS region |
| Account | AWS account ID |
