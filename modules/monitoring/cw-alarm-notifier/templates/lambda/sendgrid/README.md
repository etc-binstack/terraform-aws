# Lambda Project Structure - Separated Templates

## File Structure (simple)
```
lambda-cloudwatch-alarm/
├── sendgrid_cw_alerts.py   # Main Lambda handler (updated)
├── requirements.txt        # Dependencies
└── sendgrid_cw_alerts.zip   # Final deployment package
```

## File Structure (seperated)
```
lambda-cloudwatch-alarm/
├── sendgrid_cw_alerts.py   # Main Lambda handler (updated)
├── email_templates.py      # HTML/CSS templates & functions
├── requirements.txt        # Dependencies
└── sendgrid_cw_alerts.zip   # Final deployment package
```

## Setup Instructions

### 1. Create Project Directory
```bash
mkdir sendgrip_cw_alerts
cd sendgrip_cw_alerts
```

### 2. Create Files

#### Create `requirements.txt`:
```txt
# SendGrid API client for sending emails
sendgrid==6.12.2

# HTTP client library (dependency of sendgrid)
python-http-client==3.3.7

# ECDSA cryptographic library (dependency of sendgrid)
starkbank-ecdsa==2.2.0

# Boto3 for AWS Secrets Manager access (if used)
boto3>=1.28.0

# AWS SDK core dependency
botocore>=1.31.0
```

#### Create `email_templates.py`: (Optional)
Copy the content from the "email_templates.py" artifact above.

#### Create `sendgrid_cw_alerts.py`:
Copy the content from the updated "Lambda CloudWatch Alarm with SendGrid" artifact above.

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

## Benefits of This Structure

### 1. **Separation of Concerns**
- `sendgrid_cw_alerts.py`: Business logic & AWS integration
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
SENDGRID_API_KEY=your_sendgrid_api_key
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
- **SendGrid**: ~200KB
- **Templates**: ~5KB
- **Main logic**: ~8KB
- **Total**: ~250KB (well under Lambda limits)

This modular approach makes your Lambda function much more maintainable and professional!