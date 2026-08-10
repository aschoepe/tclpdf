#
# tclpdf - PDF generation for Tcl
#
# filter - stream filters (7.4)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Writing a PDF needs exactly two filters: FlateDecode for everything and
# DCTDecode for JPEG, which is pass-through and therefore not a filter at all.
# The two ASCII filters here are not for size - they make a stream readable in
# a text editor, which is worth a lot while debugging and costs 25 % (Ascii85)
# or 100 % (AsciiHex) in size. Everything else - LZW, CCITT, JBIG2, RunLength -
# is only needed for READING foreign PDFs and belongs to stage 7.
#
# Every procedure takes and returns bytes, never text. A caller that hands in a
# string with characters above U+00FF has already made a mistake somewhere else.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::filter {
  namespace export {[a-z]*}
  namespace ensemble create
}

# FlateDecode (7.4.4).
#
# "zlib compress" produces the zlib format of RFC 1950 - a two-byte header, the
# deflate data, an Adler-32 checksum - and that is exactly what /FlateDecode
# expects. "zlib deflate" would give raw deflate WITHOUT the header, which
# every reader rejects. The two spellings differ by one word and produce files
# that look almost identical, so this is worth stating rather than remembering.
#
# zlib is a built-in command in Tcl 8.6 and 9 alike; it is deliberately not
# requested as a package, because that package exists only in 8.6.
proc ::tclpdf::filter::encodeFlate {bytes {level 6}} {
  return [zlib compress $bytes $level]
}

proc ::tclpdf::filter::decodeFlate {bytes} {
  return [zlib decompress $bytes]
}

# ASCII85Decode (7.4.3). Four bytes become five characters from "!" onwards,
# four zero bytes collapse into a single "z", and the stream ends with "~>".
proc ::tclpdf::filter::encodeAscii85 {bytes {width 75}} {
  binary scan $bytes cu* octets
  set result {}
  set column 0
  set total [llength $octets]
  for {set index 0} {$index < $total} {incr index 4} {
    set group [lrange $octets $index [expr {$index + 3}]]
    # A short final group is padded with zeros and then emits one character
    # more than it had bytes - that is what makes the length recoverable.
    set missing [expr {4 - [llength $group]}]
    for {set n 0} {$n < $missing} {incr n} {
      lappend group 0
    }
    lassign $group b0 b1 b2 b3
    set word [expr {($b0 << 24) | ($b1 << 16) | ($b2 << 8) | $b3}]
    if {$word == 0 && $missing == 0} {
      set piece z
    } else {
      set digits {}
      for {set n 0} {$n < 5} {incr n} {
        set digits [linsert $digits 0 [format %c [expr {33 + $word % 85}]]]
        set word [expr {$word / 85}]
      }
      set piece [join [lrange $digits 0 [expr {4 - $missing}]] {}]
    }
    append result $piece
    incr column [string length $piece]
    if {$width > 0 && $column >= $width} {
      append result \n
      set column 0
    }
  }
  append result ~>
  return $result
}

proc ::tclpdf::filter::decodeAscii85 {text} {
  # White space may appear anywhere in the stream (7.2.3) and carries no
  # meaning, so it is removed before anything is interpreted.
  regsub -all {[ \t\r\n\f\x00]} $text {} text
  set stop [string first ~> $text]
  if {$stop >= 0} {
    set text [string range $text 0 $stop-1]
  }
  set result {}
  set group {}
  foreach char [split $text {}] {
    if {$char eq "z" && [llength $group] == 0} {
      append result [binary format I 0]
      continue
    }
    lappend group [expr {[scan $char %c] - 33}]
    if {[llength $group] == 5} {
      append result [Ascii85Group $group]
      set group {}
    }
  }
  if {[llength $group] > 0} {
    append result [Ascii85Group $group]
  }
  return $result
}

# Turn one to five base-85 digits back into bytes. A short group is filled up
# with the highest digit rather than with zeros: rounding must go upwards, or
# the last byte comes out one too low.
proc ::tclpdf::filter::Ascii85Group {digits} {
  set count [llength $digits]
  if {$count < 2} {
    return -code error "tclpdf: truncated ASCII85 group"
  }
  for {set n $count} {$n < 5} {incr n} {
    lappend digits 84
  }
  set word 0
  foreach digit $digits {
    set word [expr {$word * 85 + $digit}]
  }
  return [string range [binary format I $word] 0 [expr {$count - 2}]]
}

# ASCIIHexDecode (7.4.2). Doubles the size and is meant for inspection, not for
# production streams.
proc ::tclpdf::filter::encodeAsciiHex {bytes {width 64}} {
  binary scan $bytes H* hex
  if {$width <= 0} {
    return $hex>
  }
  set result {}
  set length [string length $hex]
  for {set index 0} {$index < $length} {incr index $width} {
    append result [string range $hex $index [expr {$index + $width - 1}]] \n
  }
  append result >
  return $result
}

proc ::tclpdf::filter::decodeAsciiHex {text} {
  set stop [string first > $text]
  if {$stop >= 0} {
    set text [string range $text 0 $stop-1]
  }
  regsub -all {[^0-9A-Fa-f]} $text {} hex
  # An odd number of digits is not an error: the missing one counts as zero
  # (7.4.2). Silently dropping the last nibble instead would lose a byte.
  if {[string length $hex] % 2} {
    append hex 0
  }
  return [binary format H* $hex]
}

package provide tclpdf::filter 1.0
