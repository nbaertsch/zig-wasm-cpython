import sys
print("Built-in modules:")
print([m for m in sys.builtin_module_names if 'z' in m.lower()])

try:
    import zlib
    print("zlib is available!")
except ImportError as e:
    print(f"zlib not available: {e}")
