# Embedded RAR reader

The app statically links the RAR and RAR5 readers from [libarchive 3.8.11](https://github.com/libarchive/libarchive/releases/tag/v3.8.11). The included C sources and public headers come from the upstream `libarchive/` directory. The build uses the Xcode toolchain and the public Apple iconv and zlib libraries. Running the reader requires no external program or network connection.

The [upstream source tarball](https://www.libarchive.org/downloads/libarchive-3.8.11.tar.xz) has SHA-256 `a3dc0872b1b39da34dc18ef1b944f0f11ffd37425d70ae04be679279f1cf43d2`. This matches the [upstream checksum](https://www.libarchive.org/downloads/libarchive-3.8.11.tar.xz.sums.txt) and the GitHub release asset digest. To reproduce the vendor tree, take each `src/` file and both public headers from the upstream `libarchive/` directory by basename and take `COPYING` from its root. The local change in `archive_read_support_format_rar.c` rejects PPMd dictionaries over 64 MiB before allocation, matching the upstream RAR5 dictionary limit. The limit applies to the decoder dictionary, independently of the expanded archive size. The legacy reader also lets sequential stored entries reach their final CRC check. The local change in `archive_read_support_format_rar5.c` verifies checksums on stored files using their actual output position and distinguishes an explicitly stored CRC of zero from a missing CRC. The public module map and Darwin configuration belong to this project.

`Scripts/build-mod-rar.sh` verifies the vendored files against `SHA256SUMS` and builds only the selected read API. Xcode supplies the platform and derived directory. For a native Mac smoke test run `Scripts/build-mod-rar.sh macos "$TMPDIR/pjdv-rar"`. Use `-IThirdParty/ModRAR/include` and link `libpjdvarchive.a`, `-liconv`, and `-lz`.

## Test archives

The three small fixtures are decoded copies of the same-named `.rar.uu` files from upstream `libarchive/test/`. They contain upstream test data. The following SHA-256 values cover uncompressed bytes in archive entry order.

| Fixture | Contents | SHA-256 |
| --- | --- | --- |
| `test_read_format_rar_subblock.rar` | RAR legacy, 20-byte `test.txt` | `5a5f16e01faf8adf92eb4499a2d3e93010c4b41dbb7f698f4a8466d9f58e6dd2` |
| `test_read_format_rar_compress_normal.rar` | RAR legacy compression, three regular files, a symbolic link and directories. The app import should reject the link. | `3f472759566c39c7be0bd8f07e7565a918983214842f9b2b01cf6de15fa31ee3` |
| `test_read_format_rar5_compressed.rar` | RAR5 compression, 1,200-byte `test.bin` | `588870a2dade35c2650fbb7898c9a9c7f21fce7c281198604e8d0c9737f2c375` |
