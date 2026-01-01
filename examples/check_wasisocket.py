import _wasisocket

print("_wasisocket attributes:")
for attr in dir(_wasisocket):
    if not attr.startswith('_'):
        print(f"  {attr}: {type(getattr(_wasisocket, attr))}")
