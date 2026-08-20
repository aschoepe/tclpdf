#!/bin/sh
#
# tclpdf - the full acceptance run: tests, examples, and the outside validators
#
#   tools/check.sh
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# "make test" answers whether the promises still hold. It cannot answer whether
# the FILES are still sound - that takes a reader which is not this package.
# Every defect listed below was found by exactly one tool and was invisible to
# the others:
#
#   qpdf            a duplicate /Resources key in two examples
#   veraPDF -f 3a   a form XObject without /Resources of its own (6.2.2)
#   veraPDF ua1     tagged content inside an artifact - -f 3a called it conforming
#   pdfinfo         missing word spaces at a line break - no profile sees those
#
# So the run is not "qpdf or veraPDF", it is all of them, and each against the
# right yardstick.
#
# The signed documents are the one case where the yardstick is not a profile
# but a second implementation of the same arithmetic: pdfsig recomputes the
# digest over the bytes /ByteRange names, and says whether the signature
# covers the whole file. Nothing on this side could catch a /ByteRange that is
# off by one - this side is what computed it.
#
# WHICH PROFILE a document is checked against is not a list kept here - a list
# goes stale the day someone adds an example. Each document says it itself, in
# its XMP: pdfaid:part and pdfaid:conformance. A document that claims nothing
# is checked by qpdf alone, which is the correct amount of checking for it.
#
# A missing tool is reported and skipped, never silently passed over - and the
# run says so in its summary, because "3 skipped" and "3 passed" must not look
# alike.

set -u

srcdir=`dirname "$0"`/..
cd "$srcdir" || exit 1

pass=0
fail=0
skip=0

report_fail() {
  echo "  FAIL  $1"
  fail=`expr $fail + 1`
}

report_pass() {
  echo "  ok    $1"
  pass=`expr $pass + 1`
}

report_skip() {
  echo "  SKIP  $1"
  skip=`expr $skip + 1`
}

have() {
  command -v "$1" >/dev/null 2>&1
}

echo "=== 1. the test suite, under every interpreter present ==="

# Both interpreters, because the package promises both. A run under one of them
# is half a run - and the half that is missing is the one where a Tcl 9 string
# is not a byte array.
for tclsh in tclsh8.6 tclsh9.0; do
  if have $tclsh; then
    out=`make test TCLSH_PROG=\`command -v $tclsh\` 2>&1 | grep "^all.tcl:"`
    echo "  $tclsh: $out"
    case "$out" in
      *"Failed	0") report_pass "tests under $tclsh" ;;
      *) report_fail "tests under $tclsh" ;;
    esac
  else
    report_skip "tests under $tclsh - interpreter not installed"
  fi
done

echo "=== 2. every example runs ==="

if make examples >/tmp/tclpdf-examples.$$ 2>&1; then
  count=`ls examples/out/*.pdf 2>/dev/null | wc -l | tr -d ' '`
  report_pass "$count documents written"
else
  report_fail "make examples - see /tmp/tclpdf-examples.$$"
  tail -5 /tmp/tclpdf-examples.$$
fi
rm -f /tmp/tclpdf-examples.$$

echo "=== 3. qpdf over every document ==="

