# Common Allowlist Templates

Pre-built allowlist templates for common AWS use cases. Import these into your PVM allowlist instead of manually adding actions one by one.

## Available Templates

| Template | File | Actions | Description |
|----------|------|---------|-------------|
| **Static Website** | `static-website.json` | 23 | S3 website hosting + CloudFront CDN |
| **CI/CD** | `ci-cd.json` | 20 | ECR, Lambda deploy, CodeBuild |
| **Monitoring** | `monitoring.json` | 24 | CloudWatch, SNS, SQS |
| **Email & Messaging** | `email-messaging.json` | 13 | SES, SNS |

## Usage

### List available templates

```bash
node scripts/import-allowlist.js --list
```

### Preview what would be added (dry run)

```bash
node scripts/import-allowlist.js docs/common-allowlists/static-website.json --dry-run
```

### Import a template

```bash
node scripts/import-allowlist.js docs/common-allowlists/static-website.json
```

### Import multiple templates

```bash
node scripts/import-allowlist.js docs/common-allowlists/static-website.json
node scripts/import-allowlist.js docs/common-allowlists/monitoring.json
```

Templates merge additively — existing actions are preserved, only new ones are added. You can safely run the same template twice.

## Creating Custom Templates

Create a JSON file in this directory with the following structure:

```json
{
  "description": "What this template is for",
  "allowedActions": [
    "service:ActionName",
    "service:AnotherAction"
  ]
}
```

Then import it:

```bash
node scripts/import-allowlist.js docs/common-allowlists/my-template.json
```

## Security Notes

- Templates only add to the **allowlist** — they don't bypass the **denylist** (`iam:*`, `organizations:*`, etc.)
- Every action still requires human approval via the PVM workflow
- Review template contents before importing — you're authorizing agents to *request* these actions
- Use `--dry-run` to preview changes before applying
