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
# Every file is opened in ONE place, [Transfer], and the channel is closed
# there whatever happens. Measured 2026-10-01 under 8.6.18 and 9.0.4: [open]
# on a directory SUCCEEDS for reading, and only the [read] after it fails
# (POSIX EISDIR) - with the channel still listed in [chan names]. Asking
# [file exists]/[file isdirectory] before the open, as [read] did, left a
# window in which the answer went stale, and [head] did not ask at all. So
# the open is tried first, and the path is asked what it is only after it
# failed: the question decides the message, not the road, and it depends on
# no POSIX code, whose value on Windows is unmeasured here.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::io {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Read a file as bytes.
proc ::tclpdf::io::read {path} {
  return [Transfer $path r ::read]
}

# Read the first N bytes - enough for a header, without pulling a 40 MB image
# into memory to find out how wide it is.
proc ::tclpdf::io::head {path count} {
  return [Transfer $path r \
      [list apply {{count channel} {::read $channel $count}} $count]]
}

# Open PATH for ACCESS ("r" or "w"), hand the binary channel to COMMAND - a
# command prefix, called with the channel appended - and return what COMMAND
# returns. The channel is closed on every road out.
#
# The close of the successful road stands in the body rather than only in the
# [finally]: what a write leaves in the buffer reaches the disk at [close],
# so a full disk is reported there and must not be swallowed. The [finally]
# closes only what an error left open, and quietly, so that the error the
# caller sees is the first one rather than a follow-up of the close.
#
# A POSIX failure is then explained by the path if the path can explain it
# ([Refuse]); anything else - no permission, a full disk, an I/O error - is
# passed on as the operating system reported it.
proc ::tclpdf::io::Transfer {path access command} {
  try {
    set channel [open $path $access]
    fconfigure $channel -translation binary
    set result [{*}$command $channel]
    set closing $channel
    unset channel
    close $closing
    return $result
  } trap POSIX {message options} {
    Refuse $path $access
    return -options $options $message
  } finally {
    if {[info exists channel]} {
      catch {close $channel}
    }
  }
}

# Refuse with this package's code when the path itself says why it cannot be
# used for ACCESS, and return otherwise. A missing file is a reason only for
# reading: a file about to be written does not exist yet.
proc ::tclpdf::io::Refuse {path access} {
  if {$access eq "r" && ![file exists $path]} {
    return -code error -errorcode [list TCLPDF IO MISSING $path] \
        "tclpdf: \"$path\" does not exist"
  }
  if {[file isdirectory $path]} {
    return -code error -errorcode [list TCLPDF IO DIRECTORY $path] \
        "tclpdf: \"$path\" is a directory, not a file"
  }
  return
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
  Refuse $path w
}

# Write bytes to a file.
proc ::tclpdf::io::write {path bytes} {
  checkTarget $path
  Transfer $path w \
      [list apply {{bytes channel} {puts -nonewline $channel $bytes}} $bytes]
  return $path
}

package provide tclpdf::io 1.3
