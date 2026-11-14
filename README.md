# httpd

An HTTP server written in Jai. The aim is to make a very fast and very secure HTTP server that is easy to modify and extend.

## Modules

Two modules have been developed:

- Http_Server - The HTTP server module
- LibreSSL - Bindings to LibreSSL

These modules can be used in other projects but the Http_Server module depends on the LibreSSL module.

## Features

- HTTP/1.1
- Web Sockets
- SSE
- TLS

## Performance

On my computer this HTTP server is a bit faster than nginx but more extensive testing is needed.

## Operating Systems

The HTTP server supports Linux, macOS and Windows but the performance is not very good on Windows. The primary aim is to have it running an working on Windows but not have it be super fast.

On macOS we use `kqueue`, on Linux we use `epoll` and on Windows we use `Windows Sockets 2`.

## TODO

- Add Gzip and/or Brotli support.
- Add an HTML templating engine module.