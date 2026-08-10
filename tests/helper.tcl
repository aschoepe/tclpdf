# helper.tcl --
#
# Shared helpers for the test suite. Anything a SECOND test file needs belongs
# here rather than being copied - copies drift, and the third copy is then made
# from the wrong one.
#
# Sourced by tests/all.tcl and, so that a single file can also be run on its
# own, by each test file that uses it.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

namespace eval ::tclpdfTest {}

# Read a file as bytes. Every test that looks at a generated PDF needs this,
# and it needs the binary translation - reading a PDF as text turns the binary
# marker in line two into replacement characters and shifts every offset.
proc ::tclpdfTest::readBytes {path} {
  package require tclpdf::io
  return [::tclpdf::io read $path]
}

# The content stream of a page, so a test can check which operators were
# produced rather than only that a file appeared. Reads the buffer, not the
# written object: the object does not exist until [write] runs.
proc ::tclpdfTest::content {doc {index {}}} {
  return [$doc page content $index]
}

# A scratch path inside the tcltest temporary directory.
proc ::tclpdfTest::scratch {name} {
  return [file join [::tcltest::temporaryDirectory] $name]
}

# The decoded stream of one object - for tests that have to look inside a
# compressed stream (a font file, a ToUnicode map, a CIDToGIDMap).
proc ::tclpdfTest::streamOf {writer number} {
  package require tclpdf::filter
  if {$number eq {}} {
    return {}
  }
  set body [$writer body $number]
  set start [expr {[string first "stream\n" $body] + 7}]
  set stop [expr {[string last "\nendstream" $body] - 1}]
  set data [string range $body $start $stop]
  if {[string match {*/Filter /FlateDecode*} $body]} {
    set data [::tclpdf::filter decodeFlate $data]
  }
  return $data
}
