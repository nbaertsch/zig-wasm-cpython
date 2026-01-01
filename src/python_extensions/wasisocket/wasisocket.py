"""
wasisocket - High-level Python socket interface for WASI

This module provides a socket-like interface that wraps the low-level
_wasisocket C extension, making it easier to use WASI sockets from Python.

Example usage:
    >>> import wasisocket as socket
    >>> sock = socket.Socket(socket.AF_INET, socket.SOCK_STREAM)
    >>> sock.connect(('example.com', 80))
    >>> sock.send(b'GET / HTTP/1.1\\r\\nHost: example.com\\r\\n\\r\\n')
    >>> data = sock.recv(1024)
    >>> sock.close()
"""

import _wasisocket
from typing import Tuple, List, Optional

# Re-export constants - Address families
AF_INET = _wasisocket.AF_INET
AF_INET6 = _wasisocket.AF_INET6
SOCK_STREAM = _wasisocket.SOCK_STREAM
SOCK_DGRAM = _wasisocket.SOCK_DGRAM

# Socket option constants (for setsockopt/getsockopt compatibility)
SOL_SOCKET = 1
SO_REUSEADDR = 2
SO_KEEPALIVE = 9
IPPROTO_TCP = 6
TCP_NODELAY = 1

# Socket timeout constants (for compatibility with standard socket module)
_GLOBAL_DEFAULT_TIMEOUT = object()

__all__ = [
    'AF_INET', 'AF_INET6', 'SOCK_STREAM', 'SOCK_DGRAM',
    'SOL_SOCKET', 'SO_REUSEADDR', 'SO_KEEPALIVE', 'IPPROTO_TCP', 'TCP_NODELAY',
    'Socket', 'socket', 'getaddrinfo', 'create_connection', '_GLOBAL_DEFAULT_TIMEOUT',
    'getdefaulttimeout', 'setdefaulttimeout', 'has_ipv6',
    'error', 'timeout', 'gaierror', 'herror'
]


# Exception classes (for compatibility with standard socket module)
class error(OSError):
    """Base exception for socket errors"""
    pass


class timeout(error):
    """Socket timeout exception"""
    pass


class gaierror(error):
    """Exception for getaddrinfo errors"""
    pass


class herror(error):
    """Exception for host resolution errors"""
    pass


# Legacy alias
SocketError = error


