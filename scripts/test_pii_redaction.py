#!/usr/bin/env python3
"""
Test PII redaction response interceptor.

Calls run_query as each role and checks whether PII is visible or redacted.
The mock data includes: emails, SSNs, and phone numbers.
"""

import boto3
import base64
import hmac
import hashlib
import requests
import json
import subprocess

# Config
REGION = "us-east-1"
CLIENT_ID = "67pjmvarbmk6r9ihscld3d4gd1"
CLIENT_SECRET = "ehem0eeg264501rlguv4g4kqvtvfqpnhori834so91f0nf3v5vm"

# Get gateway URL from terraform
TERRAFORM_DIR = "terraform"
try:
    GATEWAY_URL = subprocess.check_output(
        ["terraform", f"-chdir={TERRAFORM_DIR}", "output", "-raw", "gateway_url"],
        text=True, stderr=subprocess.DEVNULL
    ).strip()
except Exception:
    GATEWAY_URL = input("Enter gateway URL: ").strip()

cognito = boto3.client("cognito-idp", region_name=REGION)


def get_token(email):
    msg = email + CLIENT_ID
    sh = base64.b64encode(
        hmac.new(CLIENT_SECRET.encode(), msg.encode(), hashlib.sha256).digest()
    ).decode()
    auth = cognito.initiate_auth(
        AuthFlow="USER_PASSWORD_AUTH",
        ClientId=CLIENT_ID,
        AuthParameters={"USERNAME": email, "PASSWORD": "TestPass1", "SECRET_HASH": sh},
    )
    return auth["AuthenticationResult"]["AccessToken"]


def call_run_query(token):
    resp = requests.post(
        GATEWAY_URL,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "DatabaseTools___run_query",
                "arguments": {"sql": "SELECT * FROM users LIMIT 3", "database": "analytics"},
            },
        },
    )
    return resp.json()


def extract_text(response):
    """Extract the text content from the MCP response."""
    try:
        return response["result"]["content"][0]["text"]
    except (KeyError, IndexError):
        return json.dumps(response)


# PII patterns to check for
TEST_PIII = {
    "email": "alice.johnson@company.com",
    "ssn": "123-45-6789",
    "phone": "212-555-0147",
}

REDACTED_MARKERS = {
    "email": "[REDACTED_EMAIL]",
    "ssn": "***-**-****",
    "phone": "[REDACTED_PHONE]",
}


def check_pii(text, role):
    """Check what PII is visible vs redacted in the response."""
    results = {}
    for pii_type, value in TEST_PIII.items():
        if value in text:
            results[pii_type] = "VISIBLE"
        elif REDACTED_MARKERS[pii_type] in text:
            results[pii_type] = "REDACTED"
        else:
            results[pii_type] = "ABSENT"
    return results


def main():
    print("=" * 70)
    print("PII REDACTION TEST — Response Interceptor")
    print("=" * 70)
    print(f"Gateway: {GATEWAY_URL}")
    print()

    # Expected results
    expected = {
        "admin@example.com": {"email": "VISIBLE", "ssn": "VISIBLE", "phone": "VISIBLE"},
        "engineer@example.com": {"email": "VISIBLE", "ssn": "REDACTED", "phone": "VISIBLE"},
        "marketing@example.com": {"email": "REDACTED", "ssn": "REDACTED", "phone": "REDACTED"},
    }

    all_pass = True

    for email, expect in expected.items():
        role = email.split("@")[0]
        print(f"--- {role} ---")

        token = get_token(email)
        response = call_run_query(token)
        text = extract_text(response)

        # Check for errors
        if response.get("error") or response.get("result", {}).get("isError"):
            err = response.get("error", {}).get("message", "") or text
            print(f"  ⚠️  Request failed: {err[:80]}")
            all_pass = False
            print()
            continue

        results = check_pii(text, role)

        for pii_type in ["email", "ssn", "phone"]:
            actual = results[pii_type]
            exp = expect[pii_type]
            status = "✅" if actual == exp else "❌"
            if actual != exp:
                all_pass = False
            print(f"  {status} {pii_type:6s}: {actual:8s} (expected {exp})")

        # Show a snippet of the response
        print(f"  Response preview: {text[:120]}...")
        print()

    print("=" * 70)
    if all_pass:
        print("ALL TESTS PASSED ✅")
    else:
        print("SOME TESTS FAILED ❌")
    print("=" * 70)


if __name__ == "__main__":
    main()
