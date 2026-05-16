"""
Gateway Response Interceptor — PII Redaction by Department

This Lambda runs AFTER the tool Lambda returns data but BEFORE
the response reaches the client. It redacts PII based on the
caller's Cognito group:

  admins:      No redaction (full access)
  engineering: SSNs redacted, emails visible
  marketing:   SSNs and emails redacted

Response interceptor input format:
{
    "interceptorInputVersion": "1.0",
    "mcp": {
        "gatewayRequest": { "headers": {...}, "body": {...} },
        "gatewayResponse": { "statusCode": 200, "body": {...} }
    }
}

Response interceptor output format:
{
    "interceptorOutputVersion": "1.0",
    "mcp": {
        "transformedGatewayResponse": { "statusCode": 200, "body": {...} }
    }
}
"""

import json
import re
import base64


# Redaction rules by group
# Each group has a list of (pattern, replacement) tuples
REDACTION_RULES = {
    "admins": [],  # No redaction
    "engineering": [
        # Redact SSN patterns (xxx-xx-xxxx)
        (r"\b\d{3}-\d{2}-\d{4}\b", "***-**-****"),
        # Redact credit card numbers (16 digits with optional separators)
        (r"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b", "****-****-****-****"),
    ],
    "marketing": [
        # Redact SSNs
        (r"\b\d{3}-\d{2}-\d{4}\b", "***-**-****"),
        # Redact email addresses
        (r"[\w.+-]+@[\w-]+\.[\w.-]+", "[REDACTED_EMAIL]"),
        # Redact credit card numbers
        (r"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b", "****-****-****-****"),
        # Redact phone numbers (US format)
        (r"\b(\+1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b", "[REDACTED_PHONE]"),
    ],
}

# Default rules for unknown groups
DEFAULT_RULES = REDACTION_RULES["marketing"]  # Most restrictive


def handler(event, context):
    """
    Response interceptor: redacts PII from tool responses based on caller's group.
    """
    try:
        mcp_data = event.get("mcp", {})
        gateway_request = mcp_data.get("gatewayRequest", {})
        gateway_response = mcp_data.get("gatewayResponse", {})

        # Get the response body
        response_body = gateway_response.get("body", {})
        status_code = gateway_response.get("statusCode", 200)

        # Determine the caller's group from the request headers
        group = extract_group(gateway_request.get("headers", {}))

        # Get redaction rules for this group
        rules = REDACTION_RULES.get(group, DEFAULT_RULES)

        # If no rules (admins), pass through unchanged
        if not rules:
            return {
                "interceptorOutputVersion": "1.0",
                "mcp": {
                    "transformedGatewayResponse": {
                        "statusCode": status_code,
                        "body": response_body,
                    }
                },
            }

        # Apply redaction to the response body
        redacted_body = redact_response(response_body, rules)

        # Add a header indicating redaction was applied
        return {
            "interceptorOutputVersion": "1.0",
            "mcp": {
                "transformedGatewayResponse": {
                    "statusCode": status_code,
                    "body": redacted_body,
                }
            },
        }

    except Exception as e:
        # Fail closed for PII: if redaction fails, return an error
        # rather than leaking unredacted data
        print(f"[pii-redactor] Error: {e}")
        return {
            "interceptorOutputVersion": "1.0",
            "mcp": {
                "transformedGatewayResponse": {
                    "statusCode": 500,
                    "body": {
                        "jsonrpc": "2.0",
                        "id": 0,
                        "error": {
                            "code": -32001,
                            "message": "PII redaction failed — response blocked for safety.",
                        },
                    },
                }
            },
        }


def extract_group(headers):
    """Extract the caller's group from the JWT in the Authorization header."""
    auth_header = headers.get("authorization", headers.get("Authorization", ""))

    if not auth_header.startswith("Bearer "):
        return "default"

    try:
        token = auth_header.split(" ")[1]
        payload = token.split(".")[1]
        payload += "=" * (4 - len(payload) % 4)
        claims = json.loads(base64.b64decode(payload))
        groups = claims.get("cognito:groups", [])

        if isinstance(groups, list) and groups:
            return groups[0]
        elif isinstance(groups, str):
            return groups
    except Exception:
        pass

    return "default"


def redact_response(body, rules):
    """Apply redaction rules to the response body recursively."""
    if isinstance(body, str):
        return apply_rules(body, rules)
    elif isinstance(body, dict):
        return {k: redact_response(v, rules) for k, v in body.items()}
    elif isinstance(body, list):
        return [redact_response(item, rules) for item in body]
    else:
        return body


def apply_rules(text, rules):
    """Apply regex redaction rules to a string."""
    for pattern, replacement in rules:
        text = re.sub(pattern, replacement, text)
    return text
