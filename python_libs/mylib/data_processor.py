"""
Data processing utilities with internal dependencies
"""

from .math_utils import add, multiply
from .string_utils import capitalize_words

class DataProcessor:
    """Process various types of data"""
    
    def __init__(self, name="DataProcessor"):
        self.name = name
        self.processed_count = 0
    
    def process_numbers(self, numbers):
        """Process a list of numbers"""
        total = sum(numbers)
        product = 1
        for n in numbers:
            product = multiply(product, n)
        
        self.processed_count += 1
        return {
            'sum': total,
            'product': product,
            'count': len(numbers),
            'average': total / len(numbers) if numbers else 0
        }
    
    def process_strings(self, strings):
        """Process a list of strings"""
        capitalized = [capitalize_words(s) for s in strings]
        concatenated = ' '.join(strings)
        
        self.processed_count += 1
        return {
            'capitalized': capitalized,
            'concatenated': concatenated,
            'total_length': len(concatenated),
            'count': len(strings)
        }
    
    def get_stats(self):
        """Get processing statistics"""
        return {
            'name': self.name,
            'processed_count': self.processed_count
        }

def process_data(data):
    """
    Convenience function to process data based on type
    Uses internal dependencies
    """
    if isinstance(data, (list, tuple)):
        if all(isinstance(x, (int, float)) for x in data):
            # Numeric data
            processor = DataProcessor("NumericProcessor")
            return processor.process_numbers(data)
        elif all(isinstance(x, str) for x in data):
            # String data
            processor = DataProcessor("StringProcessor")
            return processor.process_strings(data)
    
    return {'error': 'Unsupported data type'}
