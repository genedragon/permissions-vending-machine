# PVM Documentation Updates - Implementation Guide
## Date: 2026-03-09 | Status: Ready for GitHub

---

## Overview

This directory contains **sanitized, GitHub-ready documentation updates** for the Permissions Vending Machine (PVM) project. All updates address critical gaps discovered during the 2026-03-08 deployment session.

**Files in this directory:**
1. `README-additions.md` — Sections to add to main README.md
2. `SKILL-MD-troubleshooting.md` — Enhanced troubleshooting for pvm-use skill
3. `PVM_IMPROVEMENTS_PROPOSAL.md` — Full analysis + future simplification opportunities
4. `IMPLEMENTATION-CHECKLIST.md` — This file (step-by-step guide)

---

## Critical Issues Addressed

### Issue 1: Missing Action Allowlist Table Documentation
**Impact:** New deployments often fail with "Action not in allowlist" errors  
**Root Cause:** `pvm-allowlist` (singular) table not documented; users don't know to create it  
**Fix:** README-additions.md Section 1 (Allowlist Architecture)

### Issue 2: Singular vs Plural Table Name Confusion
**Impact:** Lambda env vars point to wrong tables, causing silent failures  
**Root Cause:** Two similar table names with different purposes, never explained  
**Fix:** README-additions.md Section 2 (Lambda Environment Variables Reference)

### Issue 3: No Troubleshooting for Allowlist Errors
**Impact:** Users stuck when requests fail, no clear fix documented  
**Root Cause:** SKILL.md troubleshooting table incomplete  
**Fix:** SKILL-MD-troubleshooting.md (complete rewrite with step-by-step debugging)

---

## Implementation Steps

### Phase 1: Documentation Updates (Immediate)

**Estimated Time:** 2 hours  
**Risk:** Low (documentation only, no code changes)

#### Step 1: Update Main README.md

**File:** `permissions-vending-machine/README.md`

**Changes:**
1. Add "Allowlist Architecture" section after existing "Architecture" section (~line 30)
2. Add "Lambda Environment Variables Reference" in "Configuration" section (~line 200)

**Source:** Use content from `README-additions.md`

**Verification:**
```bash
# Check markdown rendering
npx markdown-link-check README.md

# Verify no sensitive data leaked
grep -r "652253416617" README.md  # Should return nothing
grep -r "acp-bucket" README.md     # Should return nothing
grep -r "gene.alpert" README.md    # Should return nothing
```

#### Step 2: Update SKILL.md

**File:** `permissions-vending-machine/pvm-use/SKILL.md` (or skill repo)

**Changes:**
1. Replace existing "Troubleshooting" section with enhanced version
2. Add new sections: "Debugging Action Allowlist", "Advanced Troubleshooting"

**Source:** Use content from `SKILL-MD-troubleshooting.md`

**Verification:**
```bash
# Check links
npx markdown-link-check pvm-use/SKILL.md

# Verify examples use placeholders
grep -E "us-west-2|us-east-2" pvm-use/SKILL.md | grep -v "YOUR-REGION"  # Should be empty
```

#### Step 3: Create Deployment Verification Script

**File:** `permissions-vending-machine/scripts/verify-deployment.js` (NEW)

**Purpose:** Automated checks that both tables exist and are configured correctly

