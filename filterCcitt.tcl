#
# tclpdf - PDF generation for Tcl
#
# filterCcitt - the fax codings of ITU-T T.4 and T.6 (CCITTFaxDecode, 7.4.6)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# CCITTFaxDecode (7.4.6) - the fax codings of ITU-T T.4 and T.6. Like LZW this
# package never WRITES them: a TIFF whose strips are Group 3 or Group 4 is
# passed through into a /CCITTFaxDecode stream untouched, which is the right
# thing when writing and is what imageTiffStreams.tcl does. READING is the
# other direction and the reason this decoder exists: a scanned attachment
# whose page content or whose pixels have to be looked at cannot be taken over
# while nobody in the package can turn the code stream back into pixels.
#
# What actually occurs was measured on 2026-08-24 over the local corpus: of
# 25232 PDF files 1681 name /CCITTFaxDecode, and in a sample of 250 of them
# 1591 fax images carry /K -1 and not one carries /K 0, /K greater than zero,
# /BlackIs1, /EncodedByteAlign, /EndOfLine or /EndOfBlock. Group 4 is what
# arrives; the rest is written because the filter is defined that way and a
# reader that only manages the common case refuses the uncommon one silently.
#
# The output is one bit per pixel, rows padded out to whole bytes, which is
# what an /ImageMask or a one-bit /DeviceGray image expects. /BlackIs1 decides
# the polarity and its DEFAULT IS THE TRAP: false means a 0 bit is BLACK, so a
# decoder that quietly writes 1 for black hands back a negative of the page
# and every validator will agree with it.
#
#   ::tclpdf::filter decodeCcitt $bytes -columns 1728 -k -1 -rows 2376
#
# The option names and their defaults are those of /DecodeParms (Table 11), so
# the parameters of a stream can be handed straight over.
#
# THE SPELLING CALLERS USE IS THE ONE ABOVE. This module stands beside
# filter.tcl rather than in it because the code tables below are 600 lines
# that a document which never sees a fax has no reason to read, and
# [::tclpdf::filter decodeCcitt] is the bridge that requires it: the filters
# every document does use - Flate, the two ASCII ones, LZW, the predictors -
# stay in a file one can still read in one sitting, and the entry point does
# not move. [::tclpdf::filterCcitt decode] is that same procedure one step
# down, for a caller who wants the decoder without the filter package.
#

package require Tcl 8.6.11-
package require tclpdf::option 1.0-

namespace eval ::tclpdf::filterCcitt {
  namespace export {[a-z]*}
  namespace ensemble create
}


namespace eval ::tclpdf::filterCcitt {
  # Filled by [Tables] on the first call, not when this file is sourced: the
  # tables are 250 entries a document that loads the module for one small
  # stream still has no reason to build twice, and none at all before the
  # first row is read.
  variable White {}
  variable Black {}
  variable WhiteLengths {}
  variable BlackLengths {}
  variable Mode {}
  variable ModeLengths {}
}

