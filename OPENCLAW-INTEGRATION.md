# OpenClaw Integration Guide

This guide explains how to integrate PVM (Permissions Vending Machine) with OpenClaw agents.

## Overview

PVM is designed to work as an OpenClaw agent skill, allowing your agents to autonomously request temporary AWS permissions through a human-approved workflow.

## Installation Options

### Option 1: Install as OpenClaw Skill (Recommended)

For OpenClaw users, install PVM as a skill:

```bash
openclaw skills install aws-pvm
cd ~/.openclaw/skills/aws-pvm
npm install
```

**Skill Name:** `aws-pvm`

This installs the `pvm-use` skill which provides:
- Request/polling scripts
- Agent tool integrations
- Configuration templates
- Documentation

### Option 2: Clone from GitHub

If you need to modify the backend infrastructure or contribute to development:

```bash
git clone https://github.com/genedragon/permissions-vending-machine.git
cd permissions-vending-machine
npm install
```

## Prerequisites

Before using PVM with OpenClaw:

1. **PVM Backend Deployed** — Follow the [main README](README.md) to deploy the AWS infrastructure
2. **API Endpoint Configured** — Note your API Gateway URL
3. **Allowlists Configured** — Add authorized resources and actions to DynamoDB
4. **Agent IAM Role** — Your OpenClaw agent needs an IAM role (EC2 instance profile or Lambda role)

## Agent Configuration

### Environment Variables

Set these in your OpenClaw agent environment:

```bash
# Required - your PVM API endpoint
export PVM_API_BASE="https://YOUR-API-ID.execute-api.us-west-2.amazonaws.com/prod"

# Optional - your IAM role ARN (auto-detected on EC2/Lambda)
export PVM_REQUESTER_IDENTITY="arn:aws:iam::ACCOUNT:role/YOUR-ROLE"
```

Or add to your agent's `.env` file or OpenClaw configuration.

### Skill Configuration

If using the skill, copy the example config:

```bash
cd ~/.openclaw/skills/aws-pvm/config
cp pvm.env.example pvm.env
# Edit pvm.env with your API endpoint and settings
```

## Agent Usage Workflow

Once configured, your OpenClaw agent can:

### 1. Request Permissions

```javascript
// Agent detects it needs S3 access
const request = await requestPVMPermission({
  actions: ['s3:GetObject', 's3:PutObject'],
  resources: ['arn:aws:s3:::my-bucket/data/*'],
  durationMinutes: 30,
  reason: 'Process uploaded data files'
});
```

### 2. Await Approval

The agent automatically polls for approval status:

```javascript
// Polling happens in background
// Agent receives notification when status changes to ACTIVE
await waitForApproval(request.request_id);
```

Human approver receives email with:
- Requester identity (agent name + IAM role)
- Requested permissions (actions + resources)
- Duration
- Approve/Deny buttons

### 3. Use Granted Permissions

Once approved, permissions are automatically attached to the agent's IAM role:

```javascript
// Agent can now use AWS SDK directly
const s3 = new AWS.S3();
await s3.getObject({Bucket: 'my-bucket', Key: 'data/file.txt'}).promise();
```

### 4. Automatic Revocation

Permissions are automatically revoked after the requested duration. No cleanup needed.

## Example: Agent Requesting S3 Access

```python
#!/usr/bin/env python3
"""
Example OpenClaw agent requesting S3 access via PVM
"""

import os
import boto3
from pvm_client import PVMClient

def main():
    # Initialize PVM client
    pvm = PVMClient(
        api_base=os.environ['PVM_API_BASE'],
        requester_identity=os.environ.get('PVM_REQUESTER_IDENTITY')
    )
    
    # Request S3 access
    print("Requesting S3 permissions...")
    request = pvm.request_permissions(
        actions=['s3:GetObject', 's3:ListBucket'],
        resources=['arn:aws:s3:::my-data-bucket/*'],
        duration_minutes=30,
        reason='Download and process training data'
    )
    
    print(f"Request submitted: {request['request_id']}")
    print("Waiting for approval...")
    
    # Poll until approved or denied
    status = pvm.poll_until_complete(request['request_id'], timeout_minutes=60)
    
    if status == 'ACTIVE':
        print("✅ Permissions granted! Proceeding with task...")
        
        # Use AWS SDK normally
        s3 = boto3.client('s3')
        response = s3.list_objects_v2(Bucket='my-data-bucket', Prefix='training/')
        
        for obj in response.get('Contents', []):
            print(f"  - {obj['Key']}")
            # Process files...
        
        print("Task complete. Permissions will auto-revoke.")
    
    elif status == 'DENIED':
        print("❌ Request denied by approver")
    else:
        print(f"❌ Request failed with status: {status}")

if __name__ == '__main__':
    main()
```

## Agent Capabilities Enabled by PVM

OpenClaw agents can autonomously:

✅ **Request just-in-time permissions** — No need for broad, always-on IAM policies  
✅ **Provide context** — Explain *why* permissions are needed in the approval request  
✅ **Self-regulate** — Request only what's needed, for only as long as needed  
✅ **Audit trail** — Every permission grant logged in DynamoDB  
✅ **Safe experimentation** — Test new capabilities without permanent IAM changes  

## Multi-Agent Coordination

When running multiple agents:

1. **Shared PVM backend** — All agents use the same API endpoint
2. **Per-agent IAM roles** — Each agent has its own role (for isolation)
3. **Centralized approval** — One human approves all requests (or delegate per agent type)
4. **Shared allowlists** — Configure common resources once

Example: Research agent requests S3 read, deployment agent requests S3 write.

## Security Best Practices

### For Agents

- ✅ Always include a clear `reason` in permission requests
- ✅ Request minimum permissions needed (narrow actions + resources)
- ✅ Use shortest duration that completes the task
- ✅ Handle `DENIED` status gracefully (log and move on)
- ❌ Don't retry denied requests automatically (could be seen as hostile)

### For Humans (Approvers)

- ✅ Verify the requesting agent identity
- ✅ Check if the requested resources make sense for the task
- ✅ Deny overly broad requests (`s3:*` on `*` = bad)
- ✅ Monitor the DynamoDB audit log for patterns
- ❌ Don't approve requests you don't understand

## Troubleshooting

### Agent Can't Reach PVM API

**Error:** `Connection refused` or `403 Forbidden`

**Cause:** PVM API Gateway may be VPC-restricted

**Fix:** Ensure agent's VPC has access to API Gateway endpoint

```bash
# Check API Gateway configuration
aws apigateway get-rest-api --rest-api-id YOUR-API-ID
```

### Agent's IAM Role Not Found

**Error:** `Failed to grant permissions: Role does not exist`

**Cause:** PVM tries to attach policy to a role that doesn't exist

**Fix:** Verify the agent's IAM role ARN is correct:

```bash
aws iam get-role --role-name YOUR-AGENT-ROLE
```

### Request Always Denied

**Error:** Status goes straight to `DENIED` without human interaction

**Cause:** Resource or action not in PVM allowlists

**Fix:** Add to allowlists in DynamoDB:

```bash
# Add resource
aws dynamodb put-item --table-name pvm-allowlists --item '{
  "list_id": {"S": "s3-buckets"},
  "resource_arn": {"S": "arn:aws:s3:::your-bucket/*"}
}'

# Add action (to pvm-allowlist, singular)
aws dynamodb update-item --table-name pvm-allowlist \
  --key '{"id":{"S":"current"}}' \
  --update-expression "SET allowedActions = list_append(allowedActions, :new)" \
  --expression-attribute-values '{":new":{"L":[{"S":"YOUR-ACTION"}]}}'
```

### Approval Email Not Received

**Error:** Request stays `PENDING` forever

**Cause:** SES not configured or in sandbox mode

**Fix:**
1. Verify approver email in SSM: `aws ssm get-parameter --name /pvm/approver-email`
2. Check SES sandbox status (both sender and recipient must be verified)
3. Request SES production access: https://console.aws.amazon.com/ses/

## Advanced: Custom Agent Integration

For agents not using the bundled scripts:

### Manual API Calls

```bash
# Request permissions
curl -X POST https://YOUR-API/prod/permissions/request \
  -H "Content-Type: application/json" \
  -d '{
    "requester": {
      "identity": "arn:aws:iam::ACCOUNT:role/agent-role",
      "name": "my-agent"
    },
    "permissions_requested": [
      {"action": "s3:GetObject", "resource": "arn:aws:s3:::bucket/*"}
    ],
    "expiration_minutes": 30
  }'

# Check status (URL-encode the request_id)
curl https://YOUR-API/prod/permissions/status/ENCODED-REQUEST-ID
```

### Polling Loop

```python
import time
import urllib.parse

def wait_for_approval(request_id, api_base, timeout_seconds=3600):
    """Poll PVM until request is approved or times out"""
    encoded_id = urllib.parse.quote(request_id, safe='')
    start_time = time.time()
    
    while time.time() - start_time < timeout_seconds:
        response = requests.get(f"{api_base}/permissions/status/{encoded_id}")
        data = response.json()
        
        if data['status'] == 'ACTIVE':
            return True
        elif data['status'] in ['DENIED', 'FAILED', 'REVOKED']:
            return False
        
        time.sleep(10)  # Poll every 10 seconds
    
    raise TimeoutError("Approval timeout")
```

## Monitoring Agent Permissions

View all active permissions:

```bash
# Scan requests table for ACTIVE status
aws dynamodb scan --table-name pvm-requests \
  --filter-expression "status = :s" \
  --expression-attribute-values '{":s":{"S":"ACTIVE"}}' \
  --region us-west-2
```

View permissions for specific agent:

```bash
# Filter by requester identity
aws dynamodb scan --table-name pvm-requests \
  --filter-expression "contains(requester_identity, :agent)" \
  --expression-attribute-values '{":agent":{"S":"my-agent-role"}}' \
  --region us-west-2
```

## Related Documentation

- [Main README](README.md) — Backend deployment
- [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) — Detailed AWS setup
- [docs/api-contract.md](docs/api-contract.md) — API specification
- [SKILL.md](SKILL.md) — pvm-use skill documentation (if using skill installation)

## Support

For OpenClaw-specific integration issues:
- OpenClaw docs: https://docs.openclaw.ai
- OpenClaw Discord: https://discord.com/invite/clawd

For PVM backend issues:
- Open an issue: https://github.com/genedragon/permissions-vending-machine/issues

---

**Built for OpenClaw agents requiring temporary, auditable AWS access.**
