#!/usr/bin/env python3
import boto3, json, base64, hmac, hashlib, requests

client = boto3.client('bedrock-agentcore-control', region_name='us-east-1')
gw = client.get_gateway(gatewayIdentifier='dataplatformgateway-wl6bqdhywl')
print(f'Gateway status: {gw["status"]}')
print(f'Policy mode: {gw.get("policyEngineConfiguration", {}).get("mode")}')

if gw['status'] != 'READY':
    print('Gateway not ready yet — wait and retry')
    exit(1)

cognito = boto3.client('cognito-idp', region_name='us-east-1')
client_id = '67pjmvarbmk6r9ihscld3d4gd1'
client_secret = 'ehem0eeg264501rlguv4g4kqvtvfqpnhori834so91f0nf3v5vm'
email = 'engineer@example.com'
msg = email + client_id
secret_hash = base64.b64encode(
    hmac.new(client_secret.encode(), msg.encode(), hashlib.sha256).digest()
).decode()

auth = cognito.initiate_auth(
    AuthFlow='USER_PASSWORD_AUTH',
    ClientId=client_id,
    AuthParameters={'USERNAME': email, 'PASSWORD': 'TestPass1', 'SECRET_HASH': secret_hash}
)
token = auth['AuthenticationResult']['AccessToken']

resp = requests.post(
    gw['gatewayUrl'],
    headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
    json={
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
            'name': 'DatabaseTools___run_query',
            'arguments': {'sql': 'SELECT * FROM users LIMIT 10', 'database': 'analytics'}
        }
    }
)
print(f'HTTP {resp.status_code}')
print(json.dumps(resp.json(), indent=2))