# The run-length codes of T.4, table 2 (terminating, 0 to 63) and table 3
# (makeup, 64 to 1728), plus the makeup codes above 1728 that T.4 4.1.4 shares
# between the two colours. Written out as they stand in the recommendation:
# every attempt to generate them from a rule produces a table that is right
# for the entries one checked and wrong for the rest.
proc ::tclpdf::filterCcitt::Tables {} {
  variable White
  variable Black
  variable WhiteLengths
  variable BlackLengths
  variable Mode
  variable ModeLengths
  if {[dict size $White]} {
    return
  }
  set white {
    00110101 0    000111 1     0111 2       1000 3       1011 4
    1100 5       1110 6       1111 7       10011 8      10100 9
    00111 10     01000 11     001000 12    000011 13    110100 14
    110101 15    101010 16    101011 17    0100111 18   0001100 19
    0001000 20   0010111 21   0000011 22   0000100 23   0101000 24
    0101011 25   0010011 26   0100100 27   0011000 28   00000010 29
    00000011 30  00011010 31  00011011 32  00010010 33  00010011 34
    00010100 35  00010101 36  00010110 37  00010111 38  00101000 39
    00101001 40  00101010 41  00101011 42  00101100 43  00101101 44
    00000100 45  00000101 46  00001010 47  00001011 48  01010010 49
    01010011 50  01010100 51  01010101 52  00100100 53  00100101 54
    01011000 55  01011001 56  01011010 57  01011011 58  01001010 59
    01001011 60  00110010 61  00110011 62  00110100 63
    11011 64     10010 128    010111 192   0110111 256  00110110 320
    00110111 384 01100100 448 01100101 512 01101000 576 01100111 640
    011001100 704   011001101 768   011010010 832   011010011 896
    011010100 960   011010101 1024  011010110 1088  011010111 1152
    011011000 1216  011011001 1280  011011010 1344  011011011 1408
    010011000 1472  010011001 1536  010011010 1600  011000 1664
    010011011 1728
  }
  set black {
    0000110111 0 010 1        11 2         10 3         011 4
    0011 5       0010 6       00011 7      000101 8     000100 9
    0000100 10   0000101 11   0000111 12   00000100 13  00000111 14
    000011000 15 0000010111 16 0000011000 17 0000001000 18
    00001100111 19 00001101000 20 00001101100 21 00000110111 22
    00000101000 23 00000010111 24 00000011000 25 000011001010 26
    000011001011 27 000011001100 28 000011001101 29 000001101000 30
    000001101001 31 000001101010 32 000001101011 33 000011010010 34
    000011010011 35 000011010100 36 000011010101 37 000011010110 38
    000011010111 39 000001101100 40 000001101101 41 000011011010 42
    000011011011 43 000001010100 44 000001010101 45 000001010110 46
    000001010111 47 000001100100 48 000001100101 49 000001010010 50
    000001010011 51 000000100100 52 000000110111 53 000000111000 54
    000000100111 55 000000101000 56 000001011000 57 000001011001 58
    000000101011 59 000000101100 60 000001011010 61 000001100110 62
    000001100111 63
    0000001111 64    000011001000 128  000011001001 192  000001011011 256
    000000110011 320 000000110100 384  000000110101 448  0000001101100 512
    0000001101101 576  0000001001010 640  0000001001011 704
    0000001001100 768  0000001001101 832  0000001110010 896
    0000001110011 960  0000001110100 1024 0000001110101 1088
    0000001110110 1152 0000001110111 1216 0000001010010 1280
    0000001010011 1344 0000001010100 1408 0000001010101 1472
    0000001011010 1536 0000001011011 1600 0000001100100 1664
    0000001100101 1728
  }
  # T.4 4.1.4: one set of makeup codes for both colours, so a row wider than
  # 1728 pixels can be coded at all. Every one of them goes into both tables.
  set shared {
    00000001000 1792  00000001100 1856  00000001101 1920
    000000010010 1984 000000010011 2048 000000010100 2112
    000000010101 2176 000000010110 2240 000000010111 2304
    000000011100 2368 000000011101 2432 000000011110 2496
    000000011111 2560
  }
  set White [dict merge $white $shared]
  set Black [dict merge $black $shared]
  # The two-dimensional modes of T.4 table 4, as {name delta}. The delta is
  # the offset from b1 for the seven vertical modes and is unused for the
  # rest. "0000001" is the prefix of the extension codes, which this decoder
  # refuses rather than guesses at.
  set Mode {
    1       {V 0}    011     {V 1}    010     {V -1}
    001     {H 0}    0001    {P 0}
    000011  {V 2}    000010  {V -2}   0000011 {V 3}    0000010 {V -3}
    0000001 {X 0}
  }
  # Ascending, so that a lookup can stop at the first code that fits and
  # every one of the three tables is walked the same way. The code sets are
  # prefix-free, so the first hit is the only hit.
  foreach {name table} [list WhiteLengths $White \
      BlackLengths $Black ModeLengths $Mode] {
    set seen {}
    foreach code [dict keys $table] {
      dict set seen [string length $code] 1
    }
    set $name [lsort -integer [dict keys $seen]]
  }
  return
}

