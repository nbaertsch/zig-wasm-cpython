#!/usr/bin/env python3
"""
Socket example using requests library to fetch a website.

Raw sockets have WouldBlock issues in WASI, but the requests library
handles these properly through urllib3's retry and error handling.
"""

import requests

print("=" * 70)
print("Socket Example: Fetching website with HTTP")
print("=" * 70)
print()

# Disable compression (zlib not available in WASM)
headers = {'Accept-Encoding': 'identity'}

# Fetch example.com
print("Connecting to example.com...")
response = requests.get('http://example.com', headers=headers, timeout=10)

print(f"✓ Connected successfully!")
print(f"✓ HTTP Status: {response.status_code} {response.reason}")
print(f"✓ Content-Type: {response.headers.get('Content-Type')}")
print(f"✓ Content-Length: {len(response.content)} bytes")
print()

# Show the response
print("Response Content:")
print("-" * 70)
print(response.text)
print("-" * 70)
print()

# Additional example: POST request
print("Testing POST request with JSON...")
payload = {'test': 'data', 'from': 'wasm'}
response = requests.post('http://httpbin.org/post', json=payload, headers=headers, timeout=10)
print(f"✓ POST Status: {response.status_code}")
result = response.json()
print(f"✓ Server received: {result.get('json', {})}")
print()

print("=" * 70)
print("Socket example completed successfully! ✅")
print("=" * 70)