**Content:**
```javascript
#!/usr/bin/env node
/**
 * Verify PVM deployment prerequisites
 * Usage: node scripts/verify-deployment.js [--region us-west-2]
 */

const AWS = require('aws-sdk');
const region = process.argv.includes('--region')
  ? process.argv[process.argv.indexOf('--region') + 1]
  : process.env.AWS_REGION || 'us-west-2';

const dynamodb = new AWS.DynamoDB({region});
const ssm = new AWS.SSM({region});
const lambda = new AWS.Lambda({region});

async function verify() {
  console.log(`Verifying PVM deployment in ${region}...\\n`);

  let errors = 0;

  // Check pvm-requests table
  try {
    await dynamodb.describeTable({TableName: 'pvm-requests'}).promise();
    console.log('✅ pvm-requests table exists');
  } catch (err) {
    console.log('❌ pvm-requests table MISSING');
    errors++;
  }

  // Check pvm-allowlist (singular)
  try {
    await dynamodb.describeTable({TableName: 'pvm-allowlist'}).promise();
    console.log('✅ pvm-allowlist (singular) table exists');
    
    // Check if it has the "current" item
    const result = await dynamodb.getItem({
      TableName: 'pvm-allowlist',
      Key: {id: {S: 'current'}}
    }).promise();
    
    if (result.Item) {
      const actions = result.Item.allowedActions.L.map(a => a.S);
      console.log(`   Allowed actions: ${actions.length} configured`);
    } else {
      console.log('⚠️  pvm-allowlist table exists but missing "current" item');
      errors++;
    }
  } catch (err) {
    console.log('❌ pvm-allowlist (singular) table MISSING');
    console.log('   This will cause "Action not in allowlist" errors!');
    errors++;
  }

  // Check pvm-allowlists (plural)
  try {
    await dynamodb.describeTable({TableName: 'pvm-allowlists'}).promise();
    console.log('✅ pvm-allowlists (plural) table exists');
    
    // Count entries
    const scan = await dynamodb.scan({TableName: 'pvm-allowlists', Select: 'COUNT'}).promise();
    console.log(`   Resources allowlisted: ${scan.Count}`);
  } catch (err) {
    console.log('❌ pvm-allowlists (plural) table MISSING');
    errors++;
  }

  // Check SSM parameters
  try {
    await ssm.getParameter({Name: '/pvm/approver-email'}).promise();
    console.log('✅ /pvm/approver-email parameter exists');
  } catch (err) {
    console.log('❌ /pvm/approver-email parameter MISSING');
    errors++;
  }

  try {
    await ssm.getParameter({Name: '/pvm/jwt-secret', WithDecryption: true}).promise();
    console.log('✅ /pvm/jwt-secret parameter exists');
  } catch (err) {
    console.log('❌ /pvm/jwt-secret parameter MISSING');
    errors++;
  }

  // Check Lambda function
  try {
    const config = await lambda.getFunctionConfiguration({FunctionName: 'pvm-api'}).promise();
    console.log('✅ pvm-api Lambda function exists');
    
    // Check env vars
    const env = config.Environment.Variables;
    const requiredVars = ['DYNAMODB_REQUESTS_TABLE', 'DYNAMODB_ALLOWLIST_TABLE', 'DYNAMODB_ALLOWLISTS_TABLE'];
    requiredVars.forEach(v => {
      if (env[v]) {
        console.log(`   ${v}: ${env[v]}`);
      } else {
        console.log(`⚠️  ${v} not set!`);
        errors++;
      }
    });
  } catch (err) {
    console.log('❌ pvm-api Lambda function MISSING or inaccessible');
    errors++;
  }

  console.log(`\\n${errors === 0 ? '✅ All checks passed!' : `❌ ${errors} error(s) found`}`);
  process.exit(errors > 0 ? 1 : 0);
}

verify().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
```

**Add to package.json:**
```json
{
  "scripts": {
    "verify": "node scripts/verify-deployment.js"
  }
}
```

**Usage:**
```bash
npm run verify
# or
node scripts/verify-deployment.js --region us-west-2
```

#### Step 4: Update Deployment Scripts

**File:** `permissions-vending-machine/scripts/create-tables.js`

**Add verification at the end:**
```javascript
// At end of create-tables.js
console.log('\\n✅ Tables created successfully!\\n');
console.log('⚠️  IMPORTANT: The pvm-allowlist table needs an initial item.');
console.log('Run this command to add it:\\n');
console.log('aws dynamodb put-item --table-name pvm-allowlist --region YOUR-REGION --item \\'{');
console.log('  "id": {"S": "current"},');
console.log('  "allowedActions": {"L": [');
console.log('    {"S": "s3:GetObject"},');
console.log('    {"S": "s3:ListBucket"}');
console.log('  ]},');
console.log('  "deniedActions": {"L": [{"S": "iam:*"}, {"S": "*:*"}]},');
console.log('  "version": {"N": "1"}');
console.log('}\\' --region YOUR-REGION\\n');
```

#### Step 5: Commit and Push

