/*
 * In-process libFuzzer harness for HTMLDOC's portable hd_strlcat().
 *
 * Continues the historical `hd-strlcat` Mayhem target. hd_strlcat() lives in
 * htmldoc/string.c behind `#ifndef HAVE_STRLCAT`; modern glibc provides
 * strlcat, so build.sh compiles a dedicated string.o with HAVE_STRLCAT
 * stripped from a copy of the generated config.h to keep the portable
 * implementation linkable.
 *
 * The harness derives a bounded destination capacity and a pre-filled,
 * NUL-terminated destination prefix from the first input byte, and feeds the
 * remaining bytes as the NUL-terminated source string — exercising the
 * no-room, truncation, and full-copy paths without any harness-induced UB.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern "C" size_t hd_strlcat(char *dst, const char *src, size_t size);

#define DST_CAP 64

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size < 1)
    return 0;

  size_t cap    = (size_t)(data[0] % DST_CAP) + 1;  /* 1..DST_CAP           */
  size_t prefix = (size_t)(data[0] / 4) % cap;      /* < cap, NUL fits      */

  char dst[DST_CAP + 1];
  memset(dst, 'A', prefix);
  dst[prefix] = '\0';

  size_t slen = size - 1;
  char *src = (char *)malloc(slen + 1);
  if (!src)
    return 0;
  memcpy(src, data + 1, slen);
  src[slen] = '\0';

  size_t r = (size_t)hd_strlcat(dst, src, cap);

  /* The result must stay NUL-terminated inside cap and report the new length. */
  if (r >= (size_t)DST_CAP + 1 || dst[r > cap - 1 ? cap - 1 : r] != '\0')
    __builtin_trap();

  free(src);
  return 0;
}
