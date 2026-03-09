# SKILL.md Troubleshooting Update
## For: pvm-use skill documentation

---

## Enhanced Troubleshooting Section

**Replace the existing Troubleshooting section with this expanded version:**

---

## Troubleshooting

### Common Errors

| Problem | Cause | Fix |
|---------|-------|-----|
| `Action 'xxx' is not in the allowlist` | Requested action not in action allowlist | See "Debugging Action Allowlist" below |
| `Resource not in allowlist` | Requested resource not in resource allowlist | Add resource ARN to `pvm-allowlists` table |
| `403 Forbidden` on request | Not calling from approved VPC | Must call from VPC with API Gateway endpoint access |
| `DENIED` status | Approver rejected the request | Revise request justification, try again |
| `FAILED` after approval | IAM role doesn't exist or grant failed | Verify role ARN exists; check CloudWatch logs |
| Request times out (no response) | Approver didn't receive/open email | Check SES delivery; verify approver email in SSM |
| `MessageRejected` (SES) | Email address not verified in SES sandbox | Verify both sender and recipient emails in SES console |

### Debugging "Action not in allowlist" Errors

This is the most common deployment issue. If you get:
```
{
  "error": "Action 's3:PutObject' is not in the allowlist"
}
```

**Root Cause:** The `pvm-allowlist` (singular) table either doesn't exist or doesn't contain the requested action in its `allowedActions` array.

#### Step 1: Verify the action allowlist table exists

```bash
aws dynamodb describe-table --table-name pvm-allowlist --region YOUR-REGION
```

**If you get `ResourceNotFoundException`:** The table is missing! Create it:

```bash
# Create the table
aws dynamodb create-table \
  --table-name pvm-allowlist \
  --attribute-definitions '[{"AttributeName":"id","AttributeType":"S"}]' \
  --key-schema '[{"AttributeName":"id","KeyType":"HASH"}]' \
  --billing-mode PAY_PER_REQUEST \
  --region YOUR-REGION

# Wait for table to be active
aws dynamodb wait table-exists --table-name pvm-allowlist --region YOUR-REGION

# Add initial allowlist
aws dynamodb put-item --table-name pvm-allowlist --region YOUR-REGION --item '{
  "id": {"S": "current"},
  "allowedActions": {"L": [
    {"S": "s3:GetObject"},
    {"S": "s3:ListBucket"},
    {"S": "s3:PutObject"},
    {"S": "s3:DeleteObject"},
    {"S": "dynamodb:GetItem"},
    {"S": "dynamodb:PutItem"},
    {"S": "dynamodb:Query"},
    {"S": "dynamodb:Scan"}
  ]},
  "deniedActions": {"L": [
    {"S": "iam:*"},
    {"S": "*:*"},
    {"S": "organizations:*"},
    {"S": "account:*"}
  ]},
  "version": {"N": "1"}
}'
```

#### Step 2: Check current allowed actions

```bash
aws dynamodb get-item --table-name pvm-allowlist --region YOUR-REGION \
  --key '{"id":{"S":"current"}}' \
  --query 'Item.allowedActions.L[*].S' \
  --output table
```

This shows all currently allowed actions. If your action is missing, proceed to Step 3.

#### Step 3: Add missing action to allowlist

```bash
# Example: Add secretsmanager:GetSecretValue
aws dynamodb update-item --table-name pvm-allowlist --region YOUR-REGION \
  --key '{"id":{"S":"current"}}' \
  --update-expression "SET allowedActions = list_append(allowedActions, :new)" \
  --expression-attribute-values '{":new":{"L":[{"S":"secretsmanager:GetSecretValue"}]}}'

# Verify it was added
aws dynamodb get-item --table-name pvm-allowlist --region YOUR-REGION \
  --key '{"id":{"S":"current"}}' \
  --query 'Item.allowedActions.L[*].S' | grep secretsmanager
```

#### Step 4: Force Lambda cache refresh (if needed)

The Lambda function caches the allowlist for 5-15 minutes to reduce DynamoDB reads. If you just added an action but still get the error:

```bash
# Force a cold start by updating an environment variable
aws lambda update-function-configuration \
  --function-name pvm-api \
  --region YOUR-REGION \
  --environment Variables={CACHE_BUST=$(date +%s)}

# Wait 30 seconds for the update to propagate
sleep 30

# Retry your PVM request
```

**Alternative:** Wait 5-15 minutes for the cache to naturally expire, then retry.

### Debugging "Resource not in allowlist" Errors

If you get:
```
{
  "error": "Resource 'arn:aws:s3:::my-bucket/*' is not in the allowlist"
}
```

The resource allowlist (`pvm-allowlists`, plural) doesn't contain your resource ARN.

**Add the resource:**
```bash
# For S3 buckets
aws dynamodb put-item --table-name pvm-allowlists --region YOUR-REGION --item '{
  "list_id": {"S": "s3-buckets"},
  "resource_arn": {"S": "arn:aws:s3:::your-bucket-name/prefix/*"}
}'

# For DynamoDB tables
aws dynamodb put-item --table-name pvm-allowlists --region YOUR-REGION --item '{
  "list_id": {"S": "dynamodb-tables"},
  "resource_arn": {"S": "arn:aws:dynamodb:YOUR-REGION:YOUR-ACCOUNT-ID:table/your-table"}
}'

# Verify it was added
aws dynamodb scan --table-name pvm-allowlists --region YOUR-REGION \
  --filter-expression "resource_arn = :arn" \
  --expression-attribute-values '{":arn":{"S":"arn:aws:s3:::your-bucket-name/prefix/*"}}'
```