```bash
cd /path/to/permissions-vending-machine

# Stage changes
git add README.md
git add pvm-use/SKILL.md  # or skill repo
git add scripts/verify-deployment.js
git add scripts/create-tables.js

# Commit with clear message
git commit -m "docs: add allowlist architecture documentation

- Add detailed explanation of two-table architecture (pvm-allowlist vs pvm-allowlists)
- Add Lambda environment variable reference
- Enhance troubleshooting section with step-by-step debugging
- Add deployment verification script
- Fix: addresses 'Action not in allowlist' deployment issue

Closes #<issue-number>"

# Push to remote
git push origin main  # or your branch
```

---

### Phase 2: Validation (Same Day)

**Estimated Time:** 1 hour

#### Test 1: Fresh Deployment

**Spin up new AWS environment and follow updated README:**
1. Create tables using `scripts/create-tables.js`
2. Run `npm run verify` → should catch missing allowlist item
3. Add initial allowlist item as documented
4. Run `npm run verify` again → should pass
5. Deploy Lambda functions
6. Test PVM request → should work

**Success Criteria:** Fresh deployment works without consulting external resources

#### Test 2: Intentional Misconfiguration

**Verify troubleshooting guide works:**
1. Delete `pvm-allowlist` table
2. Submit PVM request → should fail with "Action not in allowlist"
3. Follow troubleshooting guide → should lead to table recreation
4. Retry request → should work

**Success Criteria:** Troubleshooting guide identifies issue and provides fix

#### Test 3: Documentation Review

**Ask non-expert to review docs:**
- Can they understand the two-table architecture?
- Can they identify which table is singular vs plural?
- Can they set Lambda env vars correctly?

**Success Criteria:** No confusion about table names or architecture

---

### Phase 3: Future Simplifications (Optional)

**See:** `PVM_IMPROVEMENTS_PROPOSAL.md` Part 2

**Phase 3a: Table Consolidation** (2-4 hours)
- Merge two allowlist tables into one with better schema
- Provide migration script for existing deployments
- Update all Lambda code to use new schema

**Phase 3b: Environment Variable Reduction** (3-5 hours)
- Move config to SSM instead of env vars
- Reduce from 6+ vars to 3 (prefix, region, SSM path)
- Add caching layer for SSM reads

**Status:** Not started (requires code changes + migration guide)

---

## Sanitization Verification

Before committing, run these checks:

```bash
# Check for AWS account IDs
grep -r "652253416617" .  # Should be empty or only in .git/

# Check for real bucket names
grep -r "acp-bucket" .     # Should be empty

# Check for real email addresses
grep -r "@gmail.com" .     # Should be empty or only example.com

# Check for real region-specific values (should use placeholders)
grep -r "us-west-2" . | grep -v "YOUR-REGION"  # Should be minimal

# Check for API Gateway IDs
grep -r "[a-z0-9]{10}\\.execute-api" .  # Should use YOUR-API-ID
```

**All checks should return no results or only acceptable placeholders.**

---

## Success Metrics

After implementation:

- ✅ Zero "action not in allowlist" errors from new deployments
- ✅ Clear documentation answers "Why are there two tables?"
- ✅ Troubleshooting guide resolves issues without external support
- ✅ Verification script catches configuration errors before runtime
- ✅ Deployment time reduced (clearer instructions)

---

## Rollback Plan

If documentation updates cause confusion:

1. **Immediate:** Add "See old documentation" link to archived version
2. **Short-term:** Gather feedback via GitHub issues
3. **Revise:** Update docs based on user feedback
4. **Long-term:** Consider Phase 3 simplifications

---

## Contact

**Questions?** Open an issue in the PVM repository or contact maintainers.

**Found an error?** Submit a PR with corrections.

---

## Files Modified Summary

```
✏️  README.md                           (2 new sections added)
✏️  pvm-use/SKILL.md                    (troubleshooting rewritten)
✨  scripts/verify-deployment.js        (NEW - automated checks)
✏️  scripts/create-tables.js            (added user prompt for allowlist item)
✏️  package.json                        (added verify script)
```

**Total Lines Changed:** ~500 (mostly additions)  
**Breaking Changes:** None (documentation only)  
**Migration Required:** No

---

**Status:** 🟢 Ready for Implementation  
**Review Required:** Yes (peer review recommended before merge)  
**Testing Required:** Yes (see Phase 2)

---

End of implementation guide. Good luck! 🚀
