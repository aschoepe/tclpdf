#
# tclpdf - PDF generation for Tcl
#
# font - embedding TrueType faces (9.7)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The public face of the font topic. sfnt.tcl reads the file, subset.tcl
# reduces it, and this module turns the result into PDF objects. Nothing
# outside loads those two.
#
#   $doc font embed hausschrift examples/assets/fonts/DejaVuSans.ttf
#   $doc font -family hausschrift -size 11
#   $doc text "Rechnung 1.234,56 EUR" -at {20 30}
#
# Why Type0/Identity-H and not a simple TrueType font: a simple font addresses
# 256 codes through an encoding, and every document needing more than that -
# a Greek quotation, a Polish name, a currency symbol outside WinAnsi - has to
# juggle encodings. Identity-H addresses glyphs directly with two bytes, so
# the question never arises. Measured in the corpus: 51.9 % of the documents
# use it.
#
# The price is /ToUnicode. With Identity-H the text in the file consists of
# glyph numbers, which mean nothing outside this one font - without a ToUnicode
# CMap the text can be neither copied nor searched, and nothing reports that
# either. It is written unconditionally.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::sfnt 1.0-
package require tclpdf::subset 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::font {}

oo::define ::tclpdf::document::document {

  # $doc font embed <alias> <path> ?-subset 0?
  # $doc font names                 -> the embedded aliases
  # $doc font info <alias>          -> what the file says about itself
  #
  # Everything else goes to the text module - "font" without a subcommand is
  # the font state (-family, -size, ...).
  method FontEmbed {alias path args} {
    set options [::tclpdf::option parse {subset 1} $args "font embed"]
    set fonts [my state fonts]
    if {[dict exists $fonts $alias]} {
      return -code error "tclpdf: a font named \"$alias\" is already embedded"
    }
    set parsed [::tclpdf::sfnt read $path]

    dict set fonts $alias [dict create \
        path $path parsed $parsed subset [dict get $options subset] \
        used {} number {}]
    my state fonts $fonts

    if {[my state fontHooked] eq {}} {
      my state fontHooked 1
      my onSelf beforeWrite FontWrite
    }
    return $alias
  }

  method FontNames {} {
    return [dict keys [my state fonts]]
  }

  # What the file says about itself - including the embedding permission.
  method FontInfo {alias} {
    set fonts [my state fonts]
    if {![dict exists $fonts $alias]} {
      return -code error "tclpdf: no embedded font named \"$alias\""
    }
    set parsed [dict get $fonts $alias parsed]
    return [dict create \
        family [expr {[dict exists [dict get $parsed names] family] ?
            [dict get $parsed names family] : {}}] \
        postScript [expr {[dict exists [dict get $parsed names] postScript] ?
            [dict get $parsed names postScript] : {}}] \
        glyphs [dict get $parsed numGlyphs] \
        unitsPerEm [dict get $parsed unitsPerEm] \
        fsType [dict get $parsed fsType] \
        permission [::tclpdf::sfnt permission [dict get $parsed fsType]] \
        characters [dict size [dict get $parsed cmap]]]
  }

  # Encode text as two-byte glyph numbers and record which glyphs were used.
  #
  # A character the font has no glyph for is an ERROR. This is the only place
  # in the chain that notices: the reader shows a blank, the validator says
  # nothing, and the recipient sees an invoice with a gap where the amount
  # should be.
  method FontEncode {alias text} {
    set fonts [my state fonts]
    set entry [dict get $fonts $alias]
    set cmap [dict get $entry parsed cmap]
    set used [dict get $entry used]
    set bytes {}
    set position 0
    foreach char [split $text {}] {
      set code [scan $char %c]
      if {![dict exists $cmap $code]} {
        return -code error "tclpdf: the font \"$alias\" has no glyph for\
            U+[format %04X $code] (position $position) - it cannot be written\
            with this face"
      }
      set glyph [dict get $cmap $code]
      dict set used $glyph $code
      append bytes [binary format Su $glyph]
      incr position
    }
    dict set entry used $used
    dict set fonts $alias $entry
    my state fonts $fonts
    return $bytes
  }

  # The width of a string in points, at a given size.
  #
  # With kerning the pair adjustments belong in here and not only in the
  # drawing: the line breaker, the column widths and the text on a path all
  # measure through this method, and a line measured without the kerning it is
  # later drawn with breaks in the wrong place.
  method FontWidth {alias text size {kerning 0}} {
    set entry [dict get [my state fonts] $alias]
    set parsed [dict get $entry parsed]
    set cmap [dict get $parsed cmap]
    set units [dict get $parsed unitsPerEm]
    set total 0
    foreach char [split $text {}] {
      set code [scan $char %c]
      if {[dict exists $cmap $code]} {
        set total [expr {$total + [::tclpdf::sfnt advance $parsed \
            [dict get $cmap $code]]}]
      }
    }
    set points [expr {double($total) * $size / $units}]
    if {$kerning} {
      set thousandths 0
      foreach adjust [my FontKern $alias $text] {
        set thousandths [expr {$thousandths + $adjust}]
      }
      set points [expr {$points + $thousandths * $size / 1000.0}]
    }
    return $points
  }

  # The kerning of a string: one adjustment per gap between two characters,
  # in thousandths of the em - the unit a TJ number is written in, so that the
  # measurement and the drawing cannot drift apart through two conversions.
  #
  # A string of n characters yields n-1 numbers, most of them zero. Characters
  # the font has no glyph for end the pair rather than being skipped over:
  # kerning applies between neighbours, and [FontEncode] refuses such a string
  # anyway before it is ever drawn.
  method FontKern {alias text} {
    set count [string length $text]
    if {$count < 2} {
      return {}
    }
    set entry [dict get [my state fonts] $alias]
    set parsed [dict get $entry parsed]
    set state [my FontKernState $alias]
    set adjustments {}
    if {[::tclpdf::kern origin $state] eq "none"} {
      # Nothing to look up - hand back zeros rather than an empty list, so
      # every caller can index by gap without a special case.
      for {set index 1} {$index < $count} {incr index} {
        lappend adjustments 0
      }
      return $adjustments
    }
    set cmap [dict get $parsed cmap]
    set units [dict get $parsed unitsPerEm]
    set previous -1
    set first 1
    foreach char [split $text {}] {
      set code [scan $char %c]
      set glyph [expr {[dict exists $cmap $code] ? [dict get $cmap $code] : -1}]
      if {!$first} {
        if {$previous >= 0 && $glyph >= 0} {
          set value [::tclpdf::kern value $state $previous $glyph]
          lappend adjustments [expr {$value * 1000.0 / $units}]
        } else {
          lappend adjustments 0
        }
      }
      set first 0
      set previous $glyph
    }
    return $adjustments
  }

  # The prepared kerning of one font, read once and kept.
  #
  # Loaded here rather than at the top of the file: a document that never asks
  # for kerning never parses a GPOS table, and that table is the largest thing
  # in many fonts.
  method FontKernState {alias} {
    set fonts [my state fonts]
    set entry [dict get $fonts $alias]
    if {[dict exists $entry kern]} {
      return [dict get $entry kern]
    }
    package require tclpdf::kern 1.0-
    set state [::tclpdf::kern build [dict get $entry parsed]]
    dict set entry kern $state
    dict set fonts $alias $entry
    my state fonts $fonts
    return $state
  }

  # The resource name, registered on first use.
  method FontResource {alias} {
    set name FE[string map {{ } {}} $alias]
    if {[my resource Font $name] eq {}} {
      set fonts [my state fonts]
      set entry [dict get $fonts $alias]
      # Reserved now, filled at write time - only then is it known which
      # glyphs were used.
      dict set entry number [[my writer] reserve]
      dict set fonts $alias $entry
      my state fonts $fonts
      my resource Font $name [[my writer] ref [dict get $entry number]]
    }
    return [::tclpdf::pdfObj name $name]
  }

  # -- writing ------------------------------------------------------------

  method FontWrite {} {
    dict for {alias entry} [my state fonts] {
      if {[dict get $entry number] eq {}} {
        # Embedded but never used - no objects for it.
        continue
      }
      my FontWriteOne $alias $entry
    }
    return
  }

  method FontWriteOne {alias entry} {
    set writer [my writer]
    set parsed [dict get $entry parsed]
    set used [dict get $entry used]
    set units [dict get $parsed unitsPerEm]

    # Subset or whole face. Either way the glyph numbers used in the content
    # stream have to match the file that is embedded.
    if {[dict get $entry subset]} {
      set built [::tclpdf::subset build $parsed [dict keys $used]]
      set fontBytes [dict get $built bytes]
      set mapping [dict get $built glyphs]
    } else {
      set fontBytes [dict get $parsed bytes]
      set mapping {}
      foreach glyph [dict keys $used] {
        dict set mapping $glyph $glyph
      }
    }

    # The font file itself. /Length1 is the UNCOMPRESSED length and is
    # required for FontFile2 (9.9).
    set fontFileNumber [$writer addStream \
        [list Length1 [string length $fontBytes] Filter /FlateDecode] \
        [::tclpdf::filter encodeFlate $fontBytes]]

    # Derived once and passed on: the name has to be the SAME in all three
    # places (descriptor, CID font, Type0 font), and deriving it three times is
    # how two of them would one day disagree.
    set baseName [my FontBaseName $parsed $alias [dict get $entry subset]]

    set descriptorNumber [$writer add [::tclpdf::pdfObj dictionary \
        [my FontDescriptorPairs $parsed $baseName [$writer ref $fontFileNumber]]]]

    # The CID font.
    #
    # The CID is the glyph number of the ORIGINAL face, which is what the
    # content stream carries - it is written long before the subset exists and
    # cannot know the new numbering. CIDToGIDMap is the table that bridges the
    # two, and this is exactly what it is for.
    #
    # Declaring /Identity here instead is the trap: it says "CID equals glyph
    # number in the embedded file", which is false as soon as anything is
    # subsetted. The document then renders - with the wrong glyphs, and the
    # extracted text is noise. qpdf reports nothing, pdffonts still says the
    # ToUnicode map is present.
    set cidToGidNumber [$writer addStream {Filter /FlateDecode} \
        [::tclpdf::filter encodeFlate [my FontCidToGid $mapping]]]
    set descendantNumber [$writer add [::tclpdf::pdfObj dictionary [list \
        Type /Font Subtype /CIDFontType2 \
        BaseFont [::tclpdf::pdfObj name $baseName] \
        CIDSystemInfo [::tclpdf::pdfObj dictionary [list \
            Registry [::tclpdf::pdfObj str Adobe] \
            Ordering [::tclpdf::pdfObj str Identity] \
            Supplement 0]] \
        FontDescriptor [$writer ref $descriptorNumber] \
        DW 1000 \
        W [my FontWidthArray $parsed $used $units] \
        CIDToGIDMap [$writer ref $cidToGidNumber]]]]

    set toUnicodeNumber [$writer addStream {Filter /FlateDecode} \
        [::tclpdf::filter encodeFlate [my FontToUnicode $used]]]

    $writer put [dict get $entry number] [::tclpdf::pdfObj dictionary [list \
        Type /Font Subtype /Type0 \
        BaseFont [::tclpdf::pdfObj name $baseName] \
        Encoding /Identity-H \
        DescendantFonts [::tclpdf::pdfObj arr [list [$writer ref $descendantNumber]]] \
        ToUnicode [$writer ref $toUnicodeNumber]]]
    return
  }

  method FontBaseName {parsed alias {subsetted 1}} {
    if {[dict exists [dict get $parsed names] postScript]} {
      set name [dict get $parsed names postScript]
    } else {
      set name $alias
    }
    # The six-letter tag says "this is a subset" (9.9.2) - so a face embedded
    # WHOLE, through "font embed -subset 0", must not carry one. It did until
    # now, which named a complete DejaVuSans a subset of itself: a reader
    # merging fonts across documents is told to keep two incompatible copies,
    # and a preflight tool is entitled to reject the file.
    if {!$subsetted} {
      return [string map {{ } {}} $name]
    }
    # The tag is derived from the name so that the same font gives the same one.
    set tag {}
    set seed 0
    foreach char [split $name {}] {
      incr seed [scan $char %c]
    }
    for {set index 0} {$index < 6} {incr index} {
      append tag [format %c [expr {65 + ($seed + $index * 7) % 26}]]
    }
    return "$tag+[string map {{ } {}} $name]"
  }

  method FontDescriptorPairs {parsed baseName fontFileRef} {
    set units [dict get $parsed unitsPerEm]
    lassign [dict get $parsed bbox] xMin yMin xMax yMax
    set scale [expr {1000.0 / $units}]
    # Symbolic (bit 3) rather than nonsymbolic: the font is addressed by glyph
    # id, so no standard encoding applies to it.
    set flags 4
    if {[dict get $parsed macStyle] & 2} {
      incr flags 64
    }
    return [list Type /FontDescriptor \
        FontName [::tclpdf::pdfObj name $baseName] \
        Flags $flags \
        FontBBox [::tclpdf::pdfObj arr [list \
            [::tclpdf::pdfObj num [expr {$xMin * $scale}]] \
            [::tclpdf::pdfObj num [expr {$yMin * $scale}]] \
            [::tclpdf::pdfObj num [expr {$xMax * $scale}]] \
            [::tclpdf::pdfObj num [expr {$yMax * $scale}]]]] \
        ItalicAngle 0 \
        Ascent [::tclpdf::pdfObj num [expr {[dict get $parsed ascender] * $scale}]] \
        Descent [::tclpdf::pdfObj num [expr {[dict get $parsed descender] * $scale}]] \
        CapHeight [::tclpdf::pdfObj num [expr {[dict get $parsed ascender] * $scale}]] \
        StemV 80 \
        FontFile2 $fontFileRef]
  }

  # The /W array: widths per CID, in 1/1000 em. Written as individual entries
  # rather than as ranges - a range that is one CID off shifts every following
  # width, and the saving is a few dozen bytes.
  method FontWidthArray {parsed used units} {
    set scale [expr {1000.0 / $units}]
    set entries {}
    foreach glyph [lsort -integer [dict keys $used]] {
      set width [expr {[::tclpdf::sfnt advance $parsed $glyph] * $scale}]
      lappend entries $glyph [::tclpdf::pdfObj arr [list [::tclpdf::pdfObj num $width]]]
    }
    return [::tclpdf::pdfObj arr $entries]
  }

  # CID to glyph id in the embedded file: two bytes per CID, from 0 to the
  # highest one used. Unused positions hold 0, which is .notdef - a reader
  # that lands there shows the fallback rather than a random glyph.
  method FontCidToGid {mapping} {
    set highest 0
    dict for {original new} $mapping {
      if {$original > $highest} {
        set highest $original
      }
    }
    set bytes {}
    for {set cid 0} {$cid <= $highest} {incr cid} {
      append bytes [binary format Su [expr {[dict exists $mapping $cid] ?
          [dict get $mapping $cid] : 0}]]
    }
    return $bytes
  }

  # The ToUnicode CMap (9.10.3). Without it the text is glyph numbers and
  # cannot be copied or searched - and no tool reports the omission.
  method FontToUnicode {used} {
    set lines {}
    foreach glyph [lsort -integer [dict keys $used]] {
      set cid $glyph
      set code [dict get $used $glyph]
      if {$code > 0xFFFF} {
        # Outside the BMP: the target is a surrogate pair.
        set value [expr {$code - 0x10000}]
        set target [format %04X%04X [expr {0xD800 | ($value >> 10)}] \
            [expr {0xDC00 | ($value & 0x3FF)}]]
      } else {
        set target [format %04X $code]
      }
      lappend lines "<[format %04X $cid]> <$target>"
    }
    set map "/CIDInit /ProcSet findresource begin\n"
    append map "12 dict begin\nbegincmap\n"
    append map "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
    append map "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
    append map "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
    # bfchar takes at most 100 entries per block (9.10.3).
    set total [llength $lines]
    for {set start 0} {$start < $total} {incr start 100} {
      set chunk [lrange $lines $start [expr {$start + 99}]]
      append map "[llength $chunk] beginbfchar\n[join $chunk \n]\nendbfchar\n"
    }
    append map "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    return $map
  }
}

package provide tclpdf::font 1.2
