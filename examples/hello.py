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

print("=" * 60)
print("All tests passed! ✅")
print("=" * 60)
