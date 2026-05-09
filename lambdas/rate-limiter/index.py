"""
Gateway Request Interceptor — Per-User Rate Limiting

This Lambda runs BEFORE the tool invocation reaches the backend.
It checks a DynamoDB table for the caller's usage in the current
hour window and either passes the request through or returns 429.

Rate limits by role:
  - admins:      100 requests/hour
  - engineering:  50 requests/hour
  - marketing:    20 requests/hour
  - default:      10 requests/hour

The interceptor expects the gateway to pass request headers
(configured via inputConfiguration.passRequestHeaders = true).
The JWT claims are available in the headers after the gateway's
authorizer validates the token.
"""

import json
import time
import os
import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("RATE_LIMIT_TABLE", "AgentRateLimits"))

# Requests per hour by role
RATE_LIMITS = {
    "admins": 100,
    "engineering": 50,
    "marketing": 20,
}
DEFAULT_LIMIT = 10


def handler(event, context):
    """
    Event shape (gateway interceptor request):
    {
        "headers": { ... },
        "body": "{ ... tool call payload ... }",
        "requestContext": {
            "authorizer": {
                "claims": {
                    "sub": "user-id",
                    "groups": "engineering",
                    ...
                }
            }
        }
    }
    """
    try:
        # Extract caller identity from authorizer claims
        claims = event.get("requestContext", {}).get("authorizer", {}).get("claims", {})
        user_id = claims.get("sub", "anonymous")
        group = claims.get("groups", "default")

        # If groups is a list (some IdPs do this), take the first
        if isinstance(group, list):
            group = group[0] if group else "default"

        # Determine the rate limit for this role
        max_requests = RATE_LIMITS.get(group, DEFAULT_LIMIT)

        # Current hour window (floor to the hour)
        now = int(time.time())
        window_key = now - (now % 3600)

        # Composite key: userId#windowStart
        partition_key = f"{user_id}#{window_key}"

        # Atomic increment in DynamoDB
        response = table.update_item(
            Key={"pk": partition_key},
            UpdateExpression="SET #cnt = if_not_exists(#cnt, :zero) + :one, #ttl = :ttl_val",
            ExpressionAttributeNames={
                "#cnt": "request_count",
                "#ttl": "ttl",
            },
            ExpressionAttributeValues={
                ":zero": 0,
                ":one": 1,
                ":ttl_val": window_key + 7200,  # TTL: 2 hours after window start
            },
            ReturnValues="UPDATED_NEW",
        )

        current_count = int(response["Attributes"]["request_count"])

        if current_count > max_requests:
            return {
                "statusCode": 429,
                "body": json.dumps({
                    "error": "Rate limit exceeded",
                    "message": f"You have exceeded {max_requests} requests/hour for the '{group}' role. "
                               f"Current count: {current_count}. Try again at the top of the next hour.",
                    "retryAfter": window_key + 3600 - now,
                }),
            }

        # Add rate limit headers to the response for observability
        headers = event.get("headers", {})
        headers["X-RateLimit-Limit"] = str(max_requests)
        headers["X-RateLimit-Remaining"] = str(max(0, max_requests - current_count))
        headers["X-RateLimit-Reset"] = str(window_key + 3600)
        event["headers"] = headers

        # Pass through — request continues to the tool backend
        return event

    except Exception as e:
        # Fail open: if rate limiting breaks, let the request through
        # but log the error for investigation.
        print(f"[rate-limiter] Error: {e}")
        return event