# An end-of-line code is eleven or more zero bits followed by a one (T.4
# 4.1.2), the "or more" being the fill bits an encoder may put in front of it.
# Returns the position after the code, or -1 where no EOL stands at AT.
#
# Written with [string first] rather than with a loop over the bits: fill can
# run to the end of a byte-aligned line, and a scan that walks it one
# character at a time is the difference between a second and a minute over a
# page. It is also the reason this probe is safe to call anywhere - no code of
# either table carries eleven leading zeros, so a position that does is an EOL
# or is broken.
proc ::tclpdf::filterCcitt::Eol {bitsVar at total} {
  upvar 1 $bitsVar bits
  set one [string first 1 $bits $at]
  if {$one < 0 || $one >= $total} {
    return -1
  }
  if {$one - $at < 11} {
    return -1
  }
  return [expr {$one + 1}]
}

# One run length: makeup codes add up until a terminating code closes the run
# (T.4 4.1.3). Returns {run newAt}, or an empty list where the bits spell no
# code or the data ran out inside one.
# After a damaged row: forward to the next end-of-line code, so that a stream
# which carries them can pick itself up again. Returns the position where that
# code's zeros begin, so the caller's own EOL probe reads it as one, or the end
# of the data where none follows. Without this, -damagedrowsbeforeerror could
# only ever tolerate the LAST row: everything after a row that went wrong is
# read at the wrong bit offset and goes wrong too.
#
# The loop steps to just after each one bit it finds, so its position strictly
# grows and the scan is bounded by the length of the data.
proc ::tclpdf::filterCcitt::Resync {bitsVar at total} {
  upvar 1 $bitsVar bits
  while {$at < $total} {
    set one [string first 1 $bits $at]
    if {$one < 0 || $one >= $total} {
      return $total
    }
    if {$one - $at >= 11} {
      return [expr {$one - 11}]
    }
    set at [expr {$one + 1}]
  }
  return $total
}

proc ::tclpdf::filterCcitt::Run {bitsVar at total colour} {
  upvar 1 $bitsVar bits
  variable White
  variable Black
  variable WhiteLengths
  variable BlackLengths
  if {$colour} {
    set table $Black
    set lengths $BlackLengths
  } else {
    set table $White
    set lengths $WhiteLengths
  }
  set run 0
  # THE PROGRESS PROOF of this loop. A makeup code does not close a run, so
  # without a bound a stream of them would be read for ever - and a corrupt
  # stream is exactly where that happens. T.4 allows one makeup and at most
  # one shared makeup in front of the terminating code; four passes are twice
  # what any legal run needs.
  for {set step 0} {$step < 4} {incr step} {
    set found -1
    foreach length $lengths {
      if {$at + $length > $total} {
        break
      }
      set code [string range $bits $at [expr {$at + $length - 1}]]
      if {[dict exists $table $code]} {
        set found [dict get $table $code]
        incr at $length
        break
      }
    }
    if {$found < 0} {
      return {}
    }
    incr run $found
    if {$found < 64} {
      return [list $run $at]
    }
  }
  return {}
}

# A one-dimensional row (T.4 4.1): alternating runs, white first, until the
# row is full. Returns {status changes newAt} where status is ok, short (the
# data ended inside the row) or bad (a code that is none, or a row that
# overruns its width). CHANGES is the list of changing element positions -
# the position of every colour change, which is both what the row is packed
# from and what the next row references.
proc ::tclpdf::filterCcitt::OneD {bitsVar at total columns} {
  upvar 1 $bitsVar bits
  set colour 0
  set pos 0
  set changes {}
  # A row of COLUMNS pixels holds at most COLUMNS changing elements, so this
  # bound cannot cut a legal row short - it only stops a stream of zero-length
  # runs, which advance the bit position but never the pixel position.
  set guard [expr {$columns + 2}]
  while {$pos < $columns} {
    if {[incr guard -1] < 0} {
      return [list loop $changes $at]
    }
    set step [Run bits $at $total $colour]
    if {$step eq {}} {
      return [list [expr {$at >= $total ? "short" : "bad"}] $changes $at]
    }
    lassign $step run at
    incr pos $run
    if {$pos > $columns} {
      return [list bad $changes $at]
    }
    lappend changes $pos
    set colour [expr {!$colour}]
  }
  return [list ok $changes $at]
}

