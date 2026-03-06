#!/bin/bash
set -e

REGION="us-west-2"

echo "🚀 Deploying PVM Lambda Functions"
echo "=================================="
echo ""

# Check packages exist
if [ ! -f "pvm-api-final.zip" ]; then
    echo "❌ Lambda packages not found. Run ./scripts/rebuild-lambdas.sh first"
    exit 1
fi

# Deploy API Lambda
echo "[1/5] Deploying pvm-api..."
aws lambda update-function-code \
    --function-name pvm-api \
    --zip-file fileb://pvm-api-final.zip \
    --region $REGION \
    --output json > /tmp/deploy-pvm-api.json 2>&1

if [ $? -eq 0 ]; then
    echo "  ✅ pvm-api deployed"
else
    echo "  ❌ pvm-api failed"
    cat /tmp/deploy-pvm-api.json
    exit 1
fi
sleep 2

# Deploy task Lambdas
FUNCTIONS=(
    "pvm-store-request"
    "pvm-send-approval-email"
    "pvm-grant-permissions"
    "pvm-revoke-permissions"
)

CURRENT=2
TOTAL=5

for func in "${FUNCTIONS[@]}"; do
    echo "[$CURRENT/$TOTAL] Deploying $func..."
    
    aws lambda update-function-code \
        --function-name "$func" \
        --zip-file "fileb://${func}-final.zip" \
        --region "$REGION" \
        --output json > "/tmp/deploy-${func}.json" 2>&1
    
    if [ $? -eq 0 ]; then
        echo "  ✅ $func deployed"
    else
        echo "  ❌ $func failed"
        cat "/tmp/deploy-${func}.json"
        exit 1
    fi
    
    CURRENT=$((CURRENT + 1))
    sleep 2
done

echo ""
echo "🎉 All Lambda functions deployed successfully!"
echo ""
echo "Next steps:"
echo "  1. Set DYNAMODB_ALLOWLIST_TABLE=pvm-allowlist env var on all Lambdas"
echo "  2. Update Step Functions state machine (remove callback tasks)"
echo "  3. Run ./scripts/setup-iam-roles.sh to grant IAM permissions to Grant/Revoke Lambdas"
echo "  4. Run ./scripts/smoke-test.sh to verify everything is configured"
echo "  5. Test end-to-end workflow"
