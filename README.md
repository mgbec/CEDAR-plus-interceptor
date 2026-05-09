# Multi-Tenant Database Agent

A demonstration of combining **Cedar Policies** (declarative access control) with **Gateway Interceptors** (stateful rate limiting) in AgentCore Gateway.

## Architecture

```
Agent Request
     │
     ▼
┌─────────────────────────────────────────────────┐
│  AgentCore Gateway (DataPlatformGateway)         │
│                                                  │
│  1. JWT Authorizer ─── validates token           │
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

## Setup

### Prerequisites

- AWS account with AgentCore access
- `agentcore` CLI installed (`npm install -g @aws/agentcore-cli`)
- Terraform >= 1.5
- `jq` and `openssl` (for the test scripts)

### Step 1: Deploy Infrastructure with Terraform

```bash
cd terraform

# Create your variables file
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars (defaults work fine for testing)

terraform init
terraform plan
terraform apply
```

This deploys:
- **Cognito User Pool** with three groups (admins, engineering, marketing)
- **Three test users** (admin@example.com, engineer@example.com, marketing@example.com)
- **DynamoDB table** for rate limit counters (with TTL auto-cleanup)
- **Rate limiter Lambda** + IAM role (with DynamoDB access)
- **DB tools Lambda** + IAM role
- **Gateway service role** (trusted by `bedrock-agentcore.amazonaws.com`)
- Lambda invoke permissions for the gateway

### Step 2: Update agentcore.json with Terraform Outputs

After `terraform apply`, grab the output values:

```bash
terraform output -json
```

Update `agentcore.json`:
- Replace `REPLACE_WITH_COGNITO_DISCOVERY_URL` with the `cognito_discovery_url` output
- Replace `REPLACE_WITH_COGNITO_APP_CLIENT_ID` with the `cognito_app_client_id` output
- Replace the rate limiter Lambda ARN in `interceptorConfigurations`
- Replace the db-tools Lambda ARN in `targets[].lambdaArn`
- Replace `YOUR_ACCOUNT_ID` in any remaining ARNs

### Step 3: Deploy the Gateway

```bash
cd ..
agentcore deploy -y
```

### Step 4: Get Test Tokens

```bash
# Get a token for the engineer user
./scripts/get-token.sh engineer@example.com

# Get a token for the admin user
./scripts/get-token.sh admin@example.com

# Get a token for the marketing user
./scripts/get-token.sh marketing@example.com
```

The script handles the first-login password challenge automatically.
Tokens include the `cognito:groups` claim that Cedar policies evaluate.

### Step 5: Test

```bash
# Run the full test suite
./scripts/test-scenarios.sh https://your-gateway-url/mcp

# Or test manually with curl:
TOKEN=$(./scripts/get-token.sh engineer@example.com)

# Engineer calling run_query — should succeed
curl -X POST https://your-gateway-url/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"method": "tools/call", "params": {"name": "DatabaseTools___run_query", "arguments": {"sql": "SELECT * FROM users LIMIT 10", "database": "analytics"}}}'

# Engineer calling delete_records — should be DENIED by Cedar (403)
curl -X POST https://your-gateway-url/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"method": "tools/call", "params": {"name": "DatabaseTools___delete_records", "arguments": {"table": "users", "condition": "id > 100", "database": "analytics"}}}'
```

## Testing Tips

- **Start with `policyEngineConfiguration.mode: "LOG_ONLY"`** to see what Cedar would deny without actually blocking. Check CloudWatch logs, then switch to `ENFORCE`.
- **Set `exceptionLevel: "DEBUG"`** during development to get detailed error messages from the gateway.
- **Use the MCP Inspector** (https://modelcontextprotocol.io/) pointed at your gateway URL for interactive tool testing.
- **Check DynamoDB** to see rate limit counters accumulating in real time.

## Key Takeaways

| Concern | Mechanism | Why |
|---------|-----------|-----|
| Who can call what | Cedar Policy | Declarative, auditable, no code needed |
| How much they can call | Interceptor Lambda | Requires external state (DynamoDB) |
| Data transformation | Interceptor Lambda | Cedar can't modify payloads |
| Compliance audit trail | Cedar + CloudTrail | Policy decisions are logged |
