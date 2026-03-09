# README.md Documentation Update
## Section: Allowlist Architecture (Add after "Architecture" section)

---

## Allowlist Architecture (Important!)

PVM uses **two separate DynamoDB tables** for authorization. Understanding this architecture is critical for successful deployment.

### 1. Action Allowlist (`pvm-allowlist`, singular)

Controls **what IAM actions** can be requested globally.

**Purpose:** Prevents agents from requesting dangerous actions like `iam:*` or `organizations:*`. Acts as a global safety rail.

**Table Schema:**
- **Primary Key:** `id` (String)
- **Single Item:** `id = "current"`

**Item Structure:**
```json
{
  "id": "current",
  "allowedActions": [
    "s3:GetObject",
    "s3:PutObject",
    "s3:ListBucket",
    "dynamodb:GetItem",
    "dynamodb:PutItem"
  ],
  "deniedActions": [
    "iam:*",
    "*:*",
    "organizations:*",
    "account:*"
  ],
  "version": 1
}
```

**Create table:**
```bash
aws dynamodb create-table \
  --table-name pvm-allowlist \
  --attribute-definitions '[{"AttributeName":"id","AttributeType":"S"}]' \
  --key-schema '[{"AttributeName":"id","KeyType":"HASH"}]' \
  --billing-mode PAY_PER_REQUEST \
  --region YOUR-REGION
```

**Initialize allowlist:**
```bash
aws dynamodb put-item --table-name pvm-allowlist --region YOUR-REGION --item '{
  "id": {"S": "current"},
  "allowedActions": {"L": [
    {"S": "s3:GetObject"},
    {"S": "s3:PutObject"},
    {"S": "s3:ListBucket"},
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

**Add more actions later:**
```bash
aws dynamodb update-item --table-name pvm-allowlist --region YOUR-REGION \
  --key '{"id":{"S":"current"}}' \
  --update-expression "SET allowedActions = list_append(allowedActions, :new)" \
  --expression-attribute-values '{":new":{"L":[{"S":"secretsmanager:GetSecretValue"}]}}'
```

### 2. Resource Allowlist (`pvm-allowlists`, plural)

Controls **what specific resources** can be accessed.

**Purpose:** Even if an action is allowed, agents can only request access to resources in this table.

**Table Schema:**
- **Primary Key:** `list_id` (String) + `resource_arn` (String) [Composite]
- **Multiple Items:** One per authorized resource

**Item Structure:**
```json
{
  "list_id": "s3-buckets",
  "resource_arn": "arn:aws:s3:::your-bucket-name/prefix/*"
}
```

**Create table:**
```bash
aws dynamodb create-table \
  --table-name pvm-allowlists \
  --attribute-definitions \
    '[{"AttributeName":"list_id","AttributeType":"S"},
      {"AttributeName":"resource_arn","AttributeType":"S"}]' \
  --key-schema \
    '[{"AttributeName":"list_id","KeyType":"HASH"},
      {"AttributeName":"resource_arn","KeyType":"RANGE"}]' \
  --billing-mode PAY_PER_REQUEST \
  --region YOUR-REGION
```

**Add resources:**
```bash
# Allow S3 bucket access
aws dynamodb put-item --table-name pvm-allowlists --region YOUR-REGION --item '{
  "list_id": {"S": "s3-buckets"},
  "resource_arn": {"S": "arn:aws:s3:::your-bucket-name/*"}
}'

# Allow DynamoDB table access
aws dynamodb put-item --table-name pvm-allowlists --region YOUR-REGION --item '{
  "list_id": {"S": "dynamodb-tables"},
  "resource_arn": {"S": "arn:aws:dynamodb:YOUR-REGION:YOUR-ACCOUNT-ID:table/your-table"}
}'

