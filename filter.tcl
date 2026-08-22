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
package require tclpdf::option 1.0-

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

# ---------------------------------------------------------------- LZWDecode

# The 256 single-byte entries plus the two markers, built once. Every clear
# code copies this list instead of filling 256 entries again.
namespace eval ::tclpdf::filter {
  variable LzwRoots {}
  # [variable n] first: without it an unqualified [set n] at the top of a
  # namespace eval falls back to a global n of the same name where one exists,
  # so [package require tclpdf::filter] would overwrite - and then [unset] -
  # the caller's ::n. Declared here, the loop counter stays in this namespace.
  variable n
  for {set n 0} {$n < 256} {incr n} {
    lappend LzwRoots [binary format c $n]
  }
  lappend LzwRoots {} {}
  unset n
}

# LZWDecode (7.4.4.2). This package never WRITES LZW: Flate is smaller for the
# same input, and PDF/A-3B forbids the filter outright (ISO 19005-3, 6.1.7.2 -
# veraPDF names that clause when it rejects such a stream). Reading it is a
# different matter, and there are two places where LZW arrives from outside: a
# content stream in an imported PDF, and the strips of a TIFF - which for that
# same clause cannot be passed through into a PDF/A document but have to be
# unpacked here and written out again as Flate.
#
# Codes are 9 to 12 bits, packed high-order bit first. Code 256 clears the
# table, 257 is EOD, 0 to 255 stand for themselves, and 258 onwards is built by
# encoder and decoder in step - which is why the table is never transmitted.
#
# EARLY CHANGE is the one place where two LZW streams that look alike behave
# differently, and it goes wrong LATE: with the wrong setting the first 254
# codes still decode correctly and only the data after the first width change
# turn to noise. ISO 32000-2, Table 8: /EarlyChange 1 (the default) raises the
# code length one code EARLIER than necessary, 0 postpones it as long as
# possible. Measured on 2026-08-21 over 100 LZW-compressed TIFF files: with
# early change 1 all of them decode, 96 of them byte for byte identical to
# libtiff and the remaining four identical to what two other implementations
# make of the same streams; with 0 not one of them survives its first width
# change. The PDF default is therefore the right value for a TIFF strip too,
# and callers need not think about it.
#
# The input is walked in blocks rather than turned into one list of bytes:
# a single strip in that corpus reaches 50 MB, and "binary scan cu*" over it
# would build a list of fifty million integers to read four million codes from.
proc ::tclpdf::filter::decodeLzw {bytes {earlyChange 1}} {
  variable LzwRoots
  if {$earlyChange ni {0 1}} {
    return -code error -errorcode [list TCLPDF FILTER LZW EARLYCHANGE $earlyChange] \
        "tclpdf: early change is 0 or 1, got \"$earlyChange\""
  }
  set table $LzwRoots
  set next 258
  set width 9
  set previous {}
  set out {}
  set raised 0
  set accumulator 0
  set have 0
  set total [string length $bytes]
  for {set start 0} {$start < $total} {incr start 65536} {
    binary scan [string range $bytes $start [expr {$start + 65535}]] cu* octets
    foreach octet $octets {
      set accumulator [expr {($accumulator << 8) | $octet}]
      incr have 8
      while {$have >= $width} {
        incr have -$width
        set code [expr {$accumulator >> $have}]
        set accumulator [expr {$accumulator & ((1 << $have) - 1)}]
        if {$code == 256} {
          set table $LzwRoots
          set next 258
          set width 9
          set previous {}
          set raised 0
          continue
        }
        if {$code == 257} {
          return $out
        }
        if {$previous eq {}} {
          # The first code after a clear stands for one byte and nothing is
          # added to the table - there is no previous sequence to extend.
          if {$code > 255} {
            return -code error -errorcode [list TCLPDF FILTER LZW CODE $code] \
                "tclpdf: LZW stream starts with code $code, which no table entry defines yet"
          }
          set entry [lindex $table $code]
        } elseif {$code < $next} {
          set entry [lindex $table $code]
          if {$next < 4096} {
            lappend table $previous[string index $entry 0]
            incr next
          }
        } elseif {$code == $next} {
          # The one case that looks like a bug and is not: an encoder may
          # emit the code it is about to define, when the same byte sequence
          # repeats immediately. The entry is then the previous one plus its
          # own first byte.
          set entry $previous[string index $previous 0]
          lappend table $entry
          incr next
        } else {
          # An EOD marker written one bit narrower than expected, and it is
          # the encoder that is right. The encoder adds a table entry with
          # every code it emits, the decoder only from the second code on -
          # so at the end of the input, where the encoder emits its last code
          # and stops without a following byte to extend it, the decoder has
          # made ONE entry the encoder never made. If that entry is the one
          # that crosses a width boundary, the decoder widens and the encoder
          # does not, and the following EOD is read one bit too wide.
          # Measured on 2026-08-21: one strip of 1922 in one file of the local
          # corpus ends this way, and libtiff never notices because it stops
          # at the expected row length instead of at EOD. Shifting the code
          # back by the one bit too many gives 257, and only then is this
          # taken for the end of the stream.
          if {$raised && $code >> 1 == 257} {
            return $out
          }
          return -code error -errorcode [list TCLPDF FILTER LZW CODE $code] \
              "tclpdf: LZW code $code is beyond the table, which holds $next entries"
        }
        append out $entry
        set previous $entry
        if {$width < 12 && $next + $earlyChange >= (1 << $width)} {
          incr width
          set raised 1
        } else {
          set raised 0
        }
      }
    }
  }
  # A stream without an EOD marker is common enough in the wild - TIFF strips
  # written by several encoders simply stop - and everything decoded so far is
  # good, so it is returned rather than refused.
  return $out
}

