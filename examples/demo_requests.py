#!/usr/bin/env python3
"""
Simple requests demo for zig-wasm-cpython

Demonstrates basic HTTP functionality with the requests library.
Note: HTTPS not supported yet (requires TLS in WASI).
"""

import requests

print("Fetching example.com...")
print()

# Disable compression (zlib not available in WASM)
headers = {'Accept-Encoding': 'identity'}

# Make HTTP GET request
response = requests.get('http://example.com', headers=headers, timeout=10)

print(f"Status: {response.status_code} {response.reason}")
print(f"Content-Type: {response.headers.get('content-type')}")
print(f"Content-Length: {len(response.content)} bytes")
print()
print("Response:")
print("-" * 70)
print(response.text[:500])
print("-" * 70)

# Test POST with JSON
print()
print("Testing POST with JSON payload...")
payload = {'message': 'Hello from WASM!', 'source': 'zig-wasm-cpython'}
response = requests.post('http://httpbin.org/post', json=payload, headers=headers, timeout=10)
print(f"POST Status: {response.status_code}")
result = response.json()
print(f"Server echoed: {result.get('json', {})}")

print()
print("✓ requests library is working in WASM CPython!")
