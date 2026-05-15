# Multi-Tenant Database Agent

A demonstration of combining **Cedar Policies** (declarative access control) with **Gateway Interceptors** (stateful rate limiting) in AgentCore Gateway — deployed entirely with Terraform.

## Architecture

```
Agent Request
     │
     ▼
┌─────────────────────────────────────────────────┐
│  AgentCore Gateway (DataPlatformGateway)         │
│                                                  │
│  1. JWT Authorizer ─── validates Cognito token   │
│  2. Cedar Policy ───── checks role permissions   │
│  3. Rate Limiter ───── checks usage quota        │
│  4. Tool Dispatch ──── routes to Lambda backend  │
│                                                  │
└─────────────────────────────────────────────────┘
     │
     ▼
┌──────────────┐     ┌──────────────────┐
│  db-tools    │     │  DynamoDB        │
│  Lambda      │     │  (rate counters) │
└──────────────┘     └──────────────────┘
```

## Access Control Matrix

| Role        | list_tables | describe_table | run_query | delete_records | Rate Limit |
|-------------|:-----------:|:--------------:|:---------:|:--------------:|:----------:|
| admins      | ✅          | ✅             | ✅        | ✅             | 100/hr     |
| engineering | ✅          | ✅             | ✅        | ❌ (forbid)    | 50/hr      |
| marketing   | ✅          | ✅             | ❌        | ❌             | 20/hr      |

## How the Two Layers Work Together

1. **Cedar Policy (Layer 1 — Authorization)**
   - Evaluated first by the gateway's policy engine
   - Answers: "Is this principal allowed to invoke this tool?"
   - Static, declarative, auditable rules
   - Default-deny: if no `permit` matches, the request is blocked
   - `forbid` always wins over `permit` (engineers can never delete)

2. **Rate Limiter Interceptor (Layer 2 — Quota Enforcement)**
   - Runs only for requests that passed Cedar authorization
   - Answers: "Has this user exceeded their hourly budget?"
   - Stateful: reads/writes counters in DynamoDB
   - Fails open: if DynamoDB is unreachable, requests pass through

## Project Structure

```
multi-tenant-db-agent/
├── terraform/
│   ├── main.tf              # Lambdas, DynamoDB, IAM roles
│   ├── cognito.tf           # User Pool, groups, test users
│   ├── agentcore.tf         # Gateway, Policy Engine, Cedar policies, target
│   ├── variables.tf         # Inputs
│   ├── outputs.tf           # Gateway URL, Cognito endpoints, ARNs
│   ├── terraform.tfvars.example
│   └── .gitignore
├── lambdas/
│   ├── db-tools/
│   │   └── index.py         # Mock database tool backend
│   └── rate-limiter/
│       └── index.py         # Request interceptor (quota enforcement)
├── policies/
│   └── access-control.cedar # Cedar rules (reference copy)
├── scripts/
│   ├── get-token.sh         # Authenticate a test user, get JWT
│   └── test-scenarios.sh    # Full integration test suite
└── README.md
```

## Setup

### Prerequisites

- AWS account with AgentCore access
- Terraform >= 1.5
- AWS provider >= 5.90.0 (for `aws_bedrockagentcore_*` resources)
- `jq` and `openssl` (for the test scripts)

### Deploy Everything

The deployment is a two-step process because the Terraform AWS provider
doesn't support Policy Engine/Policy resources yet:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars

# Step 1: Create the Policy Engine (via AWS API)
../scripts/create-policies.sh
# This writes policy_engine_arn to policy-arns.auto.tfvars

# Step 2: Deploy all infrastructure (reads the auto.tfvars automatically)
terraform init
terraform apply

# Step 3: Create tool-specific Cedar policies (needs the gateway ARN)
../scripts/create-policies.sh
# Re-running after gateway exists creates the tool-scoped policies
```

The script is idempotent — safe to run multiple times.

This single command deploys:
- **Cognito User Pool** with three groups (admins, engineering, marketing)
- **Three test users** (admin@example.com, engineer@example.com, marketing@example.com)
- **DynamoDB table** for rate limit counters (with TTL auto-cleanup)
- **Rate limiter Lambda** + IAM role (with DynamoDB access)
- **DB tools Lambda** + IAM role
- **Gateway service role** (trusted by `bedrock-agentcore.amazonaws.com`)
- **AgentCore Policy Engine** with 7 Cedar policies
- **AgentCore Gateway** (JWT auth, semantic search, interceptor)
- **AgentCore Gateway Target** (Lambda with inline tool schema)

### Get Test Tokens

```bash
# Get a token for each role
./scripts/get-token.sh admin@example.com
./scripts/get-token.sh engineer@example.com
./scripts/get-token.sh marketing@example.com
```

The script handles the first-login password challenge automatically.
Tokens include the `cognito:groups` claim that Cedar policies evaluate.

### Test

```bash
# Get the gateway URL from terraform output
GATEWAY_URL=$(terraform -chdir=terraform output -raw gateway_url)

# Run the full test suite
./scripts/test-scenarios.sh "$GATEWAY_URL"

# Or test manually:
TOKEN=$(./scripts/get-token.sh engineer@example.com)

# Engineer calling run_query — should succeed
curl -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"method": "tools/call", "params": {"name": "DatabaseTools___run_query", "arguments": {"sql": "SELECT * FROM users LIMIT 10", "database": "analytics"}}}'

# Engineer calling delete_records — should be DENIED by Cedar (403)
curl -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"method": "tools/call", "params": {"name": "DatabaseTools___delete_records", "arguments": {"table": "users", "condition": "id > 100", "database": "analytics"}}}'
```

### Tear Down

```bash
cd terraform
terraform destroy
```

## Testing Tips

- The gateway starts in `CREATING` status after deploy. Wait for it to reach `READY` before testing (usually 1-2 minutes).
- Check DynamoDB to see rate limit counters accumulating in real time.
- Use the [MCP Inspector](https://modelcontextprotocol.io/) pointed at your gateway URL for interactive tool testing.

## Key Takeaways

| Concern | Mechanism | Why |
|---------|-----------|-----|
| Who can call what | Cedar Policy | Declarative, auditable, no code needed |
| How much they can call | Interceptor Lambda | Requires external state (DynamoDB) |
| Data transformation | Interceptor Lambda | Cedar can't modify payloads |
| Compliance audit trail | Cedar + CloudTrail | Policy decisions are logged |