# The exit code, never the output: "No syntax or stream encoding ERRORS found"
# contains the word a grep for "error" is looking for, so grepping reports every
# file as broken and the run looks thorough while checking nothing.
if have qpdf; then
  bad=""
  for f in examples/out/*.pdf; do
    # The encrypted example needs its password, and the password is the
    # point: without one qpdf refuses the file, which is checked right
    # after this loop rather than being papered over here.
    case `basename "$f"` in
      07.01-encryption.pdf) pw="--password=full" ;;
      *) pw="" ;;
    esac
    qpdf $pw --check "$f" >/dev/null 2>&1 || bad="$bad $f"
  done
  if test -f examples/out/07.01-encryption.pdf; then
    if qpdf --check examples/out/07.01-encryption.pdf >/dev/null 2>&1; then
      report_fail "qpdf read the encrypted example without a password"
    else
      report_pass "qpdf control: the encrypted example needs its password"
    fi
  fi
  if test -z "$bad"; then
    report_pass "qpdf: no complaint on any document"
  else
    report_fail "qpdf:$bad"
  fi

  # The control line. A check that never fails is not a check, and a validator
  # invoked wrongly passes everything - so hand it something that MUST fail.
  head -c 3000 examples/out/01.01-shapes.pdf > /tmp/tclpdf-broken.$$ 2>/dev/null
  if qpdf --check /tmp/tclpdf-broken.$$ >/dev/null 2>&1; then
    report_fail "qpdf accepted a truncated file - the check is not working"
  else
    report_pass "qpdf control: a truncated file is rejected"
  fi
  rm -f /tmp/tclpdf-broken.$$
else
  report_skip "qpdf not installed"
fi

echo "=== 4. veraPDF, each document against the profile it claims ==="

if have verapdf; then
  claimed=0
  for f in examples/out/*.pdf; do
    # XMP writes these either as attributes or as elements, and tclpdf uses the
    # element form - matching only one of the two finds nothing and looks like
    # "no document claims anything", which is why the count is checked below.
    part=`strings "$f" |
        grep -o 'pdfaid:part="[0-9]"\|<pdfaid:part>[0-9]<' |
        head -1 | tr -dc '0-9'`
    conf=`strings "$f" |
        grep -o 'pdfaid:conformance="[A-Z]"\|<pdfaid:conformance>[A-Z]<' |
        head -1 | tr -dc 'A-Z'`
    test -n "$part" || continue
    claimed=`expr $claimed + 1`
    flavour=`echo "$part$conf" | tr 'ABU' 'abu'`
    failed=`verapdf -f "$flavour" "$f" 2>/dev/null |
        sed -n 's/.*failedChecks="\([0-9]*\)".*/\1/p' | head -1`
    if test "$failed" = "0"; then
      report_pass "veraPDF -f $flavour `basename $f`"
    else
      report_fail "veraPDF -f $flavour `basename $f`: ${failed:-no answer} failed checks"
    fi
  done
  test $claimed -gt 0 || report_fail "no document claims a PDF/A level - did the XMP change?"

  # PDF/UA, the same rule as above: a document is held to what it CLAIMS.
  # The claim is pdfuaid:part in the XMP, and its value picks the profile -
  # ua1 or ua2. A document without one is not judged by this yardstick.
  for f in examples/out/*.pdf; do
    uapart=`strings "$f" |
        grep -o 'pdfuaid:part="[0-9]"\|<pdfuaid:part>[0-9]<' |
        head -1 | tr -dc '0-9'`
    test -n "$uapart" || continue
    failed=`verapdf --flavour "ua$uapart" "$f" 2>/dev/null |
        sed -n 's/.*failedChecks="\([0-9]*\)".*/\1/p' | head -1`
    if test "$failed" = "0"; then
      report_pass "veraPDF --flavour ua$uapart `basename $f`"
    else
      report_fail "veraPDF --flavour ua$uapart `basename $f`: ${failed:-no answer} failed checks"
    fi
  done

  # WTPDF, likewise by its own declaration: the conformsTo URI names the
  # level, and each level has its own profile.
  for f in examples/out/*.pdf; do
    for level in reuse accessibility; do
      case $level in
        reuse) profile=wt1r ;;
        *) profile=wt1a ;;
      esac
      strings "$f" | grep -q "declarations/wtpdf.*#${level}1.0" || continue
      failed=`verapdf --flavour $profile "$f" 2>/dev/null |
          sed -n 's/.*failedChecks="\([0-9]*\)".*/\1/p' | head -1`
      if test "$failed" = "0"; then
        report_pass "veraPDF --flavour $profile `basename $f`"
      else
        report_fail "veraPDF --flavour $profile `basename $f`: ${failed:-no answer} failed checks"
      fi
    done
  done

  # The tagged documents that claim NO accessibility level are still measured
  # against ua1, because the number moving is worth seeing the day it moves -
  # measured once on a file with tagged content inside an artifact, where -f
  # 3a said conforming and ua1 found 33.
  for f in examples/out/*.pdf; do
    grep -l "StructTreeRoot" "$f" >/dev/null 2>&1 || continue
    strings "$f" | grep -q 'pdfuaid:part' && continue
    failed=`verapdf --flavour ua1 "$f" 2>/dev/null |
        sed -n 's/.*failedChecks="\([0-9]*\)".*/\1/p' | head -1`
    echo "  note  ua1 `basename $f`: ${failed:-no answer} (informational)"
  done
else
  report_skip "veraPDF not installed"
fi

echo "=== 5. Mustang over every document that carries a hybrid attachment ==="

