# httpd

An HTTP server written in Jai. The aim is to make a very fast and very secure HTTP server that is easy to modify and extend.

## Modules

These modules have been developed:

- Html_Template - HTML templating engine
- Http_Server - The HTTP server module
- LibreSSL - Bindings to LibreSSL

These modules can be used in other projects but the Http_Server module depends on the LibreSSL module.

## Features

- HTTP/1.1
- Web Sockets
- SSE
- TLS

## Compiling

```
cd modules/LibreSSL
jai build.jai
jai generate.jai
cd ../..
jai first.jai - release
```

`cmake` and `ninja` must be installed for compiling LibreSSL.

## Cross Compiling to Linux ARM64

You have to compile LibreSSL manually by doing the same thing as `build.jai` does and then run `jai generate.jai - arm64`. Compile httpd with `jai first.jai - release arm64`. `aarch64-linux-gnu-gcc` must be installed. You also need [raspberry-jai](https://github.com/TheGag96/raspberry-jai).

## Performance

On my computer this HTTP server is a bit faster than nginx but more extensive testing is needed.

## Operating Systems

The HTTP server supports Linux, macOS and Windows but the performance is not very good on Windows. The primary aim is to have it running an working on Windows but not have it be super fast.

On macOS we use `kqueue`, on Linux we use `epoll` and on Windows we use `Windows Sockets 2`.