# Allow EC2 instance access
aws dynamodb put-item --table-name pvm-allowlists --region YOUR-REGION --item '{
  "list_id": {"S": "ec2-instances"},
  "resource_arn": {"S": "arn:aws:ec2:YOUR-REGION:YOUR-ACCOUNT-ID:instance/*"}
}'
```

### How Validation Works

When an agent requests permissions:

1. **Step 1:** Check if the requested **action** is in `pvm-allowlist.allowedActions` ✅
2. **Step 2:** Check if the requested **action** is NOT in `pvm-allowlist.deniedActions` ✅
3. **Step 3:** Check if the requested **resource** is in `pvm-allowlists` table ✅
4. If all pass → email approval sent
5. If any fail → request rejected immediately

**Example:**
```json
{
  "permissions_requested": [
    {"action": "s3:PutObject", "resource": "arn:aws:s3:::my-bucket/data/*"}
  ]
}
```

Validates as:
- ✅ `s3:PutObject` in allowedActions?
- ✅ `s3:PutObject` NOT in deniedActions?
- ✅ `arn:aws:s3:::my-bucket/data/*` in pvm-allowlists table?
- → All pass → send approval email

### ⚠️ Critical Deployment Note

**Both tables must exist before PVM can function.** If `pvm-allowlist` (singular) is missing, the Lambda will fall back to hardcoded defaults:
```javascript
// Hardcoded fallback (src/config.js)
const DEFAULT_ALLOWED_ACTIONS = ["s3:GetObject", "s3:ListBucket"];
```

This causes "Action not in allowlist" errors for all other actions.

**Verify both tables exist:**
```bash
aws dynamodb describe-table --table-name pvm-allowlist --region YOUR-REGION
aws dynamodb describe-table --table-name pvm-allowlists --region YOUR-REGION
```

---

## Lambda Environment Variables Reference

**Add this section in the "Configuration" area**

### Lambda Environment Variables

Each Lambda function requires specific environment variables. The main API Lambda (`pvm-api`) uses:

| Variable | Required | Description | Example Value |
|----------|----------|-------------|---------------|
| `DYNAMODB_REQUESTS_TABLE` | Yes | Table for request lifecycle storage | `pvm-requests` |
| `DYNAMODB_ALLOWLIST_TABLE` | Yes | **Action** allowlist table (singular!) | `pvm-allowlist` |
| `DYNAMODB_ALLOWLISTS_TABLE` | Yes | **Resource** allowlist table (plural!) | `pvm-allowlists` |
| `STATE_MACHINE_ARN` | Yes | Step Functions ARN for workflow | `arn:aws:states:REGION:ACCOUNT:stateMachine:pvm-workflow` |
| `APPROVER_EMAIL` | No (from SSM) | Email for approval notifications | Loaded from `/pvm/approver-email` |
| `JWT_SECRET` | No (from SSM) | Secret for callback token signing | Loaded from `/pvm/jwt-secret` |

**⚠️ Common Mistake:** Confusing the singular vs plural table names!

```bash
# Correct
DYNAMODB_ALLOWLIST_TABLE = "pvm-allowlist"   # Actions (singular)
DYNAMODB_ALLOWLISTS_TABLE = "pvm-allowlists"  # Resources (plural)

# Wrong (will cause validation failures)
DYNAMODB_ALLOWLIST_TABLE = "pvm-allowlists"
DYNAMODB_ALLOWLISTS_TABLE = "pvm-allowlist"
```

**Verify Lambda configuration:**
```bash
aws lambda get-function-configuration \
  --function-name pvm-api \
  --region YOUR-REGION \
  --query 'Environment.Variables' \
  --output json
```

**Update environment variables:**
```bash
aws lambda update-function-configuration \
  --function-name pvm-api \
  --region YOUR-REGION \
  --environment 'Variables={
    DYNAMODB_REQUESTS_TABLE=pvm-requests,
    DYNAMODB_ALLOWLIST_TABLE=pvm-allowlist,
    DYNAMODB_ALLOWLISTS_TABLE=pvm-allowlists,
    STATE_MACHINE_ARN=arn:aws:states:YOUR-REGION:YOUR-ACCOUNT-ID:stateMachine:pvm-workflow
  }'
```

**Note:** After updating env vars, the Lambda will cold-start on the next invocation. This can take 10-30 seconds.