# ZUGFeRD, Factur-X and Order-X have a reference validator of their own:
# Mustangproject checks the attached XML against schema and schematron and
# the way it sits in the PDF - none of which qpdf or veraPDF looks at.
# Which documents this yardstick applies to is, again, not a list kept here:
# the Factur-X / Order-X extension schema in the XMP names the attached file
# in fx:DocumentFileName, and a document without that claim is no hybrid and
# is not judged.
#
# The exit code, never the output: 0 is valid, anything else is not. On
# failure the report's first <error> is quoted, because a bare "invalid"
# sends whoever reads it straight back to re-running the tool by hand.
# Measured 2026-08-18: about 1 s per document (0.9-1.2 s, JVM start included) - three documents, three seconds.
mustang=`ls tools/Mustang-CLI-*.jar 2>/dev/null | head -1`
if test -n "$mustang" && have java; then
  found=0
  for f in examples/out/*.pdf; do
    strings "$f" | grep -q '<fx:DocumentFileName>' || continue
    found=`expr $found + 1`
    if out=`java -jar "$mustang" --action validate --source "$f" --disable-file-logging 2>/dev/null`; then
      report_pass "Mustang `basename $f`"
    else
      msg=`echo "$out" | sed -n 's/.*<error[^>]*>\(.*\)<\/error>.*/\1/p' | head -1`
      report_fail "Mustang `basename $f`: ${msg:-invalid}"
    fi
  done
  test $found -gt 0 || report_fail "no document names a hybrid attachment - did the XMP change?"
else
  report_skip "Mustang (java plus tools/Mustang-CLI-*.jar) not available"
fi

echo "=== 6. a reader, not a validator ==="