# --------------------------------------------------------------- predictors

# The predictor is not a filter of its own but a parameter of LZWDecode and
# FlateDecode (7.4.4.4): the data were differenced BEFORE being compressed, so
# the difference has to be undone AFTER decompression. Two families exist and
# /Predictor says which: 2 is TIFF Predictor 2, horizontal differencing with
# one algorithm for the whole image; 10 to 15 are the PNG row predictors,
# which carry a tag byte in front of every row and may differ from row to row -
# which of 10 to 15 is given says nothing, the row tag decides.
#
# Both families share the geometry (7.4.4.4): rows run top to bottom, a row
# occupies a whole number of bytes, components sit in a byte from the
# high-order bit down, and anything outside the image counts as zero.
#
# The two families differ in what they predict FROM, and that is the reason
# this procedure needs -colors and -bitspercomponent at all: TIFF Predictor 2
# predicts each colour component from the previous instance of THAT component,
# so it has to know how wide a component is and how many of them a sample has.
# The PNG group predicts a byte from the corresponding byte of the previous
# sample and does not care what a component is - it only needs the sample
# width in whole bytes.
#
#   ::tclpdf::filter decodePredictor $data -predictor 2 -colors 4 -columns 1417
#
# The option names and their defaults are those of /DecodeParms (Table 8), so
# a caller can hand the dictionary of a stream straight over. -byteorder has
# no counterpart there: PDF stores 16-bit components high byte first and the
# default says so, but a TIFF says in its own header which order it uses, and
# for Predictor 2 the difference decides.
proc ::tclpdf::filter::decodePredictor {bytes args} {
  set options [::tclpdf::option parse {
    predictor 1
    colors 1
    bitspercomponent 8
    columns 1
    byteorder big
  } $args decodePredictor]
  set predictor [dict get $options predictor]
  set colors [dict get $options colors]
  set depth [dict get $options bitspercomponent]
  set columns [dict get $options columns]
  set order [dict get $options byteorder]
  if {![string is entier -strict $predictor] ||
      ($predictor != 1 && $predictor != 2 && ($predictor < 10 || $predictor > 15))} {
    return -code error -errorcode [list TCLPDF FILTER PREDICTOR $predictor] \
        "tclpdf: unknown predictor \"$predictor\" - 1, 2 and 10 to 15 are\
        defined (Table 10)"
  }
  if {$predictor == 1} {
    return $bytes
  }
  if {![string is entier -strict $colors] || $colors < 1} {
    return -code error -errorcode [list TCLPDF FILTER PREDICTOR COLORS $colors] \
        "tclpdf: -colors is 1 or more, got \"$colors\""
  }
  if {$depth ni {1 2 4 8 16}} {
    return -code error -errorcode [list TCLPDF FILTER PREDICTOR DEPTH $depth] \
        "tclpdf: -bitspercomponent is 1, 2, 4, 8 or 16, got \"$depth\""
  }
  if {![string is entier -strict $columns] || $columns < 1} {
    return -code error -errorcode [list TCLPDF FILTER PREDICTOR COLUMNS $columns] \
        "tclpdf: -columns is 1 or more, got \"$columns\""
  }
  if {$order ni {big little}} {
    return -code error -errorcode [list TCLPDF FILTER PREDICTOR BYTEORDER $order] \
        "tclpdf: -byteorder is big or little, got \"$order\""
  }
  set rowBytes [expr {($columns * $colors * $depth + 7) / 8}]
  if {$predictor == 2} {
    switch -- $depth {
      8 {
        return [PredictorTiff8 $bytes $colors $rowBytes]
      }
      16 {
        return [PredictorTiff16 $bytes $colors $rowBytes $order]
      }
      default {
        return [PredictorTiffPacked $bytes $colors $columns $depth $rowBytes]
      }
    }
  }
  return [PredictorPng $bytes $rowBytes [expr {($colors * $depth + 7) / 8}]]
}

