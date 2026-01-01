#!/usr/bin/env python3
"""Test if new modules can be imported"""

import sys
import importlib

print("Testing module imports...")
print()

# Check what's in PyImport_Inittab via sys.builtin_module_names
print("=== Builtin Module Names ===")
print(f"Total: {len(sys.builtin_module_names)}")
print(f"_wasisocket present: {'_wasisocket' in sys.builtin_module_names}")
print(f"binascii present: {'binascii' in sys.builtin_module_names}")
print(f"select present: {'select' in sys.builtin_module_names}")
print()

# Try importing with more details
print("=== Import Attempts ===")

# Test binascii
print("Trying binascii...")
try:
    import binascii
    print(f"✓ binascii imported: {binascii}")
    print(f"  hexlify(b'test'): {binascii.hexlify(b'test')}")
except Exception as e:
    print(f"✗ binascii failed: {type(e).__name__}: {e}")
    import traceback
    traceback.print_exc()

print()

# Test select
print("Trying select...")
try:
    import select
    print(f"✓ select imported: {select}")
except Exception as e:
    print(f"✗ select failed: {type(e).__name__}: {e}")
    import traceback
    traceback.print_exc()

print()
print("=== sys.builtin_module_names (first 20) ===")
for mod in sorted(sys.builtin_module_names)[:20]:
    print(f"  {mod}")
