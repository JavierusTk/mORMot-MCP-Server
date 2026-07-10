# Changelog

## Unreleased

### Fixed
- The stdio transport now decodes stdin as UTF-8 and writes `RawUtf8` bytes
  directly to stdout. Previously the Windows console code page could corrupt
  incoming Unicode and emit invalid JSONL bytes such as CP1252 `$97`.

### Added
- **TLS/HTTPS support** for HTTP transport
  - `--tls` flag to enable TLS with certificate files
  - `--cert=path` and `--key=path` to specify certificate and private key
  - `--key-password=pass` for encrypted private keys
  - `--tls-self-signed` for zero-config development HTTPS (auto-generated certificate)
  - Console and log output reflect `https://` when TLS is active
  - Uses mORMot2's native TLS support (SChannel on Windows, OpenSSL on Linux)