# The one refusal every predictor shares: a last row that stops short. The
# loops step a whole row at a time and leave anything shorter untouched, which
# would drop the tail silently and hand back a picture missing its foot - so a
# leftover is refused by name instead, for the public filter and the import
# path alike. Data taken from a TIFF has been cut to a whole number of rows by
# [Fit] before it arrives here, so this only ever fires on a damaged stream.
proc ::tclpdf::filter::PredictorRows {start total stride} {
  if {$start < $total} {
    return -code error -errorcode {TCLPDF FILTER PREDICTOR ROW} \
        "tclpdf: the predictor data ends in a partial row - [expr {$total -
        $start}] bytes stand where a row is $stride, and a short last row would\
        decode to a shifted picture"
  }
  return
}

# TIFF Predictor 2 for eight-bit components - 108 of 194 TIFF files measured
# here use it, and every one of those has eight-bit components. A row is a
# running sum per component, so the value COLORS bytes back is the predictor.
# Two indices walk the row instead of one, because "lindex $line [expr ...]"
# in the inner loop costs more than the second incr.
proc ::tclpdf::filter::PredictorTiff8 {bytes colors rowBytes} {
  set out {}
  set total [string length $bytes]
  for {set start 0} {$start + $rowBytes <= $total} {incr start $rowBytes} {
    binary scan [string range $bytes $start [expr {$start + $rowBytes - 1}]] cu* line
    set back 0
    for {set at $colors} {$at < $rowBytes} {incr at; incr back} {
      lset line $at [expr {([lindex $line $at] + [lindex $line $back]) & 0xff}]
    }
    append out [binary format c* $line]
  }
  PredictorRows $start $total $rowBytes
  return $out
}

# The same for sixteen-bit components. The byte order is not a detail: read
# the wrong way round the sum carries between the halves of a component and
# the image comes out as coloured noise, not as a slightly wrong image.
proc ::tclpdf::filter::PredictorTiff16 {bytes colors rowBytes order} {
  if {$order eq "big"} {
    set read Su*
    set write S*
  } else {
    set read su*
    set write s*
  }
  set words [expr {$rowBytes / 2}]
  set out {}
  set total [string length $bytes]
  for {set start 0} {$start + $rowBytes <= $total} {incr start $rowBytes} {
    binary scan [string range $bytes $start [expr {$start + $rowBytes - 1}]] $read line
    set back 0
    for {set at $colors} {$at < $words} {incr at; incr back} {
      lset line $at [expr {([lindex $line $at] + [lindex $line $back]) & 0xffff}]
    }
    append out [binary format $write $line]
  }
  PredictorRows $start $total $rowBytes
  return $out
}

