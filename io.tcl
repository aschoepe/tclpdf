#
# tclpdf - PDF generation for Tcl
#
# io - reading and writing bytes
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Four lines of channel handling that decide whether a document is correct.
# Attachments, font files and images all read foreign bytes, and every one of
# them has to read them UNCHANGED. Written per module, the one call that
# matters is eventually forgotten in one of them.
#
# What can go wrong is invisible:
#
#   * without "-translation binary" a channel turns CRLF into LF on the way in
#     and back on the way out - measured, 17 written bytes became 21 in the
#     file, and a font or a JPEG is broken by that without any error
#   * an invoice XML rewritten that way still validates: no PDF validator
#     compares an attachment against its original. Measured on the reference
#     corpus, 8 of 61 files differ from their published counterparts in
#     nothing but CRLF against LF
#
# "-encoding binary" is deliberately NOT set: it throws under Tcl 9.0.4
# ("unknown encoding \"binary\": No longer supported") while working under 8.6,
# so the package would break on the other interpreter. The translation setting
# already selects the byte-transparent encoding in both.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::io {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Read a file as bytes.
proc ::tclpdf::io::read {path} {
  if {![file exists $path]} {
    return -code error -errorcode [list TCLPDF IO MISSING $path] \
        "tclpdf: \"$path\" does not exist"
  }
  if {[file isdirectory $path]} {
    return -code error -errorcode [list TCLPDF IO DIRECTORY $path] \
        "tclpdf: \"$path\" is a directory, not a file"
  }
  set channel [open $path r]
  fconfigure $channel -translation binary
  set bytes [::read $channel]
  close $channel
  return $bytes
}

# Read the first N bytes - enough for a header, without pulling a 40 MB image
# into memory to find out how wide it is.
proc ::tclpdf::io::head {path count} {
  if {![file exists $path]} {
    return -code error -errorcode [list TCLPDF IO MISSING $path] \
        "tclpdf: \"$path\" does not exist"
  }
  set channel [open $path r]
  fconfigure $channel -translation binary
  set bytes [::read $channel $count]
  close $channel
  return $bytes
}

# Write bytes to a file.
proc ::tclpdf::io::write {path bytes} {
  set channel [open $path w]
  fconfigure $channel -translation binary
  puts -nonewline $channel $bytes
  close $channel
  return $path
}

package provide tclpdf::io 1.1
