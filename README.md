# httpd

An HTTP server written in Jai.

Two modules have been developed for this project: bindings for LibreSSL and the HTTP server itself.

## Building

In `modules/LibreSSL`, run `jai build.jai` and then `jai generate.jai`. You need a C compiler, CMake, and Ninja.

Then run `jai first.jai - release` in the root folder.

## Usage

```sh
httpd -directory <path> [options]
```

### Options

- `-directory <path>`: Directory to serve (required).
- `-port <number>`: Port to listen on (default: 3000).
- `-certificate <path>`: Path to a TLS certificate in PEM format. Enables HTTPS.
- `-key <path>`: Path to a private key in PEM format. Optional if the certificate file contains the key.
- `-quiet`: Suppress logging.
- `-debug`: Enable debug features (such as `/stop`).
