/*
 * _wasisocket - Python C Extension for WASI Socket Functions
 *
 * This extension wraps the custom WASI socket functions implemented in the
 * zig-wasm-cpython runtime, exposing them to Python code.
 *
 * WASI Functions Wrapped:
 *   - sock_open: Create a new socket
 *   - sock_resolve: DNS resolution
 *   - sock_connect: Connect to remote address
 *   - sock_send: Send data on socket
 *   - sock_recv: Receive data from socket
 *   - sock_close: Close socket
 *
 * Build: This module must be compiled as part of CPython WASI build
 */

#include <Python.h>
#include <stdint.h>

/* ============================================================================
 * WASI Socket Function Imports
 * ============================================================================
 * These functions are provided by the WASM runtime (zig-wasm-cpython).
 * They are imported from the wasi_snapshot_preview1 module namespace.
 */

__attribute__((import_module("wasi_snapshot_preview1")))
__attribute__((import_name("sock_open")))
int32_t wasi_sock_open(int32_t af, int32_t socktype, int32_t* fd_ptr);

__attribute__((import_module("wasi_snapshot_preview1")))
__attribute__((import_name("sock_resolve")))
int32_t wasi_sock_resolve(
    int32_t hostname_ptr,
    int32_t hostname_len,
    int32_t port,
    int32_t addrs_ptr,
    int32_t addrs_len,
    int32_t* count_ptr
);

__attribute__((import_module("wasi_snapshot_preview1")))
__attribute__((import_name("sock_connect")))
int32_t wasi_sock_connect(int32_t sock_fd, int32_t addr_ptr);

__attribute__((import_module("wasi_snapshot_preview1")))
__attribute__((import_name("sock_send")))
int32_t wasi_sock_send(
    int32_t sock_fd,
    int32_t buf_ptr,
    int32_t buf_len,
    int32_t* sent_ptr
);

__attribute__((import_module("wasi_snapshot_preview1")))
__attribute__((import_name("sock_recv")))
int32_t wasi_sock_recv(
    int32_t sock_fd,
    int32_t buf_ptr,
    int32_t buf_len,
    int32_t* recvd_ptr
);

__attribute__((import_module("wasi_snapshot_preview1")))
__attribute__((import_name("sock_close")))
int32_t wasi_sock_close(int32_t sock_fd);

/* ============================================================================
 * Constants
 * ============================================================================ */

#define AF_INET 2
#define AF_INET6 10
#define SOCK_STREAM 1
#define SOCK_DGRAM 2

#define ADDR_STRUCT_SIZE 19  // 1 (family) + 2 (port) + 16 (address)
#define MAX_RESOLVE_ADDRS 10

/* ============================================================================
 * Helper Functions
 * ============================================================================ */

static PyObject* socket_error_from_errno(int err) {
    if (err == 0) {
        Py_RETURN_NONE;
    }
    errno = err;
    return PyErr_SetFromErrno(PyExc_OSError);
}

/* ============================================================================
 * Python Function: sock_open(af, socktype) -> fd
 * ============================================================================ */
