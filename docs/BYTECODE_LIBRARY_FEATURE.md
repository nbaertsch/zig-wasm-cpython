# Python Bytecode Library Loading Feature

## Overview
This feature enables loading pre-compiled Python libraries (`.py` source files) into the VFS and using them from WASM CPython scripts. This demonstrates a complete workflow for packaging and running custom Python code in the WASM environment.

## Components

### 1. Example Library (`python_libs/mylib/`)
A demonstration library with multiple modules showing:
- **`__init__.py`**: Package initialization with exports
- **`math_utils.py`**: Mathematical functions (add, multiply, factorial, power)
- **`string_utils.py`**: String manipulation (reverse, capitalize, count_vowels, is_palindrome)
- **`data_processor.py`**: Data processing with internal dependencies and classes

### 2. Compiler Script (`compile_library.py`)
Python script that compiles libraries to bytecode-only format:
- Uses `py_compile` to generate `.pyc` files
- Supports optimization levels (0, 1, 2)
- Creates bytecode-only packages (no source files)
- Places `.pyc` files at package root (not in `__pycache__/`)
- Recursively processes all `.py` files
- Creates manifest file with compilation info

**Important**: For bytecode-only packages to work in Python, the `.pyc` files must be at the package root level, not in `__pycache__/` subdirectories.

Usage:
```bash
python3 compile_library.py python_libs/mylib compiled_libs/mylib
```

Output structure:
```
compiled_libs/mylib/
├── __init__.pyc
├── math_utils.pyc
├── string_utils.pyc
├── data_processor.pyc
└── MANIFEST.txt
```

### 3. VFS Loader Extension (`src/python/stdlib_loader.zig`)
Added `loadBytecodeLibrary()` function that:
- Loads **ONLY** bytecode `.pyc` files (no source files)
- Places them at `/usr/local/lib/python3.13/site-packages/`
- Supports recursive directory structures
- Skips `__pycache__/` directories
- Handles both `.pyc` files and manifest files

### 4. Demo Script (`demo_bytecode.py`)
Comprehensive test script that:
- Imports the custom library from VFS
- Tests all mathematical operations
- Tests string manipulation functions
- Tests data processing with internal dependencies
- Tests class instantiation from bytecode
- Verifies all functionality works in WASM

### 5. Integration (`src/main.zig`)
Modified to:
- Load bytecode library into VFS before Python execution
- Set up proper VFS preopen for Python to access
- Execute demo script from VFS

## Workflow

1. **Create Library**: Write Python library in `python_libs/`
2. **Compile**: Run `compile_library.py` to generate bytecode-only package
3. **Load**: `loadBytecodeLibrary()` loads `.pyc` files into VFS (no source files)
4. **Execute**: Python scripts can import and use the library from bytecode only

## Key Implementation Details

### Bytecode-Only Package Format
For Python to import from bytecode-only packages:
- `.pyc` files must be at the package root (e.g., `/mylib/__init__.pyc`)
- NOT in `__pycache__/` subdirectories
- No `.py` source files are required or loaded
- Python's import system finds and loads `.pyc` files directly

### VFS File Structure
```
/usr/local/lib/python3.13/site-packages/mylib/
├── __init__.pyc          (compiled package init)
├── math_utils.pyc        (compiled module)
├── string_utils.pyc      (compiled module)
├── data_processor.pyc    (compiled module)
└── MANIFEST.txt          (metadata)
```

### VFS Path Handling
- VFS internal paths: `/usr/local/lib/python3.13/site-packages/mylib/`
- WASI guest paths: `/vfs/usr/local/lib/python3.13/site-packages/mylib/`
- VFS preopen at fd=3 with guest path `/vfs`

### Python Import System
- Libraries loaded at `site-packages/` are automatically in Python's import path
- Python imports directly from `.pyc` files when no `.py` source is present
- Bytecode files must be at package root for bytecode-only import to work
- Internal cross-module imports work correctly from bytecode

### Internal Dependencies
The demo library showcases:
- Cross-module imports (`data_processor.py` imports from `math_utils.py` and `string_utils.py`)
- Class definitions and instantiation
- Module-level functions and variables

## Test Results

All tests pass successfully:
```
WASM CPython Bytecode Library Demo
============================================================
✓ Successfully imported mylib
Testing Math Utilities:
  add(10, 20) = 30
  multiply(5, 7) = 35
  factorial(5) = 120

Testing String Utilities:
  reverse_string('hello world') = 'dlrow olleh'
  capitalize_words('hello world') = 'Hello World'

Testing Data Processor (with internal deps):
  Processing numbers: [1, 2, 3, 4, 5]
    Sum: 15, Product: 120

  Processing strings: ['hello', 'world', 'from', 'wasm']
    Capitalized: ['Hello', 'World', 'From', 'Wasm']

Testing Class Instantiation:
  Created DataProcessor: CustomProcessor
  Stats: {'name': 'CustomProcessor', 'processed_count': 1}

✓ All tests passed! Bytecode library works in WASM!
```

## Files Added/Modified

**New Files:**
- `python_libs/mylib/__init__.py` (source - not loaded into VFS)
- `python_libs/mylib/math_utils.py` (source - not loaded into VFS)
- `python_libs/mylib/string_utils.py` (source - not loaded into VFS)
- `python_libs/mylib/data_processor.py` (source - not loaded into VFS)
- `compile_library.py` (compiler script)
- `compiled_libs/mylib/*.pyc` (bytecode files - THESE are loaded into VFS)
- `demo_bytecode.py`

**Modified Files:**
- `src/python/stdlib_loader.zig` - Added `loadBytecodeLibrary()` and `loadBytecodeDirectoryIntoVFS()` functions
- `src/main.zig` - Integrated library loading and demo execution

**Key Point**: Only `.pyc` bytecode files from `compiled_libs/` are loaded into the VFS. No `.py` source files are included in the WASM environment.

## Future Enhancements

Potential improvements:
1. ~~Support for pure bytecode loading (no source files)~~ ✅ **DONE**
2. Automatic dependency resolution
3. Package metadata handling
4. Multiple library loading
5. Library versioning support
6. Support for compiled C extensions (`.so` files)