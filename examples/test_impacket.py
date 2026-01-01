#!/usr/bin/env python3
"""
Test impacket in Python WASM with custom socket support
"""

import sys
print("Python version:", sys.version)
print("=" * 70)

# Test 1: Basic imports
print("\nTest 1: Import impacket")
print("-" * 70)
try:
    import impacket
    print(f"✓ impacket imported successfully")
except ImportError as e:
    print(f"✗ Failed to import impacket: {e}")
    sys.exit(1)

# Test 2: Import SMB client
print("\nTest 2: Import SMB client")
print("-" * 70)
try:
    from impacket.smbconnection import SMBConnection
    print(f"✓ SMBConnection imported")
    print(f"  Class: {SMBConnection}")
except ImportError as e:
    print(f"✗ Failed to import SMBConnection: {e}")

# Test 3: Test socket usage
print("\nTest 3: Create SMB connection (will test socket)")
print("-" * 70)
try:
    # This will test if impacket can use our wasisocket
    import wasisocket
    print(f"✓ wasisocket available")
    
    # Try to patch socket module for impacket
    sys.modules['socket'] = wasisocket
    print(f"✓ Patched socket module")
    
    # Now try SMB connection
    conn = SMBConnection("192.168.1.1", "192.168.1.1", timeout=1)
    print(f"✓ SMBConnection created")
except Exception as e:
    print(f"✗ Connection failed: {e}")
    import traceback
    traceback.print_exc()

print("\n" + "=" * 70)
print("Test Complete")