static PyObject* py_sock_open(PyObject* self, PyObject* args) {
    int af, socktype;
    int32_t fd;
    
    if (!PyArg_ParseTuple(args, "ii", &af, &socktype)) {
        return NULL;
    }
    
    int32_t result = wasi_sock_open(af, socktype, &fd);
    
    if (result != 0) {
        errno = result;
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    
    return PyLong_FromLong(fd);
}

/* ============================================================================
 * Python Function: sock_resolve(hostname, port) -> [(family, port, addr_bytes), ...]
 * ============================================================================ */
static PyObject* py_sock_resolve(PyObject* self, PyObject* args) {
    const char* hostname;
    Py_ssize_t hostname_len;
    int port;
    
    if (!PyArg_ParseTuple(args, "s#i", &hostname, &hostname_len, &port)) {
        return NULL;
    }
    
    // Allocate buffer for addresses (19 bytes each, max 10 addresses)
    unsigned char addrs_buf[ADDR_STRUCT_SIZE * MAX_RESOLVE_ADDRS];
    int32_t count = 0;
    
    int32_t result = wasi_sock_resolve(
        (int32_t)(uintptr_t)hostname,
        (int32_t)hostname_len,
        port,
        (int32_t)(uintptr_t)addrs_buf,
        MAX_RESOLVE_ADDRS,
        &count
    );
    
    if (result != 0) {
        errno = result;
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    
    // Build list of addresses
    PyObject* addr_list = PyList_New(count);
    if (!addr_list) {
        return NULL;
    }
    
    for (int32_t i = 0; i < count; i++) {
        unsigned char* addr_ptr = &addrs_buf[i * ADDR_STRUCT_SIZE];
        
        int family = addr_ptr[0];
        int addr_port = (addr_ptr[1] << 8) | addr_ptr[2];  // Big-endian u16
        
        // Extract address bytes (4 for IPv4, 16 for IPv6)
        int addr_len = (family == AF_INET) ? 4 : 16;
        PyObject* addr_bytes = PyBytes_FromStringAndSize((char*)&addr_ptr[3], addr_len);
        if (!addr_bytes) {
            Py_DECREF(addr_list);
            return NULL;
        }
        
        PyObject* addr_tuple = Py_BuildValue("(iiO)", family, addr_port, addr_bytes);
        Py_DECREF(addr_bytes);
        
        if (!addr_tuple) {
            Py_DECREF(addr_list);
            return NULL;
        }
        
        PyList_SET_ITEM(addr_list, i, addr_tuple);
    }
    
    return addr_list;
}

/* ============================================================================
 * Python Function: sock_connect(fd, family, port, addr_bytes) -> None
 * ============================================================================ */
static PyObject* py_sock_connect(PyObject* self, PyObject* args) {
    int fd, family, port;
    const char* addr_bytes;
    Py_ssize_t addr_len;
    
    if (!PyArg_ParseTuple(args, "iiis#", &fd, &family, &port, &addr_bytes, &addr_len)) {
        return NULL;
    }
    
    // Validate address length
    if ((family == AF_INET && addr_len != 4) || 
        (family == AF_INET6 && addr_len != 16)) {
        PyErr_SetString(PyExc_ValueError, "Invalid address length for family");
        return NULL;
    }
    
    // Build address structure: family (1) + port (2) + addr (4 or 16)
    unsigned char addr_struct[ADDR_STRUCT_SIZE];
    addr_struct[0] = (unsigned char)family;
    addr_struct[1] = (port >> 8) & 0xFF;  // Big-endian port
    addr_struct[2] = port & 0xFF;
    memcpy(&addr_struct[3], addr_bytes, addr_len);
    
    // Zero out remaining bytes for IPv4
    if (family == AF_INET) {
        memset(&addr_struct[7], 0, 12);
    }
    
    int32_t result = wasi_sock_connect(fd, (int32_t)(uintptr_t)addr_struct);
    
    if (result != 0) {
        errno = result;
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    
    Py_RETURN_NONE;
}

/* ============================================================================
 * Python Function: sock_send(fd, data) -> bytes_sent
 * ============================================================================ */
static PyObject* py_sock_send(PyObject* self, PyObject* args) {
    int fd;
    const char* data;
    Py_ssize_t data_len;
    
    if (!PyArg_ParseTuple(args, "is#", &fd, &data, &data_len)) {
        return NULL;
    }
    
    int32_t sent = 0;
    
    int32_t result = wasi_sock_send(
        fd,
        (int32_t)(uintptr_t)data,
        (int32_t)data_len,
        &sent
    );
    
    if (result != 0) {
        errno = result;
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    
    return PyLong_FromLong(sent);
}

/* ============================================================================
 * Python Function: sock_recv(fd, bufsize) -> bytes
 * ============================================================================ */
static PyObject* py_sock_recv(PyObject* self, PyObject* args) {
    int fd, bufsize;
    
    if (!PyArg_ParseTuple(args, "ii", &fd, &bufsize)) {
        return NULL;
    }
    
    if (bufsize <= 0) {
        PyErr_SetString(PyExc_ValueError, "bufsize must be positive");
        return NULL;
    }
    
    // Allocate buffer for received data
    PyObject* result_bytes = PyBytes_FromStringAndSize(NULL, bufsize);
    if (!result_bytes) {
        return NULL;
    }
    
    char* buffer = PyBytes_AS_STRING(result_bytes);
    int32_t recvd = 0;
    
    int32_t result = wasi_sock_recv(
        fd,
        (int32_t)(uintptr_t)buffer,
        bufsize,
        &recvd
    );
    
    if (result != 0) {
        Py_DECREF(result_bytes);
        errno = result;
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    
    // Resize bytes object to actual received size
    if (recvd < bufsize) {
        _PyBytes_Resize(&result_bytes, recvd);
    }
    
    return result_bytes;
}

/* ============================================================================
 * Python Function: sock_close(fd) -> None
 * ============================================================================ */
static PyObject* py_sock_close(PyObject* self, PyObject* args) {
    int fd;
    
    if (!PyArg_ParseTuple(args, "i", &fd)) {
        return NULL;
    }
    
    int32_t result = wasi_sock_close(fd);
    
    if (result != 0) {
        errno = result;
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    
    Py_RETURN_NONE;
}

/* ============================================================================
 * Module Method Table
 * ============================================================================ */
static PyMethodDef WasiSocketMethods[] = {
    {
        "sock_open",
        py_sock_open,
        METH_VARARGS,
        "sock_open(af, socktype) -> fd\n\n"
        "Create a new socket.\n\n"
        "Args:\n"
        "    af (int): Address family (2=AF_INET, 10=AF_INET6)\n"
        "    socktype (int): Socket type (1=SOCK_STREAM/TCP, 2=SOCK_DGRAM/UDP)\n\n"
        "Returns:\n"
        "    int: Socket file descriptor\n\n"
        "Raises:\n"
        "    OSError: If socket creation fails"
    },
    {
        "sock_resolve",
        py_sock_resolve,
        METH_VARARGS,
        "sock_resolve(hostname, port) -> [(family, port, addr_bytes), ...]\n\n"
        "Resolve a hostname to IP addresses (DNS lookup).\n\n"
        "Args:\n"
        "    hostname (str): Hostname to resolve\n"
        "    port (int): Port number\n\n"
        "Returns:\n"
        "    list: List of tuples (family, port, addr_bytes) where:\n"
        "        - family: int (2=IPv4, 10=IPv6)\n"
        "        - port: int\n"
        "        - addr_bytes: bytes (4 bytes for IPv4, 16 for IPv6)\n\n"
        "Raises:\n"
        "    OSError: If DNS resolution fails"
    },
    {
        "sock_connect",
        py_sock_connect,
        METH_VARARGS,
        "sock_connect(fd, family, port, addr_bytes) -> None\n\n"
        "Connect a socket to a remote address.\n\n"
        "Args:\n"
        "    fd (int): Socket file descriptor\n"
        "    family (int): Address family (2=AF_INET, 10=AF_INET6)\n"
        "    port (int): Port number\n"
        "    addr_bytes (bytes): IP address (4 bytes for IPv4, 16 for IPv6)\n\n"
        "Raises:\n"
        "    OSError: If connection fails"
    },
    {
        "sock_send",
        py_sock_send,
        METH_VARARGS,
        "sock_send(fd, data) -> bytes_sent\n\n"
        "Send data on a connected socket.\n\n"
        "Args:\n"
        "    fd (int): Socket file descriptor\n"
        "    data (bytes): Data to send\n\n"
        "Returns:\n"
        "    int: Number of bytes sent\n\n"
        "Raises:\n"
        "    OSError: If send fails"
    },
    {
        "sock_recv",
        py_sock_recv,
        METH_VARARGS,
        "sock_recv(fd, bufsize) -> bytes\n\n"
        "Receive data from a connected socket.\n\n"
        "Args:\n"
        "    fd (int): Socket file descriptor\n"
        "    bufsize (int): Maximum number of bytes to receive\n\n"
        "Returns:\n"
        "    bytes: Received data\n\n"
        "Raises:\n"
        "    OSError: If receive fails"
    },
    {
        "sock_close",
        py_sock_close,
        METH_VARARGS,
        "sock_close(fd) -> None\n\n"
        "Close a socket.\n\n"
        "Args:\n"
        "    fd (int): Socket file descriptor\n\n"
        "Raises:\n"
        "    OSError: If close fails"
    },
    {NULL, NULL, 0, NULL}  // Sentinel
};

/* ============================================================================
 * Module Definition
 * ============================================================================ */
static struct PyModuleDef wasisocketmodule = {
    PyModuleDef_HEAD_INIT,
    "_wasisocket",
    "Low-level WASI socket interface.\n\n"
    "This module provides direct access to WASI socket functions\n"
    "implemented by the zig-wasm-cpython runtime. For a higher-level\n"
    "interface, use the 'wasisocket' wrapper module.\n\n"
    "Constants:\n"
    "    AF_INET (int): IPv4 address family (2)\n"
    "    AF_INET6 (int): IPv6 address family (10)\n"
    "    SOCK_STREAM (int): TCP socket type (1)\n"
    "    SOCK_DGRAM (int): UDP socket type (2)",
    -1,
    WasiSocketMethods
};

/* ============================================================================
 * Module Initialization
 * ============================================================================ */
PyMODINIT_FUNC PyInit__wasisocket(void) {
    PyObject* m = PyModule_Create(&wasisocketmodule);
    if (m == NULL) {
        return NULL;
    }
    
    // Add constants
    PyModule_AddIntConstant(m, "AF_INET", AF_INET);
    PyModule_AddIntConstant(m, "AF_INET6", AF_INET6);
    PyModule_AddIntConstant(m, "SOCK_STREAM", SOCK_STREAM);
    PyModule_AddIntConstant(m, "SOCK_DGRAM", SOCK_DGRAM);
    
    return m;
}
