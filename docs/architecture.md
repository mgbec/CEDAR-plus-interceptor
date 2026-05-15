# Architecture, Data Flow & IAM Permissions

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS Account                                     │
│                                                                             │
│  ┌──────────────┐         ┌─────────────────────────────────────────────┐  │
│  │   Cognito    │         │        AgentCore Gateway                     │  │
│  │  User Pool   │         │       (DataPlatformGateway)                  │  │
│  │              │         │                                              │  │
│  │ ┌─────────┐ │  JWT    │  ┌───────────┐  ┌────────┐  ┌───────────┐  │  │
│  │ │ admins  │ │────────▶│  │   JWT     │  │ Cedar  │  │Interceptor│  │  │
│  │ │ eng     │ │         │  │Authorizer │─▶│ Policy │─▶│  (Lambda) │  │  │
│  │ │ mktg    │ │         │  └───────────┘  │ Engine │  └─────┬─────┘  │  │
│  │ └─────────┘ │         │                  └────────┘        │        │  │
│  └──────────────┘         │                                    │        │  │
│                           │                           ┌────────▼──────┐ │  │
│                           │                           │ Gateway Target│ │  │
│                           │                           │   (Lambda)    │ │  │
│                           │                           └───────────────┘ │  │
│                           └─────────────────────────────────────────────┘  │
│                                                                             │
│  ┌──────────────┐    ┌──────────────────┐    ┌──────────────────────────┐  │
│  │  Rate Limiter│    │    DynamoDB       │    │      db-tools Lambda     │  │
│  │   Lambda     │───▶│ (rate counters)   │    │    (mock database)       │  │
│  └──────────────┘    └──────────────────┘    └──────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Detailed Request Data Flow

```
┌──────┐
│Client│
└──┬───┘
   │
   │ 1. POST /mcp
   │    Headers: Authorization: Bearer <access_token>
   │    Body: {"jsonrpc":"2.0","id":1,"method":"tools/call",
   │           "params":{"name":"DatabaseTools___run_query",
   │                     "arguments":{"sql":"...","database":"..."}}}
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│                    AgentCore Gateway                           │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ STEP 1: JWT Authorizer                                   │ │
│  │                                                          │ │
│  │ • Fetches OIDC keys from Cognito discovery URL           │ │
│  │ • Validates token signature, expiry, issuer              │ │
│  │ • Checks client_id ∈ allowedClients                      │ │
│  │ • Checks scope ∈ allowedScopes                           │ │
│  │ • Extracts claims (sub, cognito:groups, scope)           │ │
│  │                                                          │ │
│  │ FAIL → 401 "Invalid Bearer token"                        │ │
│  │ FAIL → 403 "insufficient_scope"                          │ │
│  └────────────────────────┬────────────────────────────────┘ │
│                           │                                   │
│                           ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ STEP 2: Cedar Policy Engine (ENFORCE mode)               │ │
│  │                                                          │ │
│  │ Constructs authorization request:                        │ │
│  │   Principal: AgentCore::OAuthUser::"<sub>"               │ │
│  │   Action:    AgentCore::Action::"DatabaseTools___<tool>" │ │
│  │   Resource:  AgentCore::Gateway::"<gateway_arn>"         │ │
│  │   Tags:      cognito:groups = ["engineering"]            │ │
│  │   Context:   {input: {sql: "...", database: "..."}}      │ │
│  │                                                          │ │
│  │ Evaluates all ACTIVE policies:                           │ │
│  │   • If any FORBID matches → DENY                        │ │
│  │   • If at least one PERMIT matches → ALLOW              │ │
│  │   • If no policy matches → DENY (default deny)          │ │
│  │                                                          │ │
│  │ FAIL → "Tool Execution Denied: policy enforcement"       │ │
│  └────────────────────────┬────────────────────────────────┘ │
│                           │                                   │
│                           ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ STEP 3: Request Interceptor (Lambda)                     │ │
│  │                                                          │ │
│  │ Gateway sends to rate-limiter Lambda:                    │ │
│  │ {                                                        │ │
│  │   "interceptorInputVersion": "1.0",                      │ │
│  │   "mcp": {                                               │ │
│  │     "gatewayRequest": {                                  │ │
│  │       "path": "/mcp",                                    │ │
│  │       "httpMethod": "POST",                              │ │
│  │       "headers": { "authorization": "Bearer ..." },      │ │
│  │       "body": { <jsonrpc request> }                      │ │
│  │     }                                                    │ │
│  │   }                                                      │ │
│  │ }                                                        │ │
│  │                                                          │ │
│  │ Lambda returns (pass-through):                           │ │
│  │ {                                                        │ │
│  │   "interceptorOutputVersion": "1.0",                     │ │
│  │   "mcp": {                                               │ │
│  │     "transformedGatewayRequest": {                       │ │
│  │       "body": { <jsonrpc request, unchanged> }           │ │
│  │     }                                                    │ │
│  │   }                                                      │ │
│  │ }                                                        │ │
│  │                                                          │ │
│  │ BLOCK → replaces body with error (rate limit exceeded)   │ │
│  └────────────────────────┬────────────────────────────────┘ │
│                           │                                   │
│                           ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ STEP 4: Tool Dispatch to Lambda Target                   │ │
│  │                                                          │ │
│  │ Gateway invokes db-tools Lambda with ONLY the arguments: │ │
│  │ {"sql": "SELECT * FROM users", "database": "analytics"}  │ │
│  │                                                          │ │
│  │ Lambda returns MCP tool result:                          │ │
│  │ {                                                        │ │
│  │   "content": [{"type": "text", "text": "<json result>"}] │ │
│  │ }                                                        │ │
│  └────────────────────────┬────────────────────────────────┘ │
│                           │                                   │
└───────────────────────────┼──────────────────────────────────┘
                            │
                            ▼
┌──────┐
│Client│  ← {"jsonrpc":"2.0","id":1,"result":{"content":[...]}}
└──────┘
```

