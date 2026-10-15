# httpd

An HTTP server written in Jai.

Two modules have been developed for this project: bindings for LibreSSL and the HTTP server itself.

## Building

In `modules/LibreSSL` run `jai build.jai` and then `jai generate.jai`. You need a C compiler, CMake and Ninja. Then run `jai first.jai - release` in the root folder.
