# PVM Deployment Guide - Callback-Free + DynamoDB Allowlist

## What's New

✅ Callbacks removed - Users poll status endpoint instead  
✅ Allowlist centralized in DynamoDB table  
✅ Step Functions simplified (27 → 21 states)  
✅ ~343 lines of code removed  

## Prerequisites

- AWS CLI configured with admin access
- Node.js installed (for running scripts)
- Lambda packages built (`./scripts/rebuild-lambdas.sh` already run)

## Deployment Steps

### Step 1: Create DynamoDB Allowlist Table

```bash
cd /home/ubuntu/.openclaw/workspace/aws-permissions-vending-machine
node scripts/create-allowlist-table.js
```

**Required IAM Permission:**
- `dynamodb:CreateTable`
- `dynamodb:PutItem` (for initial data)

**What it creates:**
- Table: `pvm-allowlist`
- Initial allowlist with DynamoDB cleanup actions

---

### Step 2: Add IAM Permissions for Lambdas

**All Lambda execution roles need:**

```bash
aws iam put-role-policy \
  --role-name pvm-prod-ApiFunctionRole-XXXXX \
  --policy-name AllowlistRead \
  --policy-document file://iam-policy-allowlist-read.json

# Repeat for each task Lambda role:
# - pvm-prod-StoreRequestFunctionRole-XXXXX
# - pvm-prod-SendApprovalEmailFunctionRole-XXXXX
# - pvm-prod-GrantPermissionsFunctionRole-XXXXX
# - pvm-prod-RevokePermissionsFunctionRole-XXXXX
```

Or attach managed policy to all roles.

---

### Step 3: Set Environment Variables

**All Lambdas need:**

```bash
# API Lambda
aws lambda update-function-configuration \
  --function-name pvm-api \
  --environment Variables="{DYNAMODB_ALLOWLIST_TABLE=pvm-allowlist}" \
  --region us-west-2

# Task Lambdas (repeat for each)
aws lambda update-function-configuration \
  --function-name pvm-store-request \
  --environment Variables="{DYNAMODB_ALLOWLIST_TABLE=pvm-allowlist}" \
  --region us-west-2

# ... (repeat for other 3 task functions)
```

---

### Step 4: Deploy Lambda Functions

```bash
./scripts/deploy-lambdas.sh
```

This deploys all 5 Lambda functions with callback-free code + DynamoDB allowlist loading.

---

### Step 5: Update Step Functions State Machine

```bash
# Get current state machine ARN
STATE_MACHINE_ARN="arn:aws:states:us-west-2:YOUR-ACCOUNT-ID:stateMachine:pvm-workflow"

# Update with callback-free definition
aws stepfunctions update-state-machine \
  --state-machine-arn $STATE_MACHINE_ARN \
  --definition file://docs/step-functions-state-machine.json \
  --region us-west-2
```

**Changes:**
- Removed: SendApprovalCallback, SendDenialCallback, SendRevocationCallback
- Removed: CheckRevocationCallbackEnabled choice state
- Simplified success/failure paths

---

### Step 6: Delete Old SendCallback Lambda (Optional)

```bash
aws lambda delete-function \
  --function-name pvm-send-callback \
  --region us-west-2
```

This function is no longer needed.

---

### Step 7: Test End-to-End

```bash
# Submit test request
curl -s -X POST "https://YOUR-API-ID.execute-api.us-west-2.amazonaws.com/prod/permissions/request" \
  -H "Content-Type: application/json" \
  -d '{
    "requester": {
      "identity": "arn:aws:iam::YOUR-ACCOUNT-ID:role/test-role",
      "name": "Deployment Test"
    },
    "permissions_requested": [{
      "action": "s3:GetObject",
      "resource": "arn:aws:s3:::test-bucket/*"
    }],
    "expiration_minutes": 2
  }' | jq .

# Check status
REQUEST_ID="<request_id_from_above>"
curl -s "https://YOUR-API-ID.execute-api.us-west-2.amazonaws.com/prod/permissions/status/${REQUEST_ID}" | jq .

# Approve via email link
# Wait 2 minutes
# Verify revocation
curl -s "https://YOUR-API-ID.execute-api.us-west-2.amazonaws.com/prod/permissions/status/${REQUEST_ID}" | jq .
```

Expected flow:
1. Status: `AWAITING_APPROVAL`
2. After approval: `ACTIVE`
3. After 2 min: `REVOKED`

---

### Step 8: Clean Up Test Data

```bash
node scripts/cleanup-db.js --dry-run  # Review
node scripts/cleanup-db.js            # Execute
```

---

## Verification Checklist

- [ ] DynamoDB table `pvm-allowlist` created
- [ ] All Lambda roles have `dynamodb:GetItem` permission
- [ ] All Lambdas have `DYNAMODB_ALLOWLIST_TABLE` env var
- [ ] All Lambda functions deployed successfully
- [ ] Step Functions state machine updated
- [ ] Test request completes end-to-end
- [ ] Status endpoint returns correct states
- [ ] Permissions auto-revoke after expiry
- [ ] Old test data cleaned up

---

## Rollback Plan

If issues arise:

```bash
# Revert to previous deployment
git checkout v1.0-working-with-callbacks
./deploy-all-functions.sh  # (old deployment script)

# Restore old state machine
aws stepfunctions update-state-machine \
  --state-machine-arn $STATE_MACHINE_ARN \
  --definition file://docs/step-functions-state-machine-OLD.json \
  --region us-west-2
```

---

## Managing the Allowlist

**View current allowlist:**
```bash
node scripts/update-allowlist.js --view
```

**Add new action:**
```bash
node scripts/update-allowlist.js
# Follow interactive prompts
```

**Update from file:**
```bash
node scripts/update-allowlist.js --file new-allowlist.json
```

**Required IAM permission (for human admin):**
- `dynamodb:GetItem` on `pvm-allowlist`
- `dynamodb:PutItem` on `pvm-allowlist`
- `dynamodb:PutItem` on `pvm-audit-logs` (for logging)

---

## Cost Impact

- **DynamoDB:** ~$0.25/month (on-demand, minimal reads/writes)
- **Lambda:** No change
- **Step Functions:** Slightly less (fewer state transitions)

---

## Support

- Documentation: `docs/`
- IAM Setup: `IAM-PERMISSIONS.md`
- Migration Notes: `DYNAMODB-ALLOWLIST-MIGRATION.md`
- Callback Removal: `CALLBACK-REMOVAL-SUMMARY.md`