# A two-dimensional row (T.4 4.2, T.6 2): every changing element is coded
# relative to the row above. B1 is the first changing element on the reference
# row right of A0 whose colour is opposite to the colour at A0, B2 the one
# after it. The reference row is a list of changing elements, so B1 is found
# by index: an even index changes to black, an odd one to white, which makes
# the parity of the index the colour it changes to.
proc ::tclpdf::filterCcitt::TwoD {bitsVar at total columns reference} {
  upvar 1 $bitsVar bits
  variable Mode
  variable ModeLengths
  set colour 0
  set a0 -1
  set changes {}
  set refCount [llength $reference]
  # The reference index only ever moves forward, because A0 only ever moves
  # forward - which is what keeps this a linear walk rather than a search per
  # changing element.
  set ri 0
  set guard [expr {$columns + 2}]
  while {$a0 < $columns} {
    if {[incr guard -1] < 0} {
      return [list loop $changes $at]
    }
    if {$at >= $total} {
      return [list short $changes $at]
    }
    while {$ri < $refCount && [lindex $reference $ri] <= $a0} {
      incr ri
    }
    set b1i $ri
    if {($b1i % 2) != $colour} {
      incr b1i
    }
    if {$b1i < $refCount} {
      set b1 [lindex $reference $b1i]
    } else {
      set b1 $columns
    }
    if {$b1i + 1 < $refCount} {
      set b2 [lindex $reference [expr {$b1i + 1}]]
    } else {
      set b2 $columns
    }
    set mode {}
    foreach length $ModeLengths {
      if {$at + $length > $total} {
        break
      }
      set code [string range $bits $at [expr {$at + $length - 1}]]
      if {[dict exists $Mode $code]} {
        set mode [dict get $Mode $code]
        incr at $length
        break
      }
    }
    if {$mode eq {}} {
      # Eleven zeros are an EOL, not a broken code: a Group 4 stream ends
      # with EOFB and a mixed Group 3 stream may carry one per row, and
      # either way the row is over rather than damaged.
      if {[Eol bits $at $total] >= 0} {
        return [list short $changes $at]
      }
      return [list [expr {$at >= $total ? "short" : "bad"}] $changes $at]
    }
    lassign $mode kind delta
    switch -- $kind {
      P {
        # Pass: the run of the current colour reaches past b2, and no
        # changing element is recorded - the colour does not change here.
        set a0 $b2
      }
      H {
        # Horizontal: two runs in a row, the current colour first. A0 is
        # -1 before the first element and the runs count from 0 there.
        set start [expr {$a0 < 0 ? 0 : $a0}]
        set first [Run bits $at $total $colour]
        if {$first eq {}} {
          return [list [expr {$at >= $total ? "short" : "bad"}] $changes $at]
        }
        lassign $first run at
        set a1 [expr {$start + $run}]
        set second [Run bits $at $total [expr {!$colour}]]
        if {$second eq {}} {
          return [list [expr {$at >= $total ? "short" : "bad"}] $changes $at]
        }
        lassign $second run at
        set a2 [expr {$a1 + $run}]
        if {$a1 > $columns} {
          set a1 $columns
        }
        if {$a2 > $columns} {
          set a2 $columns
        }
        lappend changes $a1 $a2
        set a0 $a2
      }
      V {
        set a1 [expr {$b1 + $delta}]
        if {$a1 < 0} {
          return [list bad $changes $at]
        }
        if {$a1 > $columns} {
          set a1 $columns
        }
        lappend changes $a1
        set a0 $a1
        set colour [expr {!$colour}]
      }
      default {
        # 0000001 is the prefix of the extension codes (T.4 table 4), which
        # carry uncompressed mode among other things. Refused by name rather
        # than guessed at: an extension read as run lengths produces a page
        # that looks decoded and is noise.
        return -code error -errorcode {TCLPDF FILTER CCITT EXTENSION} \
            "tclpdf: the fax data use a two-dimensional extension code, which\
            this decoder does not read - decode the image with a fax tool and\
            hand over the pixels"
      }
    }
  }
  return [list ok $changes $at]
}

