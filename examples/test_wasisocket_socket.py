import _wasisocket

print("Testing _wasisocket.socket class:")
try:
    sock = _wasisocket.socket(_wasisocket.AF_INET, _wasisocket.SOCK_STREAM)
    print(f"Created socket: {sock}")
    print(f"Socket type: {type(sock)}")
    print(f"Socket attributes: {[a for a in dir(sock) if not a.startswith('_')]}")
except Exception as e:
    print(f"Error: {e}")