# One, two and four bits per component. The samples do not fall on byte
# boundaries, so the row is taken apart into bits and put back together
# afterwards; the padding at the end of a row is written as zero, which is
# what 7.4.4.4 says is there. No file in the local corpus uses this, so it is
# written for clarity rather than for speed.
proc ::tclpdf::filter::PredictorTiffPacked {bytes colors columns depth rowBytes} {
  set mask [expr {(1 << $depth) - 1}]
  set samples [expr {$columns * $colors}]
  set out {}
  set total [string length $bytes]
  for {set start 0} {$start + $rowBytes <= $total} {incr start $rowBytes} {
    binary scan [string range $bytes $start [expr {$start + $rowBytes - 1}]] B* bits
    set line {}
    for {set at 0} {$at < $samples} {incr at} {
      set value [scan [string range $bits [expr {$at * $depth}] \
          [expr {($at + 1) * $depth - 1}]] %b]
      if {$at >= $colors} {
        set value [expr {($value + [lindex $line [expr {$at - $colors}]]) & $mask}]
      }
      lappend line $value
    }
    set packed {}
    foreach value $line {
      append packed [format %0${depth}b $value]
    }
    append packed [string repeat 0 [expr {$rowBytes * 8 - [string length $packed]}]]
    append out [binary format B* $packed]
  }
  PredictorRows $start $total $rowBytes
  return $out
}

# The PNG row predictors (ISO/IEC 15948, via 7.4.4.4). Every row starts with
# its own tag byte, so a row costs one byte more than it holds. BPP is the
# sample width in whole bytes and never less than one - for anything under
# eight bits per component the left neighbour is the byte before, which is
# what makes this family cheap and its compression worse.
proc ::tclpdf::filter::PredictorPng {bytes rowBytes bpp} {
  set out {}
  set stride [expr {$rowBytes + 1}]
  set prior [lrepeat $rowBytes 0]
  set total [string length $bytes]
  for {set start 0} {$start + $stride <= $total} {incr start $stride} {
    binary scan [string range $bytes $start [expr {$start + $stride - 1}]] cu* row
    set tag [lindex $row 0]
    set line {}
    set back [expr {-$bpp}]
    for {set at 0} {$at < $rowBytes} {incr at; incr back} {
      set byte [lindex $row [expr {$at + 1}]]
      if {$back >= 0} {
        set left [lindex $line $back]
        set upLeft [lindex $prior $back]
      } else {
        set left 0
        set upLeft 0
      }
      set up [lindex $prior $at]
      switch -- $tag {
        0 {
          set value $byte
        }
        1 {
          set value [expr {$byte + $left}]
        }
        2 {
          set value [expr {$byte + $up}]
        }
        3 {
          set value [expr {$byte + (($left + $up) / 2)}]
        }
        4 {
          set p [expr {$left + $up - $upLeft}]
          set pa [expr {abs($p - $left)}]
          set pb [expr {abs($p - $up)}]
          set pc [expr {abs($p - $upLeft)}]
          if {$pa <= $pb && $pa <= $pc} {
            set value [expr {$byte + $left}]
          } elseif {$pb <= $pc} {
            set value [expr {$byte + $up}]
          } else {
            set value [expr {$byte + $upLeft}]
          }
        }
        default {
          return -code error -errorcode [list TCLPDF FILTER PREDICTOR TAG $tag] \
              "tclpdf: unknown PNG predictor row tag $tag"
        }
      }
      lappend line [expr {$value & 0xff}]
    }
    append out [binary format c* $line]
    set prior $line
  }
  PredictorRows $start $total $stride
  return $out
}
package provide tclpdf::filter 1.2
