#!/bin/bash
set -euo pipefail

# build-sqlcipher.sh — build SQLCipher (encrypted SQLite) for the browser
# password manager.
#
# SQLCipher is a drop-in fork of SQLite: same public API and sqlite3.h header,
# plus `PRAGMA key` which transparently AES-256-encrypts the whole database
# file (PBKDF2 key derivation + per-DB salt handled internally). The browser's
# CredentialStore compiles unchanged against either sqlite3 or sqlcipher; this
# package is what makes its `PRAGMA key` actually encrypt on-device.
#
# Built NATIVE (aarch64-on-aarch64) like the rest of the engine and installed
# into ${WPE_PREFIX}. The OpenSSL crypto backend links libcrypto.so.3, which
# the SFOS 5.1 base system provides (verified in the 5.1.0.11 sysroot), so the
# host-built lib runs forward-compatibly on-device. build-rpms-native.sh stages
# it into the `libsqlcipher` RPM; build-ui.sh links the browser against it via
# WPE_SFOS_PREFIX.
#
# Header:    ${WPE_PREFIX}/include/sqlcipher/sqlite3.h
# Library:   ${WPE_PREFIX}/lib/libsqlcipher.so.0
# pkgconfig: ${WPE_PREFIX}/lib/pkgconfig/sqlcipher.pc

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

echo ""
echo "--- Building SQLCipher ${SQLCIPHER_VERSION} (encrypted SQLite) ---"

_stamp="${WPE_PREFIX}/lib/.sqlcipher-version"
if [ -f "${WPE_PREFIX}/lib/libsqlcipher.so" ] \
   && [ "$(cat "${_stamp}" 2>/dev/null || true)" = "${SQLCIPHER_VERSION}" ]; then
    echo "  SQLCipher already built (${SQLCIPHER_VERSION})."
    exit 0
fi

cd "${WORK}"
_src="sqlcipher-${SQLCIPHER_VERSION}"
if [ ! -d "${_src}" ]; then
    echo "  Downloading SQLCipher ${SQLCIPHER_VERSION}..."
    wget -q "https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v${SQLCIPHER_VERSION}.tar.gz" \
        -O "/tmp/${_src}.tar.gz"
    tar -xf "/tmp/${_src}.tar.gz" -C "${WORK}"
    rm -f "/tmp/${_src}.tar.gz"
fi

cd "${_src}"
# Clean any prior configure state so a re-run with a bumped version is sane.
[ -f Makefile ] && make distclean >/dev/null 2>&1 || true

# SQLCIPHER_CRYPTO_OPENSSL selects the libcrypto backend; SQLITE_HAS_CODEC turns
# on the encryption codec; TEMP_STORE=2 keeps temp tables in memory so plaintext
# never spills to disk. --disable-tcl skips the Tcl bindings (tclsh is still
# needed at build time to generate the amalgamation).
CC="ccache gcc" \
CFLAGS="-O2 -fPIC -DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 -DSQLCIPHER_CRYPTO_OPENSSL -DSQLITE_ENABLE_COLUMN_METADATA" \
LDFLAGS="-lcrypto" \
./configure \
    --prefix="${WPE_PREFIX}" \
    --libdir="${WPE_PREFIX}/lib" \
    --includedir="${WPE_PREFIX}/include/sqlcipher" \
    --enable-tempstore=yes \
    --disable-tcl \
    --disable-static \
    --disable-static-shell

make -j"${NPROC}"
make install

printf '%s\n' "${SQLCIPHER_VERSION}" > "${_stamp}"
echo "  SQLCipher installed: $(ls "${WPE_PREFIX}/lib/"libsqlcipher.so.* 2>/dev/null | head -1)"
