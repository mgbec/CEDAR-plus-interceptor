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
│   ├── agentcore.tf         # Gateway + Gateway Target
│   ├── variables.tf         # Inputs (including policy engine ARN)
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
│   ├── create-policies.sh   # Creates Policy Engine + Cedar policies via API
│   ├── create_policies.py   # Python implementation (boto3)
│   ├── get-token.sh         # Authenticate a test user, get JWT
│   └── test-scenarios.sh    # Full integration test suite
└── README.md
```

## Setup

### Prerequisites

- AWS account with AgentCore access
- Terraform >= 1.5 with AWS provider >= 5.90.0
- Python 3 with boto3 >= 1.35.0 (`pip install boto3`)
- `jq` and `openssl` (for the test scripts)
- AWS credentials configured (`aws configure` or environment variables)

### Why a Two-Tool Deployment?

The Terraform AWS provider supports `aws_bedrockagentcore_gateway` and
`aws_bedrockagentcore_gateway_target`, but does **not** yet support:
- Policy Engine or Policy resources
- `policy_engine_configuration` on the gateway
- `interceptor_configuration` (accepted by Terraform but silently not sent to the API)

So we use:
- **Terraform** for infrastructure (Cognito, Lambdas, DynamoDB, IAM, Gateway shell, Target)
- **Python script** (`scripts/create-policies.sh`) for Policy Engine, Cedar Policies, and attaching the policy engine + interceptor to the gateway via `UpdateGateway`

**Important:** Always run the Python script *after* `terraform apply`. The `UpdateGateway` API replaces the entire config, so the script must read the current gateway state and preserve all fields when attaching the policy engine.

### Deployment Steps

There's a dependency cycle between the gateway and the Cedar policies:
- The **gateway** needs the policy engine ARN (to attach it)
- The **tool-specific policies** need the gateway ARN (Cedar requires scoping to a specific gateway)

This is resolved by deploying in three passes:

```bash
# ─── Pass 1: Create the Policy Engine ───────────────────────
./scripts/create-policies.sh

# What happens:
#   - Creates the Policy Engine via boto3
#   - Creates the "AdminFullAccess" policy (no gateway ARN needed yet)
#   - Writes policy_engine_arn to terraform/policy-arns.auto.tfvars
#   - Skips tool-specific policies (no gateway yet)

# ─── Pass 2: Deploy Infrastructure ─────────────────────────
cd terraform
cp terraform.tfvars.example terraform.tfvars   # first time only
terraform init                                  # first time only
terraform apply

# What happens:
#   - Reads policy-arns.auto.tfvars automatically
#   - Deploys Cognito, Lambdas, DynamoDB, IAM
#   - Deploys Gateway + Gateway Target
#   - NOTE: policy engine and interceptor are NOT attached by Terraform
#     (provider bugs — these fields are silently ignored)

# ─── Pass 3: Attach Policy Engine + Interceptor + Create Policies ─
cd ..
./scripts/create-policies.sh

# What happens:
#   - Reads gateway ARN from `terraform output`
#   - Creates 6 tool-specific Cedar policies scoped to that gateway
#   - Attaches the policy engine to the gateway (ENFORCE mode)
#   - Attaches the interceptor Lambda to the gateway
#   - Preserves all existing gateway config during the update
#   - Skips any policies that already exist (idempotent)
```

After all three passes, the system is fully operational.

**If you re-run `terraform apply` later** (e.g., to update a Lambda), run
`./scripts/create-policies.sh` again afterward — Terraform may wipe the
policy engine and interceptor attachments.

### What Gets Deployed

| Resource | Deployed By | Notes |
|----------|-------------|-------|
| Cognito User Pool + groups + users | Terraform | 3 groups, 3 test users |
| DynamoDB table | Terraform | Rate limit counters with TTL |
| Rate limiter Lambda | Terraform | Gateway interceptor |
| DB tools Lambda | Terraform | Mock database backend |
| IAM roles | Terraform | Gateway, Lambda execution |
| AgentCore Gateway | Terraform | JWT auth, semantic search (interceptor/policy attached by script) |
| AgentCore Gateway Target | Terraform | Lambda with tool schema |
| Policy Engine | Python script | Cedar authorization engine |
| Cedar Policies (7) | Python script | Role-based access rules |
| Policy engine attachment | Python script | Attaches policy engine to gateway |
| Interceptor attachment | Python script | Attaches rate limiter to gateway |

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
TOKEN=$(./scripts/get-token.sh engineer@example.com 2>/dev/null)

# Engineer calling run_query — should succeed (returns mock data)
curl -s -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "DatabaseTools___run_query", "arguments": {"sql": "SELECT * FROM users LIMIT 10", "database": "analytics"}}}'

# Engineer calling delete_records — DENIED by Cedar (HTTP 200, JSON-RPC error in body)
curl -s -X POST "$GATEWAY_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "DatabaseTools___delete_records", "arguments": {"table": "users", "condition": "id > 100", "database": "analytics"}}}'
```

**Note:** Cedar denials return HTTP 200 with `"isError": true` and a message
containing "Tool Execution Denied". Rate limit blocks return HTTP 429.

### Tear Down

```bash
cd terraform
terraform destroy
```

## Testing Tips

- The gateway starts in `CREATING` status after deploy. Wait for it to reach `READY` before testing (usually 1-2 minutes).
- Requests require the full JSON-RPC 2.0 envelope: `{"jsonrpc": "2.0", "id": 1, "method": "tools/call", ...}`.
- Use the **access token** (not ID token) — the gateway requires a `scope` claim.
- After first deploying Cognito users, set permanent passwords: `aws cognito-idp admin-set-user-password --user-pool-id <id> --username <email> --password TestPass1 --permanent`.
- Rate limit counters use 1-hour windows. Clear DynamoDB between test runs if needed.
- Check DynamoDB to see rate limit counters accumulating in real time.
- Use the [MCP Inspector](https://modelcontextprotocol.io/) pointed at your gateway URL for interactive tool testing.

## Key Takeaways

| Concern | Mechanism | Why |
|---------|-----------|-----|
| Who can call what | Cedar Policy | Declarative, auditable, no code needed |
| How much they can call | Interceptor Lambda | Requires external state (DynamoDB) |
| Data transformation | Interceptor Lambda | Cedar can't modify payloads |
| Compliance audit trail | Cedar + CloudTrail | Policy decisions are logged |
