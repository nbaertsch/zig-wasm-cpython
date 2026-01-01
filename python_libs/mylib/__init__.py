"""
My Custom Library - A demonstration library for WASM CPython

This library demonstrates:
- Multi-module Python libraries
- Internal dependencies
- Bytecode compilation
- WASM execution
"""

__version__ = "1.0.0"
__author__ = "WASM Python Team"

from .math_utils import add, multiply, factorial
from .string_utils import reverse_string, capitalize_words
from .data_processor import process_data, DataProcessor

__all__ = [
    'add', 'multiply', 'factorial',
    'reverse_string', 'capitalize_words',
    'process_data', 'DataProcessor'
]
