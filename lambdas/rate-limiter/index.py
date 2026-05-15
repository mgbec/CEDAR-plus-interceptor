"""
Gateway Request Interceptor — Rate Limiting

Interceptor response format for pass-through:
{
    "interceptorOutputVersion": "1.0",
    "mcp": {
        "transformedGatewayRequest": {
            "body": <the MCP request body>
        }
    }
}
"""

import json
import time
import os
import base64
import boto3

dynamodb = boto3.resource("dynamodb")
table_name = os.environ.get("RATE_LIMIT_TABLE", "AgentRateLimits")
table = dynamodb.Table(table_name)

# Requests per hour by role
RATE_LIMITS = {
    "admins": 100,
    "engineering": 50,
    "marketing": 20,
}
DEFAULT_LIMIT = 10


def handler(event, context):
    mcp_data = event.get("mcp", {})
    gateway_request = mcp_data.get("gatewayRequest", {})
    request_body = gateway_request.get("body", {})
    headers = gateway_request.get("headers", {})

    try:
        # Extract user info from the JWT in the authorization header
        user_id = "anonymous"
        group = "default"

        auth_header = headers.get("authorization", headers.get("Authorization", ""))
        if auth_header.startswith("Bearer "):
            try:
                token = auth_header.split(" ")[1]
                payload = token.split(".")[1]
                payload += "=" * (4 - len(payload) % 4)
                claims = json.loads(base64.b64decode(payload))
                user_id = claims.get("sub", "anonymous")
                groups = claims.get("cognito:groups", [])
                if isinstance(groups, list) and groups:
                    group = groups[0]
                elif isinstance(groups, str):
                    group = groups
            except Exception:
                pass

        # Determine the rate limit for this role
        max_requests = RATE_LIMITS.get(group, DEFAULT_LIMIT)

        # Current hour window
        now = int(time.time())
        window_key = now - (now % 3600)
        partition_key = f"{user_id}#{window_key}"

        # Atomic increment in DynamoDB
        response = table.update_item(
            Key={"pk": partition_key},
            UpdateExpression="SET #cnt = if_not_exists(#cnt, :zero) + :one, #ttl = :ttl_val",
            ExpressionAttributeNames={"#cnt": "request_count", "#ttl": "ttl"},
            ExpressionAttributeValues={
                ":zero": 0,
                ":one": 1,
                ":ttl_val": window_key + 7200,
            },
            ReturnValues="UPDATED_NEW",
        )

        current_count = int(response["Attributes"]["request_count"])

        if current_count > max_requests:
            # Block: replace the body with an error response
            return {
                "interceptorOutputVersion": "1.0",
                "mcp": {
                    "transformedGatewayRequest": {
                        "body": {
                            "jsonrpc": "2.0",
                            "id": request_body.get("id", 0),
                            "error": {
                                "code": -32001,
                                "message": f"Rate limit exceeded: {current_count}/{max_requests} requests/hour for '{group}' role.",
                            },
                        }
                    }
                },
            }

        # Pass through unchanged
        return {
            "interceptorOutputVersion": "1.0",
            "mcp": {
                "transformedGatewayRequest": {
                    "body": request_body,
                }
            },
        }

    except Exception as e:
        # Fail open
        print(f"[rate-limiter] Error: {e}")
        return {
            "interceptorOutputVersion": "1.0",
            "mcp": {
                "transformedGatewayRequest": {
                    "body": request_body,
                }
            },
        }
