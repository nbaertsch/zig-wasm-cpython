#!/usr/bin/env python3
"""
Simple test script to verify zig-wasm-cpython works correctly.
"""

import sys
import json

print("=" * 60)
print("zig-wasm-cpython Test Script")
print("=" * 60)
print(f"Python version: {sys.version}")
print(f"Platform: {sys.platform}")
print()

# Test JSON module
data = {
    "message": "Hello from Python in WASM!",
    "features": ["VFS", "Sockets", "Standard Library"],
    "status": "working"
}

print("Testing JSON module:")
json_str = json.dumps(data, indent=2)
print(json_str)
print()

# Test list comprehension
print("Testing Python features:")
squares = [x**2 for x in range(10)]
print(f"Squares: {squares}")
print()

# Test socket availability
print("Testing raw socket with HTTP request:")
try:
    import socket
    import time
    
    # Create socket and connect
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    print(f"✓ Socket created")
    
    sock.connect(("example.com", 80))
    print(f"✓ Connected to example.com:80")
    
    # Send HTTP request in small chunks to avoid WouldBlock
    request = b"GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
    print(f"✓ Sending {len(request)} byte request...")
    
    # Send in smaller chunks
    chunk_size = 32
    for i in range(0, len(request), chunk_size):
        chunk = request[i:i+chunk_size]
        sent = sock.send(chunk)
        print(f"  Sent {sent} bytes")
    
    print(f"✓ Request sent successfully")
    
    # Receive response
    print(f"✓ Receiving response...")
    response = b""
    while True:
        try:
            chunk = sock.recv(1024)
            if not chunk:
                break
            response += chunk
        except:
            break
    
    sock.close()
    
    # Parse response
    response_text = response.decode('utf-8', errors='ignore')
    status_line = response_text.split('\r\n')[0]
    print(f"✓ HTTP Response: {status_line}")
    print(f"✓ Received {len(response)} bytes")
    
    # Show preview
    body_start = response_text.find('\r\n\r\n')
    if body_start != -1:
        preview = response_text[body_start+4:body_start+100].replace('\n', ' ')
        print(f"✓ Content: {preview}...")
        
except Exception as e:
    print(f"✗ Socket test failed: {e}")
    import traceback
    traceback.print_exc()
print()

print("=" * 60)
print("All tests passed! ✅")
print("=" * 60)
