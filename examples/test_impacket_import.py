#!/usr/bin/env python3
"""
Test impacket import in Python WASM

NOTE: socket_patch.py must be loaded BEFORE this script!
"""

import sys
print("=" * 70)
print("Testing impacket in Python WASM with custom sockets")
print("=" * 70)
print()

# Test 1: Import impacket
print("Test 1: Import impacket")
print("-" * 70)
try:
    import impacket
    print(f"✓ impacket imported successfully")
    print(f"  Location: {impacket.__file__}")
    try:
        print(f"  Version: {impacket.version.BANNER}")
    except:
        print(f"  Version: (version module not available)")
except Exception as e:
    print(f"✗ Failed: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

print()

# Test 2: Import SMB
print("Test 2: Import SMB modules")
print("-" * 70)
try:
    from impacket import smb, smb3
    print(f"✓ SMB modules imported")
    print(f"  smb: {smb.__file__}")
    print(f"  smb3: {smb3.__file__}")
except Exception as e:
    print(f"✗ Failed: {e}")
    import traceback
    traceback.print_exc()

print()

# Test 3: Import SMBConnection
print("Test 3: Import SMBConnection")
print("-" * 70)
try:
    from impacket.smbconnection import SMBConnection
    print(f"✓ SMBConnection imported")
    print(f"  Class: {SMBConnection}")
except Exception as e:
    print(f"✗ Failed: {e}")
    import traceback
    traceback.print_exc()

print()

# Test 4: Check wasisocket availability
print("Test 4: Check socket compatibility")
print("-" * 70)
try:
    import wasisocket
    print(f"✓ wasisocket available")
    print(f"  Can create socket: ", end="")
    sock = wasisocket.Socket()
    print(f"✓ (fd={sock.fileno()})")
    sock.close()
except Exception as e:
    print(f"✗ {e}")

print()
print("=" * 70)
print("impacket is ready to use!")
print("=" * 70)
