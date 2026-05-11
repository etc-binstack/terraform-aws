# Lambda Project Structure - Separated Templates

## File Structure (simple)
```
lambda-cloudwatch-alarm/
├── postmark_cw_alerts.py   # Main Lambda handler (updated)
├── requirements.txt        # Dependencies
└── postmark_cw_alerts.zip   # Final deployment package
```

## File Structure (seperated)
```
lambda-cloudwatch-alarm/
├── postmark_cw_alerts.py   # Main Lambda handler (updated)
├── email_templates.py      # HTML/CSS templates & functions
├── requirements.txt        # Dependencies
└── postmark_cw_alerts.zip   # Final deployment package
```

## Setup Instructions

### 1. Create Project Directory
```bash
mkdir postmark_cw_alerts
cd postmark_cw_alerts
```

### 2. Create Files

#### Create `requirements.txt`:
```txt
# PostMark API client for sending emails
postmarker==1.0.0
python-dotenv==1.0.0

# HTTP client library (dependency of postmark)
python-http-client==3.3.7

# ECDSA cryptographic library (dependency of postmark)
starkbank-ecdsa==2.2.0

# Boto3 for AWS Secrets Manager access (if used)
boto3>=1.28.0

# AWS SDK core dependency
botocore>=1.31.0

# Security and monitoring
requests[security]>=2.28.0,<3.0.0
urllib3>=1.26.0,<3.0.0

# For better error tracking in production
sentry-sdk>=1.32.0,<2.0.0

# For configuration validation
pyyaml>=6.0,<7.0
```

#### Create `email_templates.py`: (Optional)
Copy the content from the "email_templates.py" artifact above.

#### Create `postmark_cw_alerts.py`:
Copy the content from the updated "Lambda CloudWatch Alarm with PostMark" artifact above.

### 3. Install Dependencies
```bash
pip install -r requirements.txt -t .
```

### 4. Create Deployment ZIP
```bash
# Remove unnecessary files
rm -rf *dist-info/ __pycache__/

# Create deployment zip
zip -r lambda-deployment.zip . -x "requirements.txt" "*.pyc" "__pycache__/*"
```

## Lambda Environment 
```bash
POSTMARK_API_KEY=dev/alerts/mailKeys:POSTMARK_API_KEY
VAULT_REGION=us-east-1
VAULT_ACCOUNT_ID=123456789012
EMAIL_FROM_ADDRESS=alerts@yourdomain.com
EMAIL_TO_ADDRESSES=admin@yourdomain.com,team@yourdomain.com
```

## Benefits of This Structure

### 1. **Separation of Concerns**
- `postmark_cw_alerts.py`: Business logic & AWS integration
- `email_templates.py`: UI/UX and email formatting
- `requirements.txt`: Dependency management

### 2. **Maintainability**
- Easy to modify email templates without touching Lambda logic
- CSS changes are isolated to the templates file
- Template reusability across different functions

### 3. **Testing**
- Can test email templates independently
- Easier to mock template functions for unit tests
- Clear separation makes debugging easier

### 4. **Scalability**
- Easy to add new email templates (e.g., different templates for different alarm types)
- Template versioning and A/B testing capabilities
- Can easily add multiple languages

## Template Functions Available

### From `email_templates.py`:

1. **`create_alarm_email_template(template_data)`**
   - Creates HTML email with embedded CSS
   - Dynamic styling based on impact level
   - Responsive design

2. **`create_plain_text_template(template_data)`**
   - Creates plain text version
   - Fallback for email clients that don't support HTML

3. **`get_header_style_and_icon(impact)`**
   - Returns appropriate colors and icons
   - Supports: Critical, Warning, Status-OK, Info

4. **`create_description_section(description)`**
   - Conditionally creates description section
   - Handles empty/default descriptions

## Environment Variables Required

Set these in AWS Lambda Console:
```
POSTMARK_API_KEY=your_postmark_api_key
EMAIL_FROM_ADDRESS=alerts@yourdomain.com
EMAIL_TO_ADDRESSES=admin@yourdomain.com,team@yourdomain.com
EMAIL_CC_ADDRESSES=manager@yourdomain.com (optional)
```

## Customization Examples

