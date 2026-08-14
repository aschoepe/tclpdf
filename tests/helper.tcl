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

# Where the lines of a content stream start: the x values of every Td, and the
# y values, in the order they were written. Two test files wanted the same
# five lines of parsing, which is one too many - a wrapped paragraph is
# checked by looking at where its lines begin, and that belongs in one place.
proc ::tclpdfTest::starts {stream {axis x}} {
  set result {}
  foreach line [split $stream \n] {
    # Td for an unrotated line, Tm for a turned one - the position is the last
    # pair either way. Reading only Td answered "no lines at all" for rotated
    # text, which looks like a drawing bug and is a reading one.
    if {[regexp {^([-0-9.]+) ([-0-9.]+) Td$} $line -> x y]
        || [regexp {^[-0-9.]+ [-0-9.]+ [-0-9.]+ [-0-9.]+ ([-0-9.]+) ([-0-9.]+) Tm$} \
            $line -> x y]} {
      lappend result [expr {$axis eq "x" ? $x : $y}]
    }
  }
  return $result
}

# The differences between consecutive values - the line advance of a block,
# read off the stream rather than assumed.
proc ::tclpdfTest::steps {values {digits 2}} {
  set result {}
  foreach a [lrange $values 0 end-1] b [lrange $values 1 end] {
    lappend result [format %.*f $digits [expr {$a - $b}]]
  }
  return $result
}

# A scratch path inside the tcltest temporary directory.
proc ::tclpdfTest::scratch {name} {
  return [file join [::tcltest::temporaryDirectory] $name]
}

# Write the same document twice and return both files as bytes.
#
# The write events fire on EVERY write, so anything that creates objects has
# to be idempotent - that contract is what these tests check, and each one of
# them was writing the same six lines to do it. The files are removed again;
# what the caller gets is the two contents.
proc ::tclpdfTest::writeTwice {doc name} {
  set first [scratch $name-a.pdf]
  set second [scratch $name-b.pdf]
  $doc write $first
  $doc write $second
  set result [list [readBytes $first] [readBytes $second]]
  file delete $first $second
  return $result
}

# Try to write a document and report whether it came out, cleaning up either
# way: {code written}, both 0 or 1.
#
# For the tests that turn on a document being ACCEPTED rather than on what is
# in it - PDF/A refusing an unembedded face is the usual reason. The write
# itself may fail, so the file has to be asked about separately, and the
# scratch file has to go whether it did or not.
proc ::tclpdfTest::writes {doc name} {
  set path [scratch $name]
  set code [catch {$doc write $path}]
  set written [expr {[file exists $path] ? 1 : 0}]
  file delete $path
  return [list $code $written]
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

# The raw glyf data of one glyph, or the empty string for a glyph that has
# none - a space, for instance.
#
# Three test files reach for this, which is two too many for a copy: the
# offsets come from loca and getting them wrong reads the neighbouring glyph
# rather than failing.
proc ::tclpdfTest::glyph {font id} {
  set loca [dict get $font loca]
  if {$id + 1 >= [llength $loca]} {
    return {}
  }
  set start [lindex $loca $id]
  set stop [lindex $loca [expr {$id + 1}]]
  if {$start >= $stop} {
    return {}
  }
  return [string range [::tclpdf::sfnt table $font glyf] $start \
      [expr {$stop - 1}]]
}
