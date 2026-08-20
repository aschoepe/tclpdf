#
# tclpdf - PDF generation for Tcl
#
# pdfObj - turning Tcl values into PDF syntax
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# This is infrastructure: every other module writes PDF through here and none
# of them formats a number, escapes a name or builds a dictionary on its own.
# Those are exactly the operations that get reinvented slightly differently in
# each module otherwise, and a reader only tells you about it much later.
#
# Section numbers in the comments refer to ISO 32000-1 (PDF 1.7).
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::pdfObj {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Format a number the way PDF requires it (7.3.3): fixed notation, never an
# exponent. This is not cosmetic - "1e-05" is read as three separate tokens
# and corrupts the content stream, and Tcl produces that notation on its own
# for small values.
proc ::tclpdf::pdfObj::num {value {digits 5}} {
  if {![string is double -strict $value]} {
    return -code error "tclpdf: not a number: \"$value\""
  }
  set result [format %.*f $digits $value]
  # Infinity and NaN survive "string is double" but have no PDF spelling.
  if {[string match -nocase *inf* $result] || [string match -nocase *nan* $result]} {
    return -code error "tclpdf: number has no PDF representation: \"$value\""
  }
  # Neither has a magnitude beyond what a PDF real holds (ISO 32000-1,
  # Annex C.2: about +/-3.403e38). Fixed notation writes it anyway, as a
  # number of hundreds of digits - and a reader refuses that: qpdf reports
  # an overflow, treats the object as null and drops the whole content
  # stream it appears in.
  if {abs($value) > 3.403e38} {
    return -code error "tclpdf: number has no PDF representation: \"$value\"\
        is beyond the PDF real range of about +/-3.403e38 (ISO 32000-1,\
        Annex C.2)"
  }
  if {[string first . $result] >= 0} {
    set result [string trimright [string trimright $result 0] .]
  }
  # Trimming can leave "", "-" or "-0", all of which are wrong rather than short.
  if {$result in {{} - -0}} {
    set result 0
  }
  return $result
}

# A name object (7.3.5). Everything outside the printable ASCII range and every
# delimiter has to be written as #xx, which is why "/Mein Name" or a name with
# a slash in it cannot simply be concatenated.
proc ::tclpdf::pdfObj::name {value} {
  # The delimiters of 7.2.2 plus "#" itself, which introduces the escape.
  set delimiters "#()<>\[\]\{\}/%"
  set result /
  # Byte-wise via binary scan rather than [split]: the string may hold
  # characters above U+007F, and only the UTF-8 bytes may be escaped.
  binary scan [encoding convertto utf-8 $value] cu* codes
  foreach code $codes {
    # NUL is the one byte that may not appear in a name at all, not even
    # escaped (7.3.5) - writing "#00" would be well-formed syntax for a name
    # the standard says cannot exist.
    if {$code == 0} {
      return -code error "tclpdf: a name must not contain a NUL character\
          (ISO 32000-1, 7.3.5)"
    }
    set char [format %c $code]
    if {$code < 0x21 || $code > 0x7e || [string first $char $delimiters] >= 0} {
      append result [format #%02X $code]
    } else {
      append result $char
    }
  }
  return $result
}

# A string object (7.3.4). Pure ASCII becomes a literal string because that
# stays readable in the file; anything else becomes a UTF-16BE hex string,
# which every reader understands. PDFDocEncoding is deliberately not used: it
# covers a different subset than Latin-1 and would silently drop the rest.
proc ::tclpdf::pdfObj::str {value} {
  if {[regexp {^[\x20-\x7e\r\n\t]*$} $value]} {
    # Backslash first - otherwise the backslashes introduced by the following
    # rules would be escaped a second time.
    return ([string map [list \\ \\\\ ( \\( ) \\) \r \\r \n \\n \t \\t] $value])
  }
  return [hexStr [Utf16Be $value]]
}

# A literal string from BYTES that are already in the target encoding.
#
# Distinct from [str] on purpose. [str] takes text and decides how to encode
# it; this one takes bytes a font module has already produced - WinAnsi for a
# standard font, the two-byte codes of Identity-H for an embedded one - and
# only escapes what the syntax requires. Running text through [str] instead
# would re-encode it as UTF-16 and the reader would show something else.
proc ::tclpdf::pdfObj::bytesStr {bytes} {
  binary scan $bytes cu* codes
  set result (
  foreach code $codes {
    switch -- $code {
      40 - 41 - 92 {
        # ( ) and the backslash itself
        append result \\ [format %c $code]
      }
      default {
        if {$code < 32 || $code > 126} {
          # Octal escape: keeps the file text-safe and side-steps every
          # line-ending translation a byte above 127 could run into.
          append result \\ [format %03o $code]
        } else {
          append result [format %c $code]
        }
      }
    }
  }
  append result )
  return $result
}

# A hexadecimal string object (7.3.4.3). Takes bytes, not text.
proc ::tclpdf::pdfObj::hexStr {bytes} {
  binary scan $bytes H* hex
  return <$hex>
}

# An indirect reference (7.3.10). Small enough to be written by hand
# everywhere, which is precisely why it belongs here once.
proc ::tclpdf::pdfObj::ref {number {generation 0}} {
  return "$number $generation R"
}

# A dictionary (7.3.7) from a Tcl dict or a flat key/value list. Keys are
# encoded as names; VALUES ARE TAKEN AS THEY ARE, already in PDF syntax. That
# is the contract - a caller passing a bare string would otherwise never learn
# whether it was going to be quoted or not.
proc ::tclpdf::pdfObj::dictionary {pairs} {
  set result <<
  foreach {key value} $pairs {
    append result " " [name $key] " " $value
  }
  append result " >>"
  return $result
}

# An array (7.3.6), same contract: the items are already PDF syntax.
proc ::tclpdf::pdfObj::arr {items} {
  return \[[join $items " "]\]
}

# A date string (7.9.4): D:YYYYMMDDHHmmSSOHH'mm'.
#
# ISO 32000-2 struck the apostrophe AFTER the offset minutes, so 2.0 wants
# D:...+02'00 where 1.7 wants D:...+02'00'. Readers have to accept both, but a
# file should spell its own version - hence the argument rather than one form
# for everyone. The default stays the 1.7 form, because that is what a
# document is unless it says otherwise.
proc ::tclpdf::pdfObj::date {{seconds {}} {version 1.7}} {
  if {$seconds eq {}} {
    set seconds [clock seconds]
  }
  set stamp [clock format $seconds -format D:%Y%m%d%H%M%S]
  set zone [clock format $seconds -format %z]
  set offset "[string index $zone 0][string range $zone 1 2]'[string range $zone 3 4]"
  if {[package vcompare $version 2.0] < 0} {
    append offset "'"
  }
  return "$stamp$offset"
}

# UTF-16BE with a byte order mark. Without the BOM a reader falls back to
# PDFDocEncoding (7.9.2.2) and every non-ASCII character comes out wrong.
#
# The loop is written so that it is correct under both interpreters WITHOUT a
# version switch: Tcl 8.6 stores characters outside the BMP as a surrogate
# pair, so [split] already yields the two halves and each one is written
# unchanged; Tcl 9 yields one code point above 0xFFFF, and the pair is formed
# here. Both paths produce the same bytes.
proc ::tclpdf::pdfObj::Utf16Be {value} {
  set result [binary format S 0xFEFF]
  foreach char [split $value {}] {
    set code [scan $char %c]
    if {$code > 0xFFFF} {
      incr code -0x10000
      append result [binary format SS \
          [expr {0xD800 | (($code >> 10) & 0x3FF)}] \
          [expr {0xDC00 | ($code & 0x3FF)}]]
    } else {
      append result [binary format S $code]
    }
  }
  return $result
}

package provide tclpdf::pdfObj 1.3