### Add New Template Style:
```python
# In email_templates.py
IMPACT_CONFIGS['Custom'] = {
    'header_bg': 'linear-gradient(135deg, #purple, #pink)',
    'icon': '🔥',
    'color': '#purple'
}
```

### Create Multiple Templates:
```python
def create_simple_email_template(template_data):
    # Minimal template for less critical alerts
    pass

def create_detailed_email_template(template_data):
    # Detailed template for critical alerts
    pass
```

## Deployment Steps

1. **Zip the files**: `zip -r lambda-deployment.zip .`
2. **Upload to AWS Lambda**: Console → Upload .zip file
3. **Set environment variables**: Configuration → Environment variables
4. **Test the function**: Create test event or trigger from CloudWatch

## File Size Optimization

Current structure keeps the deployment package small:
- **PostMark**: ~200KB
- **Templates**: ~5KB
- **Main logic**: ~8KB
- **Total**: ~250KB (well under Lambda limits)

This modular approach makes your Lambda function much more maintainable and professional!


## Sample code: Sample python code to test postmark.

#### 1. Basic [https://postmarkapp.com/send-email/python]

```python
from postmarker.core import PostmarkClient

# Replace with your actual server token
postmark = PostmarkClient(server_token='YOUR_POSTMARK_SERVER_TOKEN')

try:
    postmark.emails.send(
        From='abiswas@example.com',
        To='abiswas@example.com',
        Subject='Hello from Postmark!',
        HtmlBody='<html><body><strong>Hello</strong> dear Postmark user.</body></html>'
    )
    print("Email sent successfully!")
except Exception as e:
    print(f"An error occurred: {e}")
```

#### 2. Sample code with html templates.

