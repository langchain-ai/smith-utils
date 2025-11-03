#!/usr/bin/env python3
"""
Extract all external package dependencies from a Python file and create requirements.txt

Usage:
    python extract_requirements.py <python_file.py> [output_file.txt]

Examples:
    python extract_requirements.py my_script.py
    python extract_requirements.py my_script.py custom_requirements.txt
"""

import ast
import sys
import subprocess
from pathlib import Path
from typing import Set

def get_stdlib_modules() -> Set[str]:
    """Get a set of all standard library module names"""
    stdlib_modules = set(sys.stdlib_module_names)  # Python 3.10+
    
    # For Python < 3.10, fallback to common stdlib modules
    if not stdlib_modules:
        stdlib_modules = {
            'abc', 'argparse', 'ast', 'asyncio', 'base64', 'collections',
            'copy', 'csv', 'datetime', 'decimal', 'email', 'functools',
            'glob', 'hashlib', 'io', 'itertools', 'json', 'logging',
            'math', 'os', 'pathlib', 'pickle', 're', 'shutil', 'socket',
            'sqlite3', 'string', 'subprocess', 'sys', 'tempfile', 'threading',
            'time', 'typing', 'unittest', 'urllib', 'uuid', 'warnings', 'xml'
        }
    
    return stdlib_modules

def extract_imports(file_path: str) -> Set[str]:
    """Extract all import statements from a Python file"""
    with open(file_path, 'r', encoding='utf-8') as f:
        try:
            tree = ast.parse(f.read(), filename=file_path)
        except SyntaxError as e:
            print(f"⚠️  Syntax error in {file_path}: {e}")
            return set()
    
    imports = set()
    
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                # Get the top-level package name
                package = alias.name.split('.')[0]
                imports.add(package)
        
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                # Get the top-level package name
                package = node.module.split('.')[0]
                imports.add(package)
    
    return imports

def get_package_version(package_name: str) -> str:
    """Get installed version of a package using pip"""
    try:
        result = subprocess.run(
            [sys.executable, '-m', 'pip', 'show', package_name],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            for line in result.stdout.split('\n'):
                if line.startswith('Version:'):
                    return line.split(':', 1)[1].strip()
        
        return ''
    except Exception:
        return ''

def create_requirements(file_path: str, output_file: str = 'requirements.txt'):
    """Main function to create requirements.txt from a Python file"""
    
    print(f"🔍 Analyzing: {file_path}")
    
    # Extract all imports
    all_imports = extract_imports(file_path)
    
    if not all_imports:
        print("❌ No imports found!")
        return
    
    # Filter out standard library modules
    stdlib = get_stdlib_modules()
    external_packages = sorted(all_imports - stdlib)
    
    if not external_packages:
        print("✅ No external packages found (only standard library imports)")
        return
    
    print(f"\n📦 Found {len(external_packages)} external package(s):")
    
    # Create requirements.txt
    with open(output_file, 'w', encoding='utf-8') as f:
        for package in external_packages:
            version = get_package_version(package)
            
            if version:
                line = f"{package}=={version}"
                print(f"  ✓ {line}")
            else:
                line = package
                print(f"  ⚠️  {package} (version not found, not installed?)")
            
            f.write(line + '\n')
    
    print(f"\n✅ Created: {output_file}")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python extract_requirements.py <python_file.py> [output_file.txt]")
        print("\nExample:")
        print("  python extract_requirements.py my_script.py")
        print("  python extract_requirements.py my_script.py custom_requirements.txt")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else 'requirements.txt'
    
    if not Path(input_file).exists():
        print(f"❌ File not found: {input_file}")
        sys.exit(1)
    
    create_requirements(input_file, output_file)