## IAM Roles & Permissions

### 1. Gateway Service Role

**Role:** `multi-tenant-db-agent-gateway-role`
**Trusted by:** `bedrock-agentcore.amazonaws.com`
**Purpose:** The gateway assumes this role to invoke Lambdas and evaluate policies.

```
┌─────────────────────────────────────────────────────────────┐
│ Trust Policy                                                 │
├─────────────────────────────────────────────────────────────┤
│ Principal: bedrock-agentcore.amazonaws.com                   │
│ Action:    sts:AssumeRole                                    │
│ NOTE:      Do NOT add aws:SourceAccount condition —          │
│            it breaks role assumption                          │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ Identity Policy                                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ Statement 1: Invoke Lambda targets                           │
│   Action:   lambda:InvokeFunction                            │
│   Resource: arn:aws:lambda:*:*:function:*-db-tools           │
│             arn:aws:lambda:*:*:function:*-db-tools:*         │
│             arn:aws:lambda:*:*:function:*-rate-limiter        │
│             arn:aws:lambda:*:*:function:*-rate-limiter:*      │
│                                                              │
│ Statement 2: Policy engine authorization                     │
│   Actions:  bedrock-agentcore:AuthorizeAction                │
│             bedrock-agentcore:CheckAuthorizePermissions       │
│             bedrock-agentcore:GetPolicyEngine                 │
│             bedrock-agentcore:PartiallyAuthorizeActions       │
│   Resource: * (required — ARN format is non-standard)        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Why `Resource: *` for policy engine?** The `CheckAuthorizePermissions` action uses a non-standard ARN path (`/policy-engines/.../target-resource/...`) that doesn't match standard resource patterns.

---

### 2. Rate Limiter Lambda Role

**Role:** `multi-tenant-db-agent-rate-limiter`
**Trusted by:** `lambda.amazonaws.com`
**Purpose:** Execute the interceptor Lambda and read/write DynamoDB counters.

```
┌─────────────────────────────────────────────────────────────┐
│ Permissions                                                  │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ AWSLambdaBasicExecutionRole (managed policy)                 │
│   → CloudWatch Logs: CreateLogGroup, CreateLogStream,        │
│                      PutLogEvents                            │
│                                                              │
│ Custom: DynamoDB access                                      │
│   Actions:  dynamodb:UpdateItem, dynamodb:GetItem            │
│   Resource: arn:aws:dynamodb:*:*:table/*-rate-limits         │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

### 3. DB Tools Lambda Role

**Role:** `multi-tenant-db-agent-db-tools`
**Trusted by:** `lambda.amazonaws.com`
**Purpose:** Execute the tool Lambda (mock data — no external access needed).

```
┌─────────────────────────────────────────────────────────────┐
│ Permissions                                                  │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ AWSLambdaBasicExecutionRole (managed policy)                 │
│   → CloudWatch Logs only                                     │
│                                                              │
│ In production, add:                                          │
│   → RDS/Redshift/Athena query permissions                    │
│   → Secrets Manager for DB credentials                       │
│   → VPC access if database is in a VPC                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

### 4. Lambda Resource Policies (who can invoke)

Both Lambdas have resource-based policies allowing the gateway to invoke them:

```
┌─────────────────────────────────────────────────────────────┐
│ Lambda Resource Policy (on both Lambdas)                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ Principal: bedrock-agentcore.amazonaws.com                   │
│ Action:    lambda:InvokeFunction                             │
│ Condition: aws:SourceAccount = <account_id>                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

### 5. Deployer Permissions (your IAM user/role)

To deploy and manage this infrastructure, you need:

```
┌─────────────────────────────────────────────────────────────┐
│ Deployer IAM Permissions                                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ Terraform deployment:                                        │
│   cognito-idp:*              (User Pool, groups, users)      │
│   dynamodb:*                 (rate limits table)             │
│   lambda:*                   (both Lambdas)                  │
│   iam:*                      (roles, policies)               │
│   bedrock-agentcore:*        (gateway, target)               │
│                                                              │
│ Policy script (boto3):                                       │
│   bedrock-agentcore:CreatePolicyEngine                       │
│   bedrock-agentcore:GetPolicyEngine                          │
│   bedrock-agentcore:ListPolicyEngines                        │
│   bedrock-agentcore:CreatePolicy                             │
│   bedrock-agentcore:ListPolicies                             │
│   bedrock-agentcore:DeletePolicy                             │
│   bedrock-agentcore:UpdateGateway                            │
│   bedrock-agentcore:GetGateway                               │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Component Interaction Map

```
                    ┌─────────────┐
                    │   Cognito   │
                    │  User Pool  │
                    └──────┬──────┘
                           │ issues JWT
                           ▼
┌────────┐  access   ┌─────────────────────────────────────────────┐
│ Client │──token───▶│            AgentCore Gateway                 │
└────────┘           │                                              │
                     │  assumes ──▶ Gateway Service Role             │
                     │              │                                │
                     │              ├─▶ lambda:InvokeFunction        │
                     │              │   (rate-limiter, db-tools)     │
                     │              │                                │
                     │              └─▶ bedrock-agentcore:Authorize* │
                     │                  (policy engine evaluation)   │
                     │                                              │
                     │  invokes ──▶ Rate Limiter Lambda              │
                     │              │                                │
                     │              └─▶ dynamodb:UpdateItem          │
                     │                  (rate counters)              │
                     │                                              │
                     │  invokes ──▶ DB Tools Lambda                  │
                     │              │                                │
                     │              └─▶ (mock data, no external)     │
                     │                                              │
                     │  evaluates ─▶ Policy Engine                   │
                     │               └─▶ 7 Cedar Policies            │
                     └──────────────────────────────────────────────┘
```

## Security Boundaries

| Boundary | Mechanism | Failure Mode |
|----------|-----------|--------------|
| Is the caller authenticated? | JWT validation (Cognito OIDC) | 401 Invalid Bearer token |
| Does the token have required scopes? | allowedScopes check | 403 insufficient_scope |
| Is this role allowed this tool? | Cedar Policy Engine | 403 Tool Execution Denied |
| Has the user exceeded their quota? | Interceptor Lambda + DynamoDB | 429 Rate limit exceeded |
| Can the gateway invoke the Lambda? | IAM role + resource policy | 500 InternalServerException |

## Cedar Policy Evaluation Detail

```
Request: Engineer calls DatabaseTools___delete_records

Cedar evaluates ALL policies:

  ✓ EngineeringRunQuery         → scope doesn't match (different action)
  ✓ EngineeringListTables       → scope doesn't match (different action)
  ✓ EngineeringDescribeTable    → scope doesn't match (different action)
  ★ EngineeringForbidDelete     → MATCHES! (forbid)
      principal is OAuthUser ✓
      action == DatabaseTools___delete_records ✓
      resource == this gateway ✓
      cognito:groups like "*engineering*" ✓

  Result: DENY (forbid overrides everything)
```

```
Request: Engineer calls DatabaseTools___run_query

Cedar evaluates ALL policies:

  ★ EngineeringRunQuery         → MATCHES! (permit)
      principal is OAuthUser ✓
      action == DatabaseTools___run_query ✓
      resource == this gateway ✓
      cognito:groups like "*engineering*" ✓
  ✓ EngineeringForbidDelete     → scope doesn't match (different action)

  Result: ALLOW (at least one permit, no forbid matches)
```