```python
import os
from datetime import datetime
from string import Template
from pathlib import Path
from postmarker.core import PostmarkClient

class CloudWatchEmailNotifier:
    def __init__(self, server_token, from_email):
        """Initialize the email notifier with Postmark credentials."""
        self.postmark = PostmarkClient(server_token=server_token)
        self.from_email = from_email
    
    def create_html_template(self, template_data, template_file='cloudwatch_template.html'):
        """Generate HTML using string.Template for safer substitution."""
        current_year = datetime.utcnow().year
        impact = template_data['impact']

        # Configure header styling and icons based on impact level
        header_bg = {
            'Critical': '#d9534f',
            'Warning': '#d9b04f', 
            'Status-OK': '#4fd982'
        }.get(impact, '#4f6fd9')

        header_icon = {
            'Critical': '🚨',
            'Warning': '⚠️',
            'Status-OK': '✅'
        }.get(impact, 'ℹ️')

        # Generate description HTML if description is provided
        description_html = ""
        if template_data.get("description") and template_data["description"] != "No description provided.":
            description_html = f"""
                <div class="reason-box" style="margin-top: 15px; padding: 10px; background: #f9f9f9; border-left: 4px solid #ccc; font-style: italic;">
                    <strong>Description:</strong> {template_data["description"]}
                </div>
            """

        # Prepare all template variables
        template_vars = {
            'header_bg': header_bg,
            'header_icon': header_icon,
            'impact': impact,
            'symbol': template_data.get('symbol', '⚡'),
            'state_change': template_data.get('state_change', 'N/A'),
            'alarm': template_data.get('alarm', 'Unknown Alarm'),
            'account': template_data.get('account', 'N/A'),
            'region': template_data.get('region', 'N/A'),
            'resource': template_data.get('resource', 'N/A'),
            'datetime': template_data.get('datetime', datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')),
            'comparisonoperator': template_data.get('comparisonoperator', 'N/A'),
            'threshold': template_data.get('threshold', 'N/A'),
            'namespace': template_data.get('namespace', 'N/A'),
            'metricname': template_data.get('metricname', 'N/A'),
            'reason': template_data.get('reason', 'No reason provided'),
            'description_html': description_html,
            'current_year': current_year,
            'color': template_data.get('color', header_bg)
        }

        try:
            # Read template file
            template_path = Path(__file__).parent / template_file
            with open(template_path, 'r', encoding='utf-8') as file:
                template_content = file.read()
            
            # Use Template class for safer substitution
            template = Template(template_content)
            html = template.safe_substitute(**template_vars)
            return html
            
        except FileNotFoundError:
            raise FileNotFoundError(f"Template file '{template_file}' not found at {template_path}")
        except Exception as e:
            raise Exception(f"Error processing template: {str(e)}")

    def send_cloudwatch_alarm(self, template_data, to_emails, subject=None):
        """Send CloudWatch alarm notification email."""
        try:
            # Generate HTML content
            html_content = self.create_html_template(template_data)
            
            # Create subject if not provided
            if not subject:
                impact = template_data.get('impact', 'Unknown')
                alarm_name = template_data.get('alarm', 'CloudWatch Alarm')
                subject = f"[{impact}] {alarm_name} - AWS CloudWatch Alert"
            
            # Ensure to_emails is a list
            if isinstance(to_emails, str):
                to_emails = [to_emails]
            
            # Send email to each recipient
            for email in to_emails:
                response = self.postmark.emails.send(
                    From=self.from_email,
                    To=email,
                    Subject=subject,
                    HtmlBody=html_content,
                    TextBody=self.generate_text_version(template_data)  # Optional plain text version
                )
                print(f"Email sent successfully to {email}! Message ID: {response['MessageID']}")
            
            return True
            
        except Exception as e:
            print(f"Failed to send email: {str(e)}")
            return False
    
    def generate_text_version(self, template_data):
        """Generate a plain text version of the email."""
        impact = template_data.get('impact', 'Unknown')
        alarm = template_data.get('alarm', 'Unknown Alarm')
        state_change = template_data.get('state_change', 'N/A')
        reason = template_data.get('reason', 'No reason provided')
        datetime_str = template_data.get('datetime', 'N/A')
        
        text_content = f"""
CloudWatch Alarm Notification

Impact Level: {impact}
Alarm Name: {alarm}
State Change: {state_change}
Date & Time: {datetime_str}

Reason: {reason}

Please review the AWS CloudWatch console for detailed metrics and take appropriate action.

This is an automated notification. Please do not reply.
        """.strip()
        
        return text_content

def main():
    """Main function to demonstrate usage."""
    
    # Configuration
    SERVER_TOKEN = 'YOUR_POSTMARK_SERVER_TOKEN'  # Your Postmark server token
    FROM_EMAIL = 'abiswas@example.com'
    TO_EMAILS = ['abiswas@example.com']  # Can be a list of emails
    
    # Initialize the notifier
    notifier = CloudWatchEmailNotifier(SERVER_TOKEN, FROM_EMAIL)
    
    # Sample CloudWatch alarm data
    sample_alarm_data = {
        'impact': 'Critical',
        'symbol': '🔥',
        'state_change': 'OK → ALARM',
        'alarm': 'HighCPUUtilization',
        'account': '123456789012',
        'region': 'us-east-1',
        'resource': 'EC2 Instance (i-1234567890abcdef0)',
        'datetime': '2024-01-15 10:30:00 UTC',
        'comparisonoperator': 'GreaterThanThreshold',
        'threshold': '80%',
        'namespace': 'AWS/EC2',
        'metricname': 'CPUUtilization',
        'reason': 'Threshold Crossed: 1 datapoint [85.5 (15/01/24 10:29:00)] was greater than the threshold (80.0).',
        'description': 'CPU utilization is consistently high on production server',
        'color': '#d9534f'
    }
    
    # Send the alarm notification
    success = notifier.send_cloudwatch_alarm(
        template_data=sample_alarm_data,
        to_emails=TO_EMAILS,
        subject="[CRITICAL] High CPU Utilization Alert - Production Server"
    )
    
    if success:
        print("CloudWatch alarm notification sent successfully!")
    else:
        print("Failed to send CloudWatch alarm notification.")

# Alternative standalone functions (if you prefer not to use the class)
def send_cloudwatch_email_standalone(template_data, to_emails, server_token, from_email, subject=None):
    """Standalone function to send CloudWatch email."""
    notifier = CloudWatchEmailNotifier(server_token, from_email)
    return notifier.send_cloudwatch_alarm(template_data, to_emails, subject)

if __name__ == "__main__":
    main()
```