# What no profile catches: text that validates and extracts wrongly. Missing
# word spaces at a line break came out as "istgetauscht" through every profile.
if have pdfinfo; then
  for f in examples/out/*.pdf; do
    grep -l "StructTreeRoot" "$f" >/dev/null 2>&1 || continue
    lines=`pdfinfo -struct-text "$f" 2>/dev/null | wc -l | tr -d ' '`
    if test "$lines" -gt 1; then
      report_pass "pdfinfo reads $lines structure lines from `basename $f`"
    else
      report_fail "pdfinfo found no structure in `basename $f`"
    fi
  done
else
  report_skip "pdfinfo (poppler) not installed"
fi

echo "=== 7. pdfsig over every signed document ==="

# The one thing in this package that only a second program can confirm. Every
# offset in the file can be right, qpdf can be happy with all of it, and the
# digest can still not match what the CMS object was made over - nothing on
# this side of the fence would notice, because this side is what computed the
# offsets in the first place. pdfsig recomputes the digest.
#
# Which documents: the ones that carry a /ByteRange, not a list kept here.
# Two answers are wanted and both matter. "Signature is Valid" is about the
# digest; "Total document signed" is about coverage, and a signature over
# half a document is worth half a document.
#
# What is NOT a failure: the certificate. The example signs with a test CA it
# generates and deletes again, so "Certificate issuer isn't Trusted" is the
# correct verdict and is not looked at here. A valid signature and a trusted
# signature are two different statements.
#
# What is also not a failure: an unfilled placeholder. Without openssl the
# example writes the document with the reserved room still full of zeros -
# a legitimate file, and exactly what stage one of the two-stage way hands
# on. pdfsig names that case itself ("Signature has not yet been verified"),
# and it is SKIPPED, because a machine without openssl has nothing to check
# here, not something broken.
if have pdfsig; then
  signed=0
  victim=""
  for f in examples/out/*.pdf; do
    grep -l "/ByteRange" "$f" >/dev/null 2>&1 || continue
    out=`pdfsig "$f" 2>/dev/null`
    case "$out" in
      *"has not yet been verified"*)
        report_skip "pdfsig `basename $f` - placeholder unfilled, the example found no openssl"
        continue
        ;;
    esac
    signed=`expr $signed + 1`
    case "$out" in
      *"Signature is Valid"*)
        case "$out" in
          *"Total document signed"*)
            test -n "$victim" || victim="$f"
            report_pass "pdfsig `basename $f`: valid, over the whole file"
            ;;
          *)
            report_fail "pdfsig `basename $f`: valid, but NOT over the whole document"
            ;;
        esac
        ;;
      *)
        verdict=`echo "$out" | sed -n 's/.*Signature Validation: //p' | head -1`
        report_fail "pdfsig `basename $f`: ${verdict:-no verdict}"
        ;;
    esac
  done

  # The control line, and it is the reason the section is worth running: a
  # verifier that cannot say no verifies nothing. So hand pdfsig a copy whose
  # bytes were changed INSIDE the signed range and require it to notice.
  #
  # Where: the /Producer string of the information dictionary. It is plain
  # text, every tclpdf document has one, and it sits in the second signed
  # range - which runs from the end of the reserved room to the end of the
  # file. One character of it changed leaves a PERFECTLY WELL-FORMED PDF that
  # no longer matches its signature, which is the file this whole section
  # exists for. Ten bytes past the key is the first character of the value,
  # so the dictionary keys themselves stay untouched.
  #
  # qpdf is asked about the copy as well and has to still accept it: if the
  # tampered file were merely broken, pdfsig refusing it would prove nothing
  # about the digest.
  if test -z "$victim"; then
    report_skip "the tamper control - no signed document to tamper with"
  else
    at=`grep -abo "Producer" "$victim" 2>/dev/null | tail -1 | cut -d: -f1`
    if test -z "$at"; then
      report_fail "no /Producer in `basename $victim` - the tamper control has nothing to change"
    else
      cp "$victim" /tmp/tclpdf-tampered.$$
      printf 'X' | dd of=/tmp/tclpdf-tampered.$$ bs=1 seek=`expr $at + 10` \
          count=1 conv=notrunc 2>/dev/null
      if cmp -s "$victim" /tmp/tclpdf-tampered.$$; then
        report_fail "the tamper control changed no byte - the control is not working"
      elif have qpdf && ! qpdf --check /tmp/tclpdf-tampered.$$ >/dev/null 2>&1; then
        report_fail "the tampered copy is not a well-formed PDF - the control proves nothing"
      else
        case `pdfsig /tmp/tclpdf-tampered.$$ 2>/dev/null` in
          *"Digest Mismatch"*)
            report_pass "pdfsig control: one byte changed inside the signed range is caught"
            ;;
          *)
            report_fail "pdfsig accepted a tampered document - the check is not working"
            ;;
        esac
      fi
      rm -f /tmp/tclpdf-tampered.$$
    fi
  fi
else
  report_skip "pdfsig (poppler) not installed"
fi

echo "=== 8. the manual is no older than what it is made from ==="

# Neither doc/tclpdf.n nor doc/tclpdf.html is under version control: both are
# built by "make all" and travel in the source archive. That is exactly why
# nothing else notices when they fall behind - a check-in of doc/tclpdf.md
# looks complete, and the stale pages only surface in a release, which is where
# they cost the most. Version 1.0 shipped that way once: "make publish" ran
# before the second check-in and the archives carried the code from before it.
#
# A timestamp, not a diff: the two are generated, so any difference at all is
# either "not rebuilt" or noise from pandoc.
manualSource=doc/tclpdf.md
for made in doc/tclpdf.n doc/tclpdf.html; do
  if test ! -f "$made"; then
    report_fail "$made is missing - run make all"
  elif test "$manualSource" -nt "$made"; then
    report_fail "$made is older than $manualSource - run make all"
  else
    report_pass "`basename $made` is no older than its source"
  fi
done

echo "=== 9. the reference code of the tclpdf-tcl skill runs ==="

# doc/claude/skills/tclpdf-tcl/reference/*.md is the code a reader - or an
# agent - copies, so it has to keep running against the package as it is;
# check.tcl there extracts every tcl block, runs each file in a fresh tclsh
# and puts qpdf and veraPDF over what came out. Under the same interpreter
# rule as the suite: both where both are present.
#
# What it produces stays, under examples/tmp/reference: the extracted scripts
# there, their PDFs in its out/. The name says what it is - nothing in that
# branch is a source file - and after a failure it is the evidence, because
# the extracted script carries the line numbers the error message names.
# "make clean" removes examples/tmp either way.
reference=doc/claude/skills/tclpdf-tcl
if test -f "$reference/check.tcl"; then
  for tclsh in tclsh8.6 tclsh9.0; do
    if have $tclsh; then
      if TCLPDF_REFERENCE_OUT=examples/tmp/reference/out \
          $tclsh "$reference/check.tcl" "$reference/assets.tcl" >/tmp/tclpdf-reference.$$ 2>&1; then
        report_pass "reference snippets under $tclsh: `tail -1 /tmp/tclpdf-reference.$$`"
      else
        report_fail "reference snippets under $tclsh - see below"
        grep -v '^PASS' /tmp/tclpdf-reference.$$ | head -20
      fi
      rm -f /tmp/tclpdf-reference.$$
    else
      report_skip "reference snippets under $tclsh - interpreter not installed"
    fi
  done
else
  report_skip "$reference/check.tcl not present"
fi

echo "==="
echo "passed $pass, failed $fail, skipped $skip"
test $skip -eq 0 || echo "NOTE: $skip check(s) did not run - skipped is not passed"
test $fail -eq 0 || exit 1
exit 0
