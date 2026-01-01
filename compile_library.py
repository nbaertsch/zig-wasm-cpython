#!/usr/bin/env python3
"""
Smart Python Bytecode Compiler for WASM CPython

Compiles Python libraries to bytecode with dependency tracking and incremental compilation.

Usage:
    python3 compile_library.py ../impacket --name impacket --with-deps
"""

import py_compile
import os
import sys
import json
import hashlib
from pathlib import Path

COMPILED_LIBS_DIR = Path(__file__).parent / "compiled_libs"
MANIFEST_FILE = COMPILED_LIBS_DIR / ".manifest.json"

def load_manifest():
    if MANIFEST_FILE.exists():
        with open(MANIFEST_FILE, 'r') as f:
            return json.load(f)
    return {}

def save_manifest(manifest):
    MANIFEST_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_FILE, 'w') as f:
        json.dump(manifest, indent=2, fp=f)

def get_file_hash(path):
    with open(path, 'rb') as f:
        return hashlib.md5(f.read()).hexdigest()

def compile_lib(source_dir, lib_name, force=False):
    source = Path(source_dir).absolute()
    
    if not source.exists():
        print(f"Error: {source} not found")
        return 0, 0, 0
    
    # Check for package subdirectory
    if (source / lib_name).is_dir():
        source = source / lib_name
    
    target = COMPILED_LIBS_DIR / lib_name
    target.mkdir(parents=True, exist_ok=True)
    
    manifest = load_manifest()
    if lib_name not in manifest:
        manifest[lib_name] = {"files": {}}
    
    lib_data = manifest[lib_name]
    
    print(f"\n{'='*70}")
    print(f"Library: {lib_name}")
    print(f"Source:  {source}")
    print(f"Target:  {target}")
    print(f"{'='*70}\n")
    
    compiled, skipped, failed = 0, 0, 0
    
    for root, dirs, files in os.walk(source):
        # Skip tests and examples
        dirs[:] = [d for d in dirs if d not in ('__pycache__', 'test', 'tests', 'examples')]
        
        root_path = Path(root)
        rel_path = root_path.relative_to(source)
        target_dir = target / rel_path
        target_dir.mkdir(parents=True, exist_ok=True)
        
        for fname in files:
            if not fname.endswith('.py'):
                continue
            
            src_file = root_path / fname
            rel_file = str(rel_path / fname)
            pyc_file = target_dir / fname.replace('.py', '.pyc')
            
            # Check if compilation needed
            current_hash = get_file_hash(src_file)
            if not force and rel_file in lib_data["files"]:
                if lib_data["files"][rel_file] == current_hash and pyc_file.exists():
                    skipped += 1
                    continue
            
            # Compile
            try:
                py_compile.compile(
                    str(src_file),
                    cfile=str(pyc_file),
                    dfile=rel_file,
                    optimize=2,
                    doraise=True
                )
                lib_data["files"][rel_file] = current_hash
                print(f"  ✓ {rel_file}")
                compiled += 1
            except Exception as e:
                print(f"  ✗ {rel_file}: {e}")
                failed += 1
    
    manifest[lib_name] = lib_data
    save_manifest(manifest)
    
    print(f"\nCompiled: {compiled}, Skipped: {skipped}, Failed: {failed}\n")
    return compiled, skipped, failed

def compile_deps(req_file):
    if not req_file.exists():
        return
    
    print(f"\nProcessing dependencies from {req_file}...\n")
    
    with open(req_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or ';sys_platform' in line:
                continue
            
            pkg = line.split('>=')[0].split('==')[0].split('<')[0].split('>')[0].strip()
            print(f"Dependency: {pkg}")
            
            # Search for package
            for base in ["/usr/lib/python3.13", "/usr/local/lib/python3.13", 
                         str(Path.home() / ".local/lib/python3.13")]:
                pkg_path = Path(base) / "site-packages" / pkg
                if pkg_path.exists():
                    compile_lib(pkg_path.parent, pkg)
                    break
            else:
                print(f"  ⚠ Not found\n")

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser()
    parser.add_argument("library_path", type=Path)
    parser.add_argument("--name", help="Library name")
    parser.add_argument("--with-deps", action="store_true")
    parser.add_argument("--force", action="store_true")
    
    args = parser.parse_args()
    
    lib_path = args.library_path.absolute()
    lib_name = args.name or lib_path.name
    
    compile_lib(lib_path, lib_name, args.force)
    
    if args.with_deps:
        req_file = lib_path / "requirements.txt"
        compile_deps(req_file)
    
    print(f"\n{'='*70}")
    print(f"Done! Compiled libraries in: {COMPILED_LIBS_DIR}")
    print(f"{'='*70}\n")