# Changing elements to pixels. The row starts white and every element flips
# the colour; WHITE and BLACK are the characters "0" and "1" the other way
# round, which is all /BlackIs1 amounts to.
proc ::tclpdf::filterCcitt::Pack {changes columns white black} {
  set pos 0
  set bit $white
  foreach change $changes {
    if {$change > $columns} {
      set change $columns
    }
    if {$change > $pos} {
      append row [string repeat $bit [expr {$change - $pos}]]
      set pos $change
    }
    set bit [expr {$bit eq $white ? $black : $white}]
  }
  if {$pos < $columns} {
    append row [string repeat $bit [expr {$columns - $pos}]]
  }
  # A row occupies a whole number of bytes (7.4.6). The padding carries no
  # picture and is written as zero.
  return $row[string repeat 0 [expr {(8 - $columns % 8) % 8}]]
}

proc ::tclpdf::filterCcitt::decode {bytes args} {
  set options [::tclpdf::option parse {
    columns 1728
    rows 0
    k 0
    blackis1 0
    encodedbytealign 0
    endofline 0
    endofblock 1
    damagedrowsbeforeerror 0
  } $args decodeCcitt]
  # The context is the name the CALLER typed, not the one this procedure
  # carries: an unknown option is reported "for decodeCcitt" because that is
  # the spelling of the bridge in filter.tcl, which is where every caller
  # comes in.
  set columns [dict get $options columns]
  set rows [dict get $options rows]
  set k [dict get $options k]
  if {![string is entier -strict $columns] || $columns < 1} {
    return -code error -errorcode [list TCLPDF FILTER CCITT COLUMNS $columns] \
        "tclpdf: -columns is 1 or more, got \"$columns\""
  }
  # Not a limit of the coding - T.4 4.1.4 chains makeup codes as far as one
  # likes - but of what may be trusted from outside. A /Columns of a million
  # turns a few kilobytes of fax into gigabytes of pixels, and no scan is
  # that wide: 65536 pixels is a metre and a half at 1200 dpi.
  if {$columns > 65536} {
    return -code error -errorcode [list TCLPDF FILTER CCITT COLUMNS $columns] \
        "tclpdf: -columns is at most 65536, got \"$columns\" - a wider row is\
        not a scan but a stream that would decode to more pixels than it has\
        bits"
  }
  if {![string is entier -strict $rows] || $rows < 0} {
    return -code error -errorcode [list TCLPDF FILTER CCITT ROWS $rows] \
        "tclpdf: -rows is 0 (unknown) or more, got \"$rows\""
  }
  if {![string is entier -strict $k]} {
    return -code error -errorcode [list TCLPDF FILTER CCITT K $k] \
        "tclpdf: -k is an integer - below zero Group 4, zero Group 3\
        one-dimensional, above zero Group 3 mixed - got \"$k\""
  }
  set damagedLimit [dict get $options damagedrowsbeforeerror]
  if {![string is entier -strict $damagedLimit] || $damagedLimit < 0} {
    return -code error \
        -errorcode [list TCLPDF FILTER CCITT DAMAGEDROWS $damagedLimit] \
        "tclpdf: -damagedrowsbeforeerror is 0 or more, got \"$damagedLimit\""
  }
  foreach name {blackis1 encodedbytealign endofline endofblock} {
    set value [dict get $options $name]
    if {![string is boolean -strict $value]} {
      return -code error \
          -errorcode [list TCLPDF FILTER CCITT [string toupper $name] $value] \
          "tclpdf: -$name is a boolean, got \"$value\""
    }
    set $name [expr {!!$value}]
  }
  Tables
  if {$blackis1} {
    set white 0
    set black 1
  } else {
    set white 1
    set black 0
  }
  binary scan $bytes B* bits
  set total [string length $bits]
  set at 0
  set count 0
  set damaged 0
  set out {}
  set reference [list $columns $columns]
  while {$rows == 0 || $count < $rows} {
    if {$encodedbytealign} {
      # Each row begins on a byte boundary (Table 11), and with K above zero
      # that boundary is in front of the EOL, not behind it.
      set at [expr {($at + 7) & ~7}]
    }
    if {$at >= $total} {
      break
    }
    # Zeros to the end are the padding of the last byte, or of several - not
    # a row. Any row still to come has to contain a one bit somewhere, since
    # every code of every table ends in one.
    if {[string first 1 $bits $at] < 0} {
      break
    }
    # Group 4 is two-dimensional throughout; Group 3 says per row, in the tag
    # bit behind the EOL, and a Group 3 stream that carries no EOL at all can
    # only be one-dimensional - there is nowhere for the tag bit to stand.
    set twoDimensional [expr {$k < 0}]
    set seenEol 0
    while {1} {
      set next [Eol bits $at $total]
      if {$next < 0} {
        break
      }
      set at $next
      incr seenEol
      if {$seenEol >= 2} {
        break
      }
      if {$k > 0} {
        if {$at >= $total} {
          break
        }
        set twoDimensional [expr {[string index $bits $at] eq "0"}]
        incr at
      }
    }
    if {$seenEol >= 2} {
      # Two end-of-line codes back to back are the end of the block: EOFB in
      # Group 4 (T.6 2.2.1), the first two of the six that make up RTC in
      # Group 3 (T.4 4.1.2). Either way nothing follows that is a row.
      break
    }
    if {$endofline && !$seenEol} {
      return -code error -errorcode {TCLPDF FILTER CCITT EOL} "tclpdf: the fax\
          data are declared with end-of-line codes and row [expr {$count + 1}]\
          begins without one - decode with -endofline false if the declaration\
          is what is wrong"
    }
    if {$at >= $total} {
      break
    }
    set began $at
    if {$twoDimensional} {
      lassign [TwoD bits $at $total $columns $reference] status changes at
    } else {
      lassign [OneD bits $at $total $columns] status changes at
    }
    if {$status eq "short" && $changes eq {}} {
      # The data ended where a row was to begin. Nothing was lost.
      break
    }
    if {$status ne "ok"} {
      incr damaged
      if {$damaged > $damagedLimit} {
        switch -- $status {
          short {
            set word SHORT
            set what "ends before the row is full"
          }
          loop {
            # The row consumed bits and produced no pixels - zero-length runs
            # in horizontal mode, which advance the reader and not the row.
            # Bounded rather than walked: this is the shape an endless loop
            # in a fax decoder takes.
            set word LOOP
            set what "codes more colour changes than a row of $columns pixels\
                can hold"
          }
          default {
            set word CODE
            set what "holds a code that is none"
          }
        }
        return -code error -errorcode [list TCLPDF FILTER CCITT $word] \
            "tclpdf: row [expr {$count + 1}] of the fax data $what - raise\
            -damagedrowsbeforeerror to take the page as far as it goes"
      }
      if {$seenEol} {
        set at [Resync bits $at $total]
      }
    }
    append out [Pack $changes $columns $white $black]
    incr count
    set reference [linsert $changes end $columns $columns]
    if {$at <= $began} {
      # THE PROGRESS PROOF of the row loop, and the one guard in this decoder
      # that no input has been able to make fire: every mode code and every
      # run code is at least one bit wide, the loop only reaches here with
      # bits left, and a row that ends where it began therefore cannot
      # happen. It stands because the argument is the kind that stops being
      # true when somebody adds a mode that consumes nothing, and because a
      # fax decoder that walks in a circle over a broken stream is the
      # failure this whole file is written against.
      return -code error -errorcode {TCLPDF FILTER CCITT PROGRESS} "tclpdf:\
          row $count of the fax data consumed no bits - the stream is broken\
          in a way this decoder will not walk in a circle over"
    }
  }
  if {$rows > 0 && $count < $rows} {
    return -code error -errorcode [list TCLPDF FILTER CCITT TRUNCATED] \
        "tclpdf: the fax data hold $count of the $rows rows they declare -\
        decode with -rows 0 to take what is there"
  }
  if {!$count} {
    return -code error -errorcode {TCLPDF FILTER CCITT EMPTY} \
        "tclpdf: the fax data hold no row at all - check -k, which says\
        Group 4 below zero and Group 3 from zero up"
  }
  return [binary format B* $out]
}

package provide tclpdf::filterCcitt 1.0
