"""
Stub zlib module for WASM CPython

Since zlib is not available in WASM, this stub provides minimal functionality
to allow libraries like requests/urllib3 to import without error.
Compression features will not work, but basic HTTP will still function.
"""

class error(Exception):
    """Base class for zlib exceptions"""
    pass

# Compression constants (not actually used)
Z_DEFAULT_COMPRESSION = -1
DEFLATED = 8
MAX_WBITS = 15

# Methods that will raise NotImplementedError
def compress(data, level=-1):
    raise NotImplementedError("zlib compression not available in WASM")

def decompress(data, wbits=MAX_WBITS, bufsize=16384):
    raise NotImplementedError("zlib decompression not available in WASM")

def compressobj(level=-1, method=DEFLATED, wbits=MAX_WBITS, memLevel=8, strategy=0):
    raise NotImplementedError("zlib compression not available in WASM")

def decompressobj(wbits=MAX_WBITS):
    raise NotImplementedError("zlib decompression not available in WASM")

def crc32(data, value=0):
    """Stub CRC32 - always returns 0"""
    return 0

def adler32(data, value=1):
    """Stub Adler-32 - always returns 1"""
    return 1

print("[STUB] zlib module loaded as stub - compression features unavailable")
