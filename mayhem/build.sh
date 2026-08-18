#!/usr/bin/env bash
#
# mayhem/build.sh — build HTMLDOC's fuzz harness(es) + the functional-test binaries.
#
# Layout produced (target names match the historical Mayhem project targets):
#   /html_fuzzer                 libFuzzer harness over htmlReadFile()  (Mayhem target: htmldoc)
#   /html_fuzzer-standalone      run-once reproducer for the parser harness
#   /fuzz_hd_strlcat             libFuzzer harness over hd_strlcat()    (Mayhem target: hd-strlcat)
#   /fuzz_hd_strlcat-standalone  run-once reproducer for the hd_strlcat harness
#   /mayhem/hd_strlcat_kat       known-answer check used by mayhem/test.sh
#   htmldoc/htmldoc              normal-flags CLI binary  (used by mayhem/test.sh)
#   htmldoc/testhtml             normal-flags parser tool (used by mayhem/test.sh)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

IMG_LIBS="-ljpeg -lpng -lz -lm"

# --- 1) Generate config.h + Makedefs (autotools), no GUI (no FLTK), no CUPS. -----------------
env -u CFLAGS -u CXXFLAGS -u LDFLAGS ./configure --without-gui CC="$CC" CXX="$CXX" >/tmp/configure.log 2>&1 \
  || { echo "configure failed"; tail -40 /tmp/configure.log; exit 1; }

# --- 2) Build the functional-test binaries with the project's NORMAL flags (clean build). ----
#     These are what mayhem/test.sh RUNS; keep them uninstrumented so the oracle can't
#     false-fail on benign UB.  Append $COVERAGE_FLAGS (empty by default).
make -j"$MAYHEM_JOBS" OPTIM="-O2 $COVERAGE_FLAGS" >/tmp/make.log 2>&1 \
  || { echo "make (test binaries) failed"; tail -60 /tmp/make.log; exit 1; }
test -x htmldoc/htmldoc  || { echo "missing htmldoc/htmldoc"; exit 1; }
test -x htmldoc/testhtml || { echo "missing htmldoc/testhtml"; exit 1; }

# --- 3) Compile the sanitized project objects for the fuzz harness (separate object dir). -----
#     CRITICAL: add SanitizerCoverage (-fsanitize=fuzzer-no-link) to EVERY fuzzed TU so libFuzzer
#     sees the parser's edges. ASan/UBSan alone insert NO edge guards — without this the harness
#     runs the parser but reports ~0 edges (0-edge harness = REWORK). Link with -fsanitize=fuzzer.
COV_FLAGS="-fsanitize=fuzzer-no-link"
OBJ="$SRC/mayhem-obj"
rm -rf "$OBJ"; mkdir -p "$OBJ"

CSRCS="file.c md5.c snprintf.c string.c"
CXXSRCS="htmllib.cxx image.cxx iso8859.cxx progress.cxx toc.cxx util.cxx"

cd "$SRC/htmldoc"
for s in $CSRCS; do
  $CC  $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS -I.. -I. -c "$s" -o "$OBJ/${s%.c}.o"
done
for s in $CXXSRCS; do
  $CXX $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS -I.. -I. -c "$s" -o "$OBJ/${s%.cxx}.o"
done
cd "$SRC"

SAN_OBJS=$(ls "$OBJ"/*.o)

# --- 4) Link the libFuzzer harness (harness + project both coverage-instrumented). ----------
$CXX $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
  -I"$SRC" -I"$SRC/htmldoc" \
  "$SRC/mayhem/html_fuzzer.cxx" $SAN_OBJS $IMG_LIBS \
  -o "$SRC/html_fuzzer"

# --- 5) Standalone run-once reproducer (no libFuzzer runtime). --------------------------------
#     Compile the LLVM standalone driver as C so its LLVMFuzzerTestOneInput ref keeps C linkage.
#     The cov objects' sancov hooks resolve to the sanitizer_common defaults (ASan runtime).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
  -I"$SRC" -I"$SRC/htmldoc" \
  "$SRC/mayhem/html_fuzzer.cxx" /tmp/standalone_main.o $SAN_OBJS $IMG_LIBS \
  -o "$SRC/html_fuzzer-standalone"

# --- 6) hd-strlcat target: force-build the portable hd_strlcat(). ----------------------------
#     hd_strlcat lives behind `#ifndef HAVE_STRLCAT` in htmldoc/string.c; modern glibc provides
#     strlcat, so configure sets HAVE_STRLCAT and the portable impl is compiled out. Strip that
#     one define from a COPY of the generated config.h so the portable function stays linkable —
#     this preserves the historical `hd-strlcat` Mayhem target (do NOT drop the target name).
NOSTR="$SRC/mayhem-nostrlcat"
rm -rf "$NOSTR"; mkdir -p "$NOSTR"
sed '/#[[:space:]]*define[[:space:]]\+HAVE_STRLCAT[[:space:]]/d' "$SRC/config.h" > "$NOSTR/config.h"
$CC $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS -I"$NOSTR" -I"$SRC" -I"$SRC/htmldoc" \
  -c "$SRC/htmldoc/string.c" -o "$OBJ/string_nostrlcat.o"

$CXX $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
  "$SRC/mayhem/fuzz_hd_strlcat.cxx" "$OBJ/string_nostrlcat.o" \
  -o "$SRC/fuzz_hd_strlcat"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
  "$SRC/mayhem/fuzz_hd_strlcat.cxx" /tmp/standalone_main.o "$OBJ/string_nostrlcat.o" \
  -o "$SRC/fuzz_hd_strlcat-standalone"

# Known-answer check binary for mayhem/test.sh (asserts hd_strlcat truncation semantics).
# Built with NORMAL flags (a normal-flags copy of the portable string.o), matching the
# uninstrumented functional-test binaries above.
cat > /tmp/hd_strlcat_kat.c <<'KAT'
#include <stdio.h>
#include <string.h>
extern size_t hd_strlcat(char *, const char *, size_t);
int main(void) {
  char d[8] = "ab";
  size_t r = hd_strlcat(d, "cdefghij", sizeof(d));   /* truncating concat into an 8-byte buffer */
  /* htmldoc's hd_strlcat returns the TRUNCATED length and keeps dst NUL-terminated. */
  return (r == 7 && strcmp(d, "abcdefg") == 0) ? 0 : 1;
}
KAT
$CC $DEBUG_FLAGS -O2 -I"$NOSTR" -I"$SRC" -I"$SRC/htmldoc" \
  -c "$SRC/htmldoc/string.c" -o /tmp/string_nostrlcat_norm.o
$CC $DEBUG_FLAGS /tmp/hd_strlcat_kat.c /tmp/string_nostrlcat_norm.o -o "$SRC/hd_strlcat_kat"

test -x "$SRC/fuzz_hd_strlcat"  || { echo "missing fuzz_hd_strlcat"; exit 1; }
test -x "$SRC/hd_strlcat_kat"   || { echo "missing hd_strlcat_kat"; exit 1; }

echo "build.sh OK: $SRC/html_fuzzer $SRC/fuzz_hd_strlcat $SRC/html_fuzzer-standalone $SRC/fuzz_hd_strlcat-standalone htmldoc/htmldoc htmldoc/testhtml"
