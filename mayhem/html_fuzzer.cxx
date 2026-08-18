/*
 * In-process libFuzzer harness for HTMLDOC's HTML parser.
 *
 * Drives htmlReadFile() over fuzzer-supplied bytes (the same entry point the
 * upstream `testhtml` tool exercises), then builds the table of contents and
 * frees both trees so the harness is leak-clean under ASan.
 *
 * `_HTMLDOC_CXX_` is defined here (exactly as upstream's testhtml.cxx does) so
 * the book-level globals declared in htmldoc.h are DEFINED in this translation
 * unit, satisfying the references from the linked COMMONOBJS.
 */

#define _HTMLDOC_CXX_
#include "htmldoc.h"

#include <stdio.h>
#include <stdint.h>
#include <stddef.h>

/* prefs_load/prefs_save live in gui.cxx which we do not link (no GUI). */
void prefs_load(void) { }
void prefs_save(void) { }

extern "C" int LLVMFuzzerInitialize(int * /*argc*/, char *** /*argv*/)
{
  const char *data_dir = getenv("HTMLDOC_DATA");
  _htmlData = data_dir && *data_dir ? data_dir : "/mayhem";
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  FILE *fp = fmemopen((void *)data, size, "rb");
  if (!fp)
    return 0;

  tree_t *doc = htmlReadFile(NULL, fp, ".");
  fclose(fp);

  if (doc != NULL)
  {
    tree_t *toc = toc_build(doc);
    if (toc != NULL)
      htmlDeleteTree(toc);
    htmlDeleteTree(doc);
  }

  return 0;
}