**No cache flush needed:** Resource allowlist changes take effect immediately.

### Debugging Request Timeout Issues

If your request stays `PENDING` forever:

**1. Check if approval email was sent:**
```bash
# Get request details
REQUEST_ID="arn:aws:states:..."  # Your request ID
ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$REQUEST_ID")
curl -s "$PVM_API_BASE/permissions/status/$ENCODED" | jq .
```

Look for `email_sent_at` timestamp. If missing, check CloudWatch logs for `pvm-send-approval-email` Lambda.

**2. Check SES email delivery:**
```bash
# Check SES sending statistics
aws ses get-send-statistics --region YOUR-REGION | jq '.SendDataPoints[-1]'
```

Look for `Bounces` or `Rejects` counts.

**3. Verify approver email in SSM:**
```bash
aws ssm get-parameter --name /pvm/approver-email --region YOUR-REGION --query 'Parameter.Value'
```

**4. Check SES sandbox mode:**
If you're in SES sandbox, BOTH sender and recipient emails must be verified:
```bash
aws ses list-identities --region YOUR-REGION
```

Request production access: https://console.aws.amazon.com/ses/home#/account

### Debugging Lambda Errors

**Check CloudWatch Logs:**
```bash
# Get recent logs for API Lambda
aws logs tail /aws/lambda/pvm-api --region YOUR-REGION --follow

# Search for errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/pvm-api \
  --filter-pattern "ERROR" \
  --region YOUR-REGION \
  --max-items 10
```

**Common Lambda errors:**
- `Cannot read property 'xxx' of undefined` → Missing env var or table
- `AccessDeniedException` → Lambda IAM role lacks permissions
- `ResourceNotFoundException` → Table name wrong or table doesn't exist

### Verification Checklist

Before opening a support issue, verify:

- [ ] Both DynamoDB tables exist (`pvm-allowlist` + `pvm-allowlists`)
- [ ] Action is in `pvm-allowlist.allowedActions`
- [ ] Resource is in `pvm-allowlists` table
- [ ] Lambda env vars are correct (singular vs plural table names)
- [ ] SSM parameters exist (`/pvm/approver-email`, `/pvm/jwt-secret`)
- [ ] IAM role exists and has correct trust policy
- [ ] SES is configured (verified sender email)
- [ ] API Gateway endpoint is accessible from your VPC

**Quick verification script:**
```bash
#!/bin/bash
echo "Checking PVM deployment..."
aws dynamodb describe-table --table-name pvm-allowlist --region $REGION --query 'Table.TableStatus'
aws dynamodb describe-table --table-name pvm-allowlists --region $REGION --query 'Table.TableStatus'
aws ssm get-parameter --name /pvm/approver-email --region $REGION --query 'Parameter.Value'
aws lambda get-function --function-name pvm-api --region $REGION --query 'Configuration.State'
echo "All checks passed!"
```

---

## Advanced Troubleshooting

### Lambda Cache Behavior

The `pvm-api` Lambda caches the action allowlist to reduce DynamoDB read costs:
- **Cache TTL:** 5-15 minutes (configurable in `src/config.js`)
- **Cache key:** `allowlist-current`
- **Cache invalidation:** Automatic after TTL or Lambda cold start

**Force immediate cache refresh:**
```bash
# Option 1: Update any env var (triggers cold start)
aws lambda update-function-configuration --function-name pvm-api --region YOUR-REGION \
  --environment Variables={CACHE_BUST=$(date +%s)}

# Option 2: Force new Lambda version
aws lambda publish-version --function-name pvm-api --region YOUR-REGION

# Option 3: Delete all Lambda ENIs (aggressive, use as last resort)
aws ec2 describe-network-interfaces --region YOUR-REGION \
  --filters "Name=description,Values=AWS Lambda VPC ENI*" \
  --query 'NetworkInterfaces[*].NetworkInterfaceId' \
  --output text | xargs -I {} aws ec2 delete-network-interface --network-interface-id {}
```

### Step Functions Execution Debugging

**View execution history:**
```bash
# List recent executions
aws stepfunctions list-executions \
  --state-machine-arn arn:aws:states:YOUR-REGION:YOUR-ACCOUNT-ID:stateMachine:pvm-workflow \
  --max-results 10 \
  --region YOUR-REGION

# Get execution details
aws stepfunctions describe-execution \
  --execution-arn "$REQUEST_ID" \
  --region YOUR-REGION
```

**Common execution failures:**
- `States.TaskFailed` → Lambda threw an error (check CloudWatch logs)
- `States.Timeout` → Lambda exceeded timeout (default 30s)
- `States.Permissions` → Step Functions role lacks Lambda invoke permission

---

## Getting Help

If none of the above resolves your issue:

1. **Check CloudWatch Logs** for all Lambda functions (`/aws/lambda/pvm-*`)
2. **Review Step Functions execution history** for your request
3. **Verify DynamoDB tables** contain expected data
4. **Test Lambda functions directly** via AWS Console (Test tab)

**Include this info when reporting issues:**
- PVM version / commit hash
- AWS region
- Request ID (full ARN)
- Error message (full text)
- CloudWatch log excerpts
- DynamoDB table scan results
