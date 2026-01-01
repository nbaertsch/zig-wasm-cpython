import sys
print("Python path:")
for path in sys.path:
    print(f"  {path}")
    
# Try to import zlib
try:
    import zlib
    print("zlib imported successfully!")
except ImportError as e:
    print(f"Failed to import zlib: {e}")
    print(f"Module search paths: {sys.path}")
