# Workflows Documentation

## Set "Opened On" in Project

**File:** `set-opened-on.yaml`

### Purpose

Automatically sets the "Opened On" date field for issues when they are added to a GitHub Project board. The date is set to the issue's original creation date, providing accurate tracking of when issues were first opened.

### Trigger

- **Event:** `projects_v2_item` with type `created`
- **When:** Runs when any item (issue, PR, draft) is added to a project
- **Filter:** Only processes items where `content_type == 'Issue'` (skips PRs and other types)
- **Manual:** Supports `workflow_dispatch` for manual testing

### How It Works

1. **Trigger:** Workflow activates when an issue is added to the project
2. **Extract Issue Date:** Queries GitHub GraphQL API to fetch the issue's `createdAt` timestamp and number from the `content_node_id`
3. **Set Date Field:** Updates the project item's "Opened On" field with the extracted date

### Configuration

The workflow uses the following hardcoded values:

- **Project ID:** `PVT_kwDOA9MHEM4AgKVv`
- **Field ID:** `PVTF_lADOA9MHEM4AgKVvzg4bxWU` (the "Opened On" date field)

### Required Secrets

#### `DATE_AUTOMATION`

A GitHub Personal Access Token (PAT) with the following permissions:

**For Fine-Grained Personal Access Tokens:**

| Permission | Access Level | Reason |
|------------|-------------|---------|
| **Organization permissions:** | | |
| `organization_projects` | Read and write | Required to query project items and update project field values |
| **Repository permissions:** | | |
| `metadata` | Read | Required for basic GraphQL API access |

**For Classic Personal Access Tokens:**

- `project` scope (or `write:project`) - Required to update project fields
- `read:org` scope - Required to access organization projects

**Token Configuration Notes:**
- The token must have access to the organization where the project is hosted
- For fine-grained tokens, grant access to all repositories in the organization or specific repositories as needed
- The token must be stored as a secret named `DATE_AUTOMATION` in the repository or organization settings

### Permissions

The workflow declares the following GitHub Actions permissions:

```yaml
permissions:
  contents: read
  repository-projects: write
  organization-projects: write
```

### Error Handling

The workflow includes comprehensive error handling:

- **Token validation:** Checks if `DATE_AUTOMATION` secret is set
- **GraphQL response validation:** Verifies the API response contains valid issue data
- **Null checks:** Ensures extracted values (createdAt, issue number) are not null
- **Rate limit detection:** Detects and reports API rate limit errors with reset time
- **Permission errors:** Identifies and reports token scope/permission issues

### Example Output

**Success:**
```
Successfully set 'Opened On' to 2024-01-15 for issue #123
```

**Error (missing token):**
```
Error: GH_TOKEN (DATE_AUTOMATION secret) is not set
```

**Error (rate limit):**
```
Error while setting field value: GitHub API rate limit exceeded for DATE_AUTOMATION token
Rate limit resource: graphql
Remaining: 0
Resets at: Thu Jan 09 21:30:00 UTC 2026
```

### Maintenance

To update the project or field IDs:

1. Get your project's node ID:
   ```bash
   gh api graphql -f query='query($org:String!, $number:Int!){
     organization(login:$org){
       projectV2(number:$number){ id }
     }
   }' -F org=YOUR_ORG -F number=PROJECT_NUMBER
   ```

2. Get the field ID:
   ```bash
   gh api graphql -f query='query($org:String!, $number:Int!){
     organization(login:$org){
       projectV2(number:$number){
         fields(first:20){
           nodes{
             ... on ProjectV2Field { id name }
           }
         }
       }
     }
   }' -F org=YOUR_ORG -F number=PROJECT_NUMBER
   ```

3. Update `PROJECT_ID` and `FIELD_ID` environment variables in the workflow file

### Troubleshooting

**Workflow doesn't trigger:**
- Ensure the workflow file is in the organization's `.github` repository
- Verify the `projects_v2_item` event is enabled for organization workflows
- Check that issues are being added to the correct project

**Permission errors:**
- Verify the `DATE_AUTOMATION` token has the required scopes
- Ensure the token hasn't expired
- Check that the token has access to the organization and project

**Field not updating:**
- Confirm `PROJECT_ID` matches your project's node ID
- Verify `FIELD_ID` matches the "Opened On" field in your project
- Check the field type is "Date" in the project settings
