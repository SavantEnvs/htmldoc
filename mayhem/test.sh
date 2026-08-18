#!/usr/bin/env bash
#
# mayhem/test.sh — AUTHORED behavioral oracle for HTMLDOC.
#
# HTMLDOC ships NO automated assertion suite upstream (its CI only compiles; `testsuite/`
# is a set of sample docs + a timing benchmark, not an assertion suite). So this oracle is
# AUTHORED: it drives the real, upstream code paths (the `testhtml` parser tool and the
# `htmldoc` HTML->PDF converter, both built by mayhem/build.sh with normal flags) and asserts
# concrete OUTPUT — canonical reparse tokens, table-of-contents generation, and valid PDF
# structure. A no-op / exit(0) sabotage of the program produces no output and FAILS every check.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

TESTHTML="$SRC/htmldoc/testhtml"
HTMLDOC="$SRC/htmldoc/htmldoc"
export HTMLDOC_DATA="$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

[ -x "$TESTHTML" ] || { echo "FATAL: $TESTHTML missing (build.sh bug)"; emit_ctrf htmldoc-oracle 0 1; exit 1; }
[ -x "$HTMLDOC" ]  || { echo "FATAL: $HTMLDOC missing (build.sh bug)"; emit_ctrf htmldoc-oracle 0 1; exit 1; }

PASS=0; FAIL=0
pass() { echo "ok   - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

W=/tmp/htmldoc-oracle; rm -rf "$W"; mkdir -p "$W"
"$TESTHTML" testsuite/list.html         > "$W/list.out"  2>/dev/null || true
"$TESTHTML" testsuite/table-simple.html > "$W/table.out" 2>/dev/null || true

# 1) The parser reparses an unordered + ordered list into canonical markup.
if grep -q "<ul>" "$W/list.out" && grep -q "<ol>" "$W/list.out" && grep -q "<li>List 1</li>" "$W/list.out"; then
  pass "parse-list-ul-ol"; else fail "parse-list-ul-ol"; fi
# 2) toc_build() runs and emits the table-of-contents section.
if grep -q -- "---- TABLE OF CONTENTS ----" "$W/list.out"; then pass "toc-section-emitted"; else fail "toc-section-emitted"; fi
# 3) Headings get generated NAME anchors (toc anchoring of parsed headings).
if grep -q '<a NAME="1">List Tests</a>' "$W/list.out"; then pass "heading-name-anchor"; else fail "heading-name-anchor"; fi
# 4) Table structure is parsed: BORDER attribute, header + data cells.
if grep -q '<table BORDER="1">' "$W/table.out" && grep -q "<th>Heading 1</th>" "$W/table.out" && grep -q "<td>Cell 1,1</td>" "$W/table.out"; then
  pass "parse-table-cells"; else fail "parse-table-cells"; fi

# 5) Full HTML->PDF pipeline produces a structurally valid PDF.
rm -f "$W/basic.pdf"
"$HTMLDOC" --quiet --webpage -f "$W/basic.pdf" testsuite/basic.html >/dev/null 2>&1 || true
if [ -s "$W/basic.pdf" ] && head -c 5 "$W/basic.pdf" | grep -q "%PDF-" && grep -qa "%%EOF" "$W/basic.pdf"; then
  pass "html2pdf-valid"; else fail "html2pdf-valid"; fi
# 6) Markdown input is converted through the markdown front-end into a valid PDF.
rm -f "$W/welcome.pdf"
"$HTMLDOC" --quiet --charset utf-8 --webpage -f "$W/welcome.pdf" testsuite/welcome.md >/dev/null 2>&1 || true
if [ -s "$W/welcome.pdf" ] && head -c 5 "$W/welcome.pdf" | grep -q "%PDF-"; then
  pass "md2pdf-valid"; else fail "md2pdf-valid"; fi

# 7) hd_strlcat known-answer test: truncating concat returns the truncated length and
#    keeps dst NUL-terminated (the portable impl behind the hd-strlcat target).
if [ -x "$SRC/hd_strlcat_kat" ] && "$SRC/hd_strlcat_kat"; then
  pass "hd-strlcat-kat"; else fail "hd-strlcat-kat"; fi

echo "----"
echo "passed=$PASS failed=$FAIL"
emit_ctrf "htmldoc-oracle" "$PASS" "$FAIL"