class Socket:
    """
    High-level socket object wrapping WASI socket functions.
    
    This class provides a familiar socket-like interface while using
    the custom WASI socket functions under the hood.
    """
    
    def __init__(self, family: int = AF_INET, socktype: int = SOCK_STREAM):
        """
        Create a new socket.
        
        Args:
            family: Address family (AF_INET or AF_INET6)
            socktype: Socket type (SOCK_STREAM for TCP, SOCK_DGRAM for UDP)
        """
        self.family = family
        self.socktype = socktype
        self._fd: Optional[int] = None
        self._connected = False
        
        # Create the socket
        self._fd = _wasisocket.sock_open(family, socktype)
    
    def connect(self, address: Tuple[str, int]) -> None:
        """
        Connect to a remote address.
        
        Args:
            address: Tuple of (hostname, port)
        
        Raises:
            SocketError: If connection fails
        """
        if self._fd is None:
            raise SocketError("Socket is closed")
        
        if self._connected:
            raise SocketError("Socket is already connected")
        
        hostname, port = address
        
        # Resolve hostname to IP address
        addrs = _wasisocket.sock_resolve(hostname, port)
        if not addrs:
            raise gaierror(f"Cannot resolve hostname: {hostname}")
        
        # Try to connect to the first address
        # TODO: Implement fallback to other addresses on failure
        family, resolved_port, addr_bytes = addrs[0]
        
        try:
            _wasisocket.sock_connect(self._fd, family, resolved_port, addr_bytes)
            self._connected = True
        except OSError as e:
            raise error(f"Connection failed: {e}") from e
    
    def send(self, data: bytes) -> int:
        """
        Send data on the socket.
        
        Args:
            data: Bytes to send
        
        Returns:
            Number of bytes sent
        
        Raises:
            SocketError: If socket is not connected or send fails
        """
        if self._fd is None:
            raise SocketError("Socket is closed")
        
        if not self._connected:
            raise SocketError("Socket is not connected")
        
        if not isinstance(data, (bytes, bytearray)):
            raise TypeError("data must be bytes or bytearray")
        
        try:
            return _wasisocket.sock_send(self._fd, bytes(data))
        except OSError as e:
            raise SocketError(f"Send failed: {e}") from e
    
    def sendall(self, data: bytes) -> None:
        """
        Send all data on the socket.
        
        Blocks until all data is sent or an error occurs.
        
        Args:
            data: Bytes to send
        
        Raises:
            SocketError: If send fails
        """
        total_sent = 0
        data_len = len(data)
        
        while total_sent < data_len:
            sent = self.send(data[total_sent:])
            if sent == 0:
                raise SocketError("Connection closed during send")
            total_sent += sent
    
    def recv(self, bufsize: int = 4096) -> bytes:
        """
        Receive data from the socket.
        
        Args:
            bufsize: Maximum number of bytes to receive
        
        Returns:
            Received bytes (may be less than bufsize)
        
        Raises:
            SocketError: If socket is not connected or recv fails
        """
        if self._fd is None:
            raise SocketError("Socket is closed")
        
        if not self._connected:
            raise SocketError("Socket is not connected")
        
        try:
            return _wasisocket.sock_recv(self._fd, bufsize)
        except OSError as e:
            raise SocketError(f"Receive failed: {e}") from e
    
    def close(self) -> None:
        """
        Close the socket.
        
        After calling this, the socket cannot be used anymore.
        """
        if self._fd is not None:
            try:
                _wasisocket.sock_close(self._fd)
            except OSError:
                pass  # Ignore errors on close
            finally:
                self._fd = None
                self._connected = False
    
    def fileno(self) -> int:
        """
        Return the socket file descriptor.
        
        Returns:
            File descriptor number
        
        Raises:
            SocketError: If socket is closed
        """
        if self._fd is None:
            raise SocketError("Socket is closed")
        return self._fd
    
    def __enter__(self):
        """Context manager entry"""
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - ensures socket is closed"""
        self.close()
    
    def __del__(self):
        """Destructor - clean up socket"""
        self.close()
    
    def __repr__(self) -> str:
        status = "connected" if self._connected else "disconnected"
        if self._fd is None:
            status = "closed"
        return f"<Socket fd={self._fd} family={self.family} type={self.socktype} {status}>"


def getaddrinfo(host: str, port: int) -> List[Tuple[int, int, bytes]]:
    """
    Resolve hostname to addresses.
    
    Similar to socket.getaddrinfo() but simplified for WASI.
    
    Args:
        host: Hostname to resolve
        port: Port number
    
    Returns:
        List of tuples (family, port, addr_bytes)
    """
    return _wasisocket.sock_resolve(host, port)


def create_connection(address: Tuple[str, int], timeout: Optional[float] = None) -> Socket:
    """
    Convenience function to create and connect a socket.
    
    Similar to socket.create_connection() but for WASI sockets.
    
    Args:
        address: Tuple of (hostname, port)
        timeout: Currently ignored (WASI sockets are blocking)
    
    Returns:
        Connected Socket object
    
    Raises:
        SocketError: If connection fails
    """
    sock = Socket(AF_INET, SOCK_STREAM)
    try:
        sock.connect(address)
        return sock
    except:
        sock.close()
        raise


# Timeout management (for compatibility with standard socket module)
_default_timeout = _GLOBAL_DEFAULT_TIMEOUT

def getdefaulttimeout():
    """Get the default timeout value for new sockets."""
    return _default_timeout

def setdefaulttimeout(timeout):
    """Set the default timeout value for new sockets."""
    global _default_timeout
    _default_timeout = timeout

# IPv6 support check
has_ipv6 = True  # Assume IPv6 support for compatibility


# Example usage
if __name__ == "__main__":
    print("WASI Socket Module")
    print("=" * 60)
    print()
    print("Example: Connect to example.com:80")
    print()
    
    try:
        with Socket(AF_INET, SOCK_STREAM) as sock:
            print(f"Created socket: {sock}")
            
            print("Connecting to example.com:80...")
            sock.connect(('example.com', 80))
            print("Connected!")
            
            request = b"GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
            print(f"Sending {len(request)} bytes...")
            sock.send(request)
            
            print("Receiving response...")
            response = sock.recv(4096)
            print(f"Received {len(response)} bytes")
            print()
            print("First 200 bytes:")
            print(response[:200].decode('utf-8', errors='ignore'))
            
    except Exception as e:
        print(f"Error: {e}")
