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

# Where a file is about to be written: the directory has to be one, and it
# has to be there.
#
# [open $path w] says so itself, but in POSIX's words and with POSIX's error
# code - "couldn't open \"/nonexistent/dir/x.pdf\": no such file or
# directory", and a code whose first word is the operating system's rather
# than this package's - while the manual promises that every refusal of this
# package begins with "tclpdf:" (doc/tclpdf.md:1379).
# Measured 2026-08-26 through [$doc write], which is the call a caller makes
# with a path they built themselves.
#
# Only the two cases a caller can act on are named. Everything else - a
# read-only directory, a full disk, a name too long - stays with [open],
# whose message is then the whole truth and has nothing better to be
# replaced with.
proc ::tclpdf::io::checkTarget {path} {
  set directory [file dirname $path]
  if {![file exists $directory]} {
    return -code error -errorcode [list TCLPDF IO DIRECTORY $directory] \
        "tclpdf: \"$directory\" does not exist, so \"$path\" cannot be\
        written - the directory is not created here"
  }
  if {![file isdirectory $directory]} {
    return -code error -errorcode [list TCLPDF IO DIRECTORY $directory] \
        "tclpdf: \"$directory\" is a file, not a directory, so \"$path\"\
        cannot be written"
  }
  if {[file isdirectory $path]} {
    return -code error -errorcode [list TCLPDF IO DIRECTORY $path] \
        "tclpdf: \"$path\" is a directory, not a file"
  }
  return
}

# Write bytes to a file.
proc ::tclpdf::io::write {path bytes} {
  checkTarget $path
  set channel [open $path w]
  fconfigure $channel -translation binary
  puts -nonewline $channel $bytes
  close $channel
  return $path
}

package provide tclpdf::io 1.2
