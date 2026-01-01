#!/usr/bin/env python3
"""
Test script for the requests library in zig-wasm-cpython

Tests HTTP functionality using the popular requests library.
"""

import sys
print(f"Python version: {sys.version}")
print(f"Platform: {sys.platform}")
print()

print("=" * 70)
print("Testing requests library in WASM CPython")
print("=" * 70)
print()

# Test 1: Import requests
print("1. Importing requests library...")
try:
    import requests
    print(f"   ✓ Successfully imported requests {requests.__version__}")
except ImportError as e:
    print(f"   ✗ Failed to import requests: {e}")
    sys.exit(1)
print()

# Test 2: Simple GET request
print("2. Testing HTTP GET request to example.com...")
try:
    response = requests.get('http://example.com', timeout=5)
    print(f"   ✓ Status Code: {response.status_code}")
    print(f"   ✓ Content Length: {len(response.content)} bytes")
    print(f"   ✓ Response Headers: {len(response.headers)} headers")
    
    # Show first 100 characters of response
    content_preview = response.text[:100].replace('\n', ' ')
    print(f"   ✓ Content preview: {content_preview}...")
except Exception as e:
    print(f"   ✗ Request failed: {e}")
print()

# Test 3: Test with headers
print("3. Testing GET request with custom headers...")
try:
    headers = {
        'User-Agent': 'zig-wasm-cpython/1.0',
        'Accept': 'text/html'
    }
    response = requests.get('http://example.com', headers=headers, timeout=5)
    print(f"   ✓ Request with custom headers successful")
    print(f"   ✓ Status: {response.status_code}")
except Exception as e:
    print(f"   ✗ Request with headers failed: {e}")
print()

# Test 4: Test HTTPS (if supported)
print("4. Testing HTTPS request...")
try:
    response = requests.get('https://httpbin.org/get', timeout=5)
    print(f"   ✓ HTTPS Status Code: {response.status_code}")
    print(f"   ✓ HTTPS works!")
except Exception as e:
    print(f"   ⚠ HTTPS may not be fully supported: {e}")
print()

# Test 5: Test JSON response
print("5. Testing JSON response parsing...")
try:
    response = requests.get('http://httpbin.org/json', timeout=5)
    data = response.json()
    print(f"   ✓ JSON parsed successfully")
    print(f"   ✓ JSON keys: {list(data.keys())[:5]}...")
except Exception as e:
    print(f"   ✗ JSON parsing failed: {e}")
print()

# Test 6: Test POST request
print("6. Testing HTTP POST request...")
try:
    payload = {'key': 'value', 'test': 'data'}
    response = requests.post('http://httpbin.org/post', json=payload, timeout=5)
    print(f"   ✓ POST Status Code: {response.status_code}")
    result = response.json()
    print(f"   ✓ Server echoed back: {result.get('json', {})}")
except Exception as e:
    print(f"   ✗ POST request failed: {e}")
print()

print("=" * 70)
print("requests library test completed!")
print("=" * 70)
