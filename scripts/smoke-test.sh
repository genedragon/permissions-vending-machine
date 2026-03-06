#!/bin/bash
set -e

# PVM Smoke Test — verifies all prerequisites are in place
#
# Usage:
#   ./scripts/smoke-test.sh                    # Check everything
#   ./scripts/smoke-test.sh --region us-east-1 # Custom region
#
# Checks:
#   1. SSM parameters exist (/pvm/approver-email, /pvm/jwt-secret)
#   2. DynamoDB tables exist (pvm-requests, pvm-allowlist)
#   3. Allowlist is not empty
#   4. Grant/Revoke Lambda roles have IAM permissions
#   5. SES sender identity is verified
#   6. Lambda functions exist and are configured

REGION="${AWS_DEFAULT_REGION:-us-west-2}"
PASS=0
FAIL=0
WARN=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --region) REGION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

check_pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
check_fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
check_warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }

echo "🔍 PVM Smoke Test"
echo "=================="
echo "Region: $REGION"
echo ""

# 1. SSM Parameters
echo "[1/6] SSM Parameters"
for param in /pvm/approver-email /pvm/jwt-secret; do
  if aws ssm get-parameter --name "$param" --region "$REGION" >/dev/null 2>&1; then
    check_pass "$param exists"
  else
    check_fail "$param missing — run setup per DEPLOYMENT-GUIDE.md step 2"
  fi
done

# 2. DynamoDB Tables
echo ""
echo "[2/6] DynamoDB Tables"
for table in pvm-requests pvm-allowlist; do
  if aws dynamodb describe-table --table-name "$table" --region "$REGION" >/dev/null 2>&1; then
    check_pass "Table $table exists"
  else
    check_fail "Table $table missing — run: node scripts/create-tables.js"
  fi
done

# 3. Allowlist contents
echo ""
echo "[3/6] Allowlist Configuration"
ALLOWLIST=$(aws dynamodb get-item --table-name pvm-allowlist --key '{"id":{"S":"current"}}' \
  --region "$REGION" --query 'Item.allowedActions.L' --output json 2>/dev/null || echo "[]")

if [ "$ALLOWLIST" = "[]" ] || [ "$ALLOWLIST" = "null" ]; then
  check_fail "Allowlist is empty — add actions via: node scripts/update-allowlist.js"
else
  ACTION_COUNT=$(echo "$ALLOWLIST" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  check_pass "Allowlist has $ACTION_COUNT allowed actions"
  
  # Check for common services
  if echo "$ALLOWLIST" | grep -q "cloudfront:"; then
    check_pass "CloudFront actions in allowlist"
  else
    check_warn "No CloudFront actions in allowlist (add if needed — see docs/common-allowlists/)"
  fi
fi

DENYLIST=$(aws dynamodb get-item --table-name pvm-allowlist --key '{"id":{"S":"current"}}' \
  --region "$REGION" --query 'Item.deniedActions.L' --output json 2>/dev/null || echo "[]")

if echo "$DENYLIST" | grep -q "iam:"; then
  check_pass "IAM actions are denied (good security)"
else
  check_warn "iam:* not in deny list — consider adding for safety"
fi

# 4. Lambda functions
echo ""
echo "[4/6] Lambda Functions"
FUNCTIONS=("pvm-api" "pvm-store-request" "pvm-send-approval-email" "pvm-grant-permissions" "pvm-revoke-permissions")
for func in "${FUNCTIONS[@]}"; do
  if aws lambda get-function --function-name "$func" --region "$REGION" >/dev/null 2>&1; then
    check_pass "$func exists"
  else
    check_fail "$func missing — run: ./scripts/deploy-lambdas.sh"
  fi
done

# 5. Grant/Revoke Lambda IAM permissions
echo ""
echo "[5/6] Grant/Revoke IAM Permissions"

GRANT_ROLE=$(aws iam list-roles \
  --query "Roles[?contains(RoleName, 'GrantPermissions')].RoleName" \
  --output text 2>/dev/null)

if [ -n "$GRANT_ROLE" ]; then
  if aws iam get-role-policy --role-name "$GRANT_ROLE" --policy-name "pvm-grant-revoke-permissions" >/dev/null 2>&1; then
    check_pass "Grant Lambda role ($GRANT_ROLE) has IAM permissions"
  else
    check_fail "Grant Lambda role ($GRANT_ROLE) MISSING IAM permissions — run: ./scripts/setup-iam-roles.sh"
  fi
else
  check_fail "No Grant Lambda role found"
fi

REVOKE_ROLE=$(aws iam list-roles \
  --query "Roles[?contains(RoleName, 'RevokePermissions')].RoleName" \
  --output text 2>/dev/null)

if [ -n "$REVOKE_ROLE" ]; then
  if aws iam get-role-policy --role-name "$REVOKE_ROLE" --policy-name "pvm-grant-revoke-permissions" >/dev/null 2>&1; then
    check_pass "Revoke Lambda role ($REVOKE_ROLE) has IAM permissions"
  else
    check_fail "Revoke Lambda role ($REVOKE_ROLE) MISSING IAM permissions — run: ./scripts/setup-iam-roles.sh"
  fi
else
  check_fail "No Revoke Lambda role found"
fi

# 6. SES
echo ""
echo "[6/6] SES Email Configuration"
APPROVER_EMAIL=$(aws ssm get-parameter --name /pvm/approver-email --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "")

if [ -n "$APPROVER_EMAIL" ]; then
  VERIFICATION=$(aws ses get-identity-verification-attributes \
    --identities "$APPROVER_EMAIL" --region "$REGION" \
    --query "VerificationAttributes.\"$APPROVER_EMAIL\".VerificationStatus" \
    --output text 2>/dev/null || echo "Unknown")
  
  if [ "$VERIFICATION" = "Success" ]; then
    check_pass "SES: $APPROVER_EMAIL is verified"
  else
    check_warn "SES: $APPROVER_EMAIL verification status: $VERIFICATION (may block approval emails)"
  fi
else
  check_warn "Could not read approver email from SSM"
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━"
echo "Results: ✅ $PASS passed | ❌ $FAIL failed | ⚠️  $WARN warnings"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Fix the failures above before using PVM."
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "PVM should work, but review the warnings."
  exit 0
else
  echo ""
  echo "🎉 All checks passed! PVM is ready."
  exit 0
fi
