#!/bin/bash
set -e

# Setup IAM roles for PVM Lambda functions
# This script ensures the Grant and Revoke Lambda roles have the IAM permissions
# they need to actually attach/detach temporary policies on target roles.
#
# Usage:
#   ./scripts/setup-iam-roles.sh                           # Auto-detect roles
#   ./scripts/setup-iam-roles.sh --target-role-pattern "MyRole-*"  # Custom target
#   ./scripts/setup-iam-roles.sh --dry-run                 # Preview only
#
# Why this is needed:
#   The Grant Lambda needs iam:PutRolePolicy to attach temporary permissions.
#   The Revoke Lambda needs iam:DeleteRolePolicy to clean them up.
#   Without these, PVM deploys but silently fails on the grant step.

REGION="${AWS_DEFAULT_REGION:-us-west-2}"
DRY_RUN=false
TARGET_ROLE_PATTERN=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --region) REGION="$2"; shift 2 ;;
    --target-role-pattern) TARGET_ROLE_PATTERN="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help) 
      echo "Usage: $0 [--region us-west-2] [--target-role-pattern 'MyRole-*'] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "🔐 PVM IAM Role Setup"
echo "====================="
echo "Region: $REGION"
echo ""

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
if [ -z "$ACCOUNT_ID" ]; then
  echo "❌ Could not determine AWS account ID. Check your AWS credentials."
  exit 1
fi
echo "Account: $ACCOUNT_ID"

# Find Grant Lambda role
echo ""
echo "[1/4] Finding Grant Lambda role..."
GRANT_ROLE=$(aws iam list-roles \
  --query "Roles[?contains(RoleName, 'GrantPermissions')].RoleName" \
  --output text --region "$REGION" 2>/dev/null)

if [ -z "$GRANT_ROLE" ]; then
  echo "❌ No role containing 'GrantPermissions' found."
  echo "   Deploy Lambda functions first: ./scripts/deploy-lambdas.sh"
  exit 1
fi
echo "  Found: $GRANT_ROLE"

# Find Revoke Lambda role
echo ""
echo "[2/4] Finding Revoke Lambda role..."
REVOKE_ROLE=$(aws iam list-roles \
  --query "Roles[?contains(RoleName, 'RevokePermissions')].RoleName" \
  --output text --region "$REGION" 2>/dev/null)

if [ -z "$REVOKE_ROLE" ]; then
  echo "❌ No role containing 'RevokePermissions' found."
  echo "   Deploy Lambda functions first: ./scripts/deploy-lambdas.sh"
  exit 1
fi
echo "  Found: $REVOKE_ROLE"

# Determine target role ARN pattern
if [ -z "$TARGET_ROLE_PATTERN" ]; then
  echo ""
  echo "[3/4] No --target-role-pattern specified."
  echo "  Using default: arn:aws:iam::${ACCOUNT_ID}:role/*"
  echo "  (Allows granting to any role in this account)"
  echo ""
  echo "  For tighter security, re-run with:"
  echo "    $0 --target-role-pattern 'openclaw-*'"
  echo ""
  TARGET_ARN="arn:aws:iam::${ACCOUNT_ID}:role/*"
else
  TARGET_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${TARGET_ROLE_PATTERN}"
  echo ""
  echo "[3/4] Target role pattern: $TARGET_ARN"
fi

# Build the policy document
POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PVMGrantRevokePermissions",
      "Effect": "Allow",
      "Action": [
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:GetRole"
      ],
      "Resource": "${TARGET_ARN}"
    }
  ]
}
EOF
)

POLICY_NAME="pvm-grant-revoke-permissions"

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "[4/4] DRY RUN — would apply this policy to both roles:"
  echo ""
  echo "$POLICY_DOC"
  echo ""
  echo "Roles:"
  echo "  - $GRANT_ROLE"
  echo "  - $REVOKE_ROLE"
  echo ""
  echo "Re-run without --dry-run to apply."
  exit 0
fi

# Apply to Grant role
echo ""
echo "[4/4] Applying IAM policy..."
echo "  Attaching to $GRANT_ROLE..."
aws iam put-role-policy \
  --role-name "$GRANT_ROLE" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$POLICY_DOC" \
  --region "$REGION"
echo "  ✅ Grant role updated"

# Apply to Revoke role
echo "  Attaching to $REVOKE_ROLE..."
aws iam put-role-policy \
  --role-name "$REVOKE_ROLE" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$POLICY_DOC" \
  --region "$REGION"
echo "  ✅ Revoke role updated"

echo ""
echo "🎉 IAM setup complete!"
echo ""
echo "Both Lambda roles can now attach/detach inline policies on: $TARGET_ARN"
echo ""
echo "Verify with:"
echo "  aws iam get-role-policy --role-name $GRANT_ROLE --policy-name $POLICY_NAME"
echo "  aws iam get-role-policy --role-name $REVOKE_ROLE --policy-name $POLICY_NAME"
