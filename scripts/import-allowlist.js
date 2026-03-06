#!/usr/bin/env node
/**
 * Import a common allowlist template into the PVM DynamoDB allowlist.
 * 
 * Usage:
 *   node scripts/import-allowlist.js docs/common-allowlists/static-website.json
 *   node scripts/import-allowlist.js docs/common-allowlists/static-website.json --dry-run
 *   node scripts/import-allowlist.js docs/common-allowlists/static-website.json --region us-east-1
 *   node scripts/import-allowlist.js --list   # Show available templates
 * 
 * This merges new actions into the existing allowlist (does not remove existing actions).
 */

const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, GetCommand, PutCommand } = require('@aws-sdk/lib-dynamodb');
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const regionIdx = args.indexOf('--region');
const region = regionIdx >= 0 ? args[regionIdx + 1] : 'us-west-2';
const dryRun = args.includes('--dry-run');
const listMode = args.includes('--list');

const TABLE_NAME = 'pvm-allowlist';

async function listTemplates() {
  const dir = path.join(__dirname, '..', 'docs', 'common-allowlists');
  if (!fs.existsSync(dir)) {
    console.log('No templates found. Expected directory: docs/common-allowlists/');
    return;
  }

  const files = fs.readdirSync(dir).filter(f => f.endsWith('.json'));
  console.log('Available allowlist templates:\n');
  
  for (const file of files) {
    const template = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
    const name = file.replace('.json', '');
    console.log(`  📋 ${name}`);
    console.log(`     ${template.description}`);
    console.log(`     ${template.allowedActions.length} actions`);
    console.log(`     Import: node scripts/import-allowlist.js docs/common-allowlists/${file}`);
    console.log('');
  }
}

async function importTemplate(filePath) {
  if (!fs.existsSync(filePath)) {
    console.error(`File not found: ${filePath}`);
    process.exit(1);
  }

  const template = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  const templateName = path.basename(filePath, '.json');

  console.log(`📋 Template: ${templateName}`);
  console.log(`   ${template.description}`);
  console.log(`   ${template.allowedActions.length} actions to add`);
  console.log('');

  const client = new DynamoDBClient({ region });
  const docClient = DynamoDBDocumentClient.from(client);

  // Fetch current allowlist
  const current = await docClient.send(new GetCommand({
    TableName: TABLE_NAME,
    Key: { id: 'current' }
  }));

  if (!current.Item) {
    console.error('No allowlist found in DynamoDB. Run setup first.');
    process.exit(1);
  }

  const existingActions = new Set(current.Item.allowedActions || []);
  const newActions = template.allowedActions.filter(a => !existingActions.has(a));

  if (newActions.length === 0) {
    console.log('✅ All actions already in allowlist. Nothing to do.');
    return;
  }

  console.log(`Adding ${newActions.length} new actions:`);
  for (const action of newActions) {
    console.log(`  + ${action}`);
  }
  console.log('');

  if (dryRun) {
    console.log('🔍 DRY RUN — no changes made.');
    return;
  }

  // Merge and update
  const mergedActions = [...existingActions, ...newActions];
  const updatedItem = {
    ...current.Item,
    allowedActions: mergedActions,
    version: (current.Item.version || 0) + 1,
    updatedAt: new Date().toISOString(),
    updatedBy: `import-allowlist:${templateName}`
  };

  await docClient.send(new PutCommand({
    TableName: TABLE_NAME,
    Item: updatedItem
  }));

  console.log(`✅ Allowlist updated. Now has ${mergedActions.length} allowed actions (was ${existingActions.size}).`);
}

async function main() {
  if (listMode) {
    await listTemplates();
    return;
  }

  const filePath = args.find(a => !a.startsWith('--') && a !== region);
  if (!filePath) {
    console.log('Usage: node scripts/import-allowlist.js <template.json> [--dry-run] [--region us-west-2]');
    console.log('       node scripts/import-allowlist.js --list');
    process.exit(1);
  }

  await importTemplate(filePath);
}

main().catch(err => {
  console.error('Error:', err.message);
  process.exit(1);
});
