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
    set options [::tclpdf::option parse {subset 1 metrics {}} $args "font embed"]
    set fonts [my state fonts]
    if {[dict exists $fonts $alias]} {
      return -code error "tclpdf: a font named \"$alias\" is already embedded"
    }
    # The file says what it is; the extension does not. Read once and let both
    # parsers work on the same bytes rather than opening it twice.
    set bytes [::tclpdf::io read $path]
    if {[string index $bytes 0] eq "\x80" || [string range $bytes 0 1] eq "%!"} {
      dict set fonts $alias [my FontEmbedType1 $alias $path $bytes \
          [dict get $options metrics]]
    } else {
      set parsed [::tclpdf::sfnt parse $bytes]
      dict set fonts $alias [dict create \
          kind truetype \
          path $path parsed $parsed subset [dict get $options subset] \
          used {} number {}]
    }
    my state fonts $fonts

    if {[my state fontHooked] eq {}} {
      my state fontHooked 1
      my onSelf beforeWrite FontWrite
    }
    return $alias
  }

  # A Type 1 program plus the metrics beside it.
  #
  # The metrics are a SEPARATE FILE and there is no way around it: the widths
  # of a Type 1 face live in its charstrings, behind the eexec encryption, and
  # reading them would be the subsetting work this way exists to avoid. So the
  # AFM is looked for next to the program under the same base name, and
  # -metrics names it where it sits elsewhere.
  method FontEmbedType1 {alias path bytes metricsPath} {
    package require tclpdf::type1 1.0-
    set program [::tclpdf::type1 parse $bytes]
    if {$metricsPath eq {}} {
      set metricsPath [file rootname $path].afm
    }
    if {![file readable $metricsPath]} {
      return -code error "tclpdf: a Type 1 font needs its metrics -\
          \"$metricsPath\" is not readable. Put the AFM beside the font or\
          name it with -metrics"
    }
    set metrics [::tclpdf::type1 metrics $metricsPath]
    return [dict create \
        kind type1 \
        path $path metricsPath $metricsPath \
        program $program metrics $metrics \
        widths [::tclpdf::type1 widths $metrics] \
        names [::tclpdf::type1 names $metrics] \
        subset 0 used {} number {}]
  }

  # Which of the two roads a face takes. Everything that has to tell them
  # apart asks here rather than testing for a key.
  method FontKind {alias} {
    return [dict get [my state fonts] $alias kind]
  }

  # The ascender of an embedded face at a given size, in points.
  #
  # Asked here rather than read out of the entry, because the two kinds keep
  # it in different places and different units: a TrueType face in hhea, in
  # its own units per em, a Type 1 face in the AFM beside it, already in
  # 1/1000 em. Whoever needs the number should not have to know which.
  method FontAscender {alias size} {
    set entry [dict get [my state fonts] $alias]
    if {[dict get $entry kind] eq "type1"} {
      # ZERO counts as absent, not as a measurement. The URW metrics in this
      # tree write "Ascender 0" and "Descender 0" - the fields are there and
      # say nothing. Read literally, every line anchored at its top sat one
      # full ascender too high, which in a table put the text on the rule
      # above it. A face has no zero ascender; the bounding box is measured
      # from the same outlines and is the honest substitute.
      set ascent [dict get $entry metrics ascender]
      if {$ascent eq {} || $ascent == 0} {
        set ascent [lindex [dict get $entry metrics bbox] 3]
      }
      return [expr {double($ascent) * $size / 1000.0}]
    }
    set parsed [dict get $entry parsed]
    return [expr {double([dict get $parsed ascender]) * $size
        / [dict get $parsed unitsPerEm]}]
  }

  # A Type 1 face is addressed by single bytes through WinAnsiEncoding, so it
  # is encoded by the same code as the standard fourteen - only the widths
  # come from its own metrics. [afm encodeWidths] is that shared road; what
  # differs is which face the message names.
  method FontType1Encode {alias text} {
    return [::tclpdf::afm encodeWidths \
        [dict get [my state fonts] $alias widths] $text 0 \
        "the embedded Type 1 face \"$alias\"" \
        " - embed a TrueType face for this text"]
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
    if {[dict get $fonts $alias kind] eq "type1"} {
      set metrics [dict get $fonts $alias metrics]
      # No fsType: a Type 1 program carries no embedding permission at all.
      # That is a property of the format, not something unknown about this
      # file, so it is reported as such rather than guessed at.
      return [dict create \
          family [dict get $metrics family] \
          postScript [dict get $metrics name] \
          glyphs [dict size [dict get $metrics widths]] \
          unitsPerEm 1000 \
          fsType {} \
          permission "not stated - Type 1 has no fsType" \
          characters [dict size [dict get $fonts $alias names]]]
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

  # A string as the glyphs that will be drawn for it.
  #
  # THE single place that turns characters into glyphs. Measuring, kerning and
  # encoding all go through it, because with ligatures they can no longer
  # agree by accident: three characters may become one glyph, and a width
  # counted per character would then disagree with what is drawn.
  #
  # The result is a list of entries {glyph codes}, where codes are the
  # character code points the glyph stands for - one for an ordinary glyph,
  # several for a ligature. That provenance is not decoration: it is what the
  # ToUnicode CMap is built from, and without it a ligature would extract as
  # one unknown character instead of "ffi".
  #
  # A character the font has no glyph for is an ERROR. This is the only place
  # in the chain that notices: the reader shows a blank, the validator says
  # nothing, and the recipient sees an invoice with a gap where the amount
  # should be.
  method FontRun {alias text {ligatures 0} {unshaped 0}} {
    # Refused BEFORE anything is looked up: a script that needs shaping would
    # otherwise come out as isolated glyphs in the wrong order, which looks
    # like text and is not. Same rule as the missing glyph below, and the same
    # reason - this is the only place in the chain that notices.
    if {!$unshaped} {
      package require tclpdf::shaping 1.0-
      set finding [::tclpdf::shaping needed $text]
      if {[llength $finding]} {
        return -code error [::tclpdf::shaping message $finding]
      }
    }
    set entry [dict get [my state fonts] $alias]
    set cmap [dict get $entry parsed cmap]
    set run {}
    set position 0
    foreach char [split $text {}] {
      set code [scan $char %c]
      # A soft hyphen is a permission, not a character: it says a word may be
      # broken here. The breaker has already put a real hyphen wherever it took
      # the offer, so from here on the mark itself has to vanish - it must not
      # reach a glyph, a width or the ToUnicode map. A face that HAS a glyph at
      # U+00AD would otherwise set a hyphen in the middle of an unbroken word,
      # which is how it looked before: "Silben-trennung", measured 4.33 pt
      # wider than the same word without the mark.
      if {$code == 0x00AD} {
        incr position
        continue
      }
      if {![dict exists $cmap $code]} {
        return -code error "tclpdf: the font \"$alias\" has no glyph for\
            U+[format %04X $code] (position $position) - it cannot be written\
            with this face"
      }
      lappend run [list [dict get $cmap $code] [list $code]]
      incr position
    }
    if {$ligatures && [llength $run] > 1} {
      set run [::tclpdf::liga apply [my FontLigaState $alias] $run]
    }
    return $run
  }

  # Two-byte glyph numbers for a run, recording which glyphs were used and
  # what each of them stands for.
  #
  # One glyph can be reached in more than one way, and a ToUnicode CMap has
  # room for only one destination per CID. In DejaVu Sans glyph 5044 is both
  # the GSUB output of "ffi" and the cmap entry for U+FB03, the precomposed
  # ligature character. Whichever was written last used to win, so a document
  # that drew "office" before it drew U+FB03 extracted the word as
  # o U+FB03 c e - rendering perfectly, validating cleanly, and no longer
  # findable by searching for "office".
  #
  # The longer decomposition therefore wins, and the order stops mattering:
  # three characters say more about the glyph than one does, and "ffi" is what
  # a reader wants back from a search either way.
  #
  # This does NOT settle the older ambiguity of two characters sharing one
  # glyph through the cmap alone - Roboto maps U+0394 and U+2206 to the same
  # glyph, both lists are one long, and there is no answer that is right for
  # both. There the first one recorded stays.
  method FontRunEncode {alias run} {
    set fonts [my state fonts]
    set entry [dict get $fonts $alias]
    set used [dict get $entry used]
    set bytes {}
    foreach item $run {
      lassign $item glyph codes
      if {![dict exists $used $glyph]
          || [llength $codes] > [llength [dict get $used $glyph]]} {
        dict set used $glyph $codes
      }
      append bytes [binary format Su $glyph]
    }
    dict set entry used $used
    dict set fonts $alias $entry
    my state fonts $fonts
    return $bytes
  }

  # Encode text directly. Kept for the callers that have a string and no
  # reason to hold a run.
  method FontEncode {alias text {ligatures 0} {unshaped 0}} {
    return [my FontRunEncode $alias [my FontRun $alias $text $ligatures $unshaped]]
  }

  # The width of a prepared run, in points.
  #
  # A ligature contributes ITS advance, not the sum of the advances of the
  # characters it replaced - which is the whole point of measuring the run
  # rather than the string.
  method FontRunWidth {alias run size {kerning 0}} {
    set parsed [dict get [my state fonts] $alias parsed]
    set units [dict get $parsed unitsPerEm]
    set total 0
    foreach item $run {
      set total [expr {$total + [::tclpdf::sfnt advance $parsed \
          [lindex $item 0]]}]
    }
    set points [expr {double($total) * $size / $units}]
    if {$kerning} {
      set thousandths 0
      foreach adjust [my FontRunKern $alias $run] {
        set thousandths [expr {$thousandths + $adjust}]
      }
      set points [expr {$points + $thousandths * $size / 1000.0}]
    }
    return $points
  }

  # The kerning of a run: one adjustment per gap between two GLYPHS, in
  # thousandths of the em - the unit a TJ number is written in, so that the
  # measurement and the drawing cannot drift apart through two conversions.
  #
  # Per glyph, not per character: after "ffi" has become one glyph the pair to
  # look up is that ligature and its neighbour, and the pairs that used to sit
  # between f and f are gone with them.
  # The whole run goes down in one piece, not pair by pair: a lookup that
  # ignores marks kerns A against V across the acute between them, and a caller
  # that asked for one pair at a time could never see that pair.
  method FontRunKern {alias run} {
    if {[llength $run] < 2} {
      return {}
    }
    set glyphs {}
    foreach item $run {
      lappend glyphs [lindex $item 0]
    }
    set units [dict get [my state fonts] $alias parsed unitsPerEm]
    set adjustments {}
    foreach value [::tclpdf::kern run [my FontKernState $alias] $glyphs] {
      lappend adjustments [expr {$value * 1000.0 / $units}]
    }
    return $adjustments
  }

  # The prepared ligatures of one font, read once and kept.
  method FontLigaState {alias} {
    set fonts [my state fonts]
    set entry [dict get $fonts $alias]
    if {[dict exists $entry liga]} {
      return [dict get $entry liga]
    }
    package require tclpdf::liga 1.0-
    set state [::tclpdf::liga build [dict get $entry parsed]]
    dict set entry liga $state
    dict set fonts $alias $entry
    my state fonts $fonts
    return $state
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

  # A Type 1 face: the program goes in as it came, in the three pieces it
  # already consists of, and the widths come from the AFM.
  #
  # Nonsymbolic (bit 6, value 32) - the opposite of the TrueType road below,
  # and it follows from how the face is addressed: single bytes through
  # WinAnsiEncoding, which is a standard encoding, rather than glyph numbers.
  method FontWriteType1 {alias entry} {
    set writer [my writer]
    set program [dict get $entry program]
    set metrics [dict get $entry metrics]
    set widths [dict get $entry widths]

    set fontBytes [string cat [dict get $program clear] \
        [dict get $program encrypted] [dict get $program trailer]]
    set fontFileNumber [$writer addStream \
        [list Length1 [dict get $program length1] \
            Length2 [dict get $program length2] \
            Length3 [dict get $program length3] \
            Filter /FlateDecode] \
        [::tclpdf::filter encodeFlate $fontBytes]]

    set baseName [dict get $metrics name]
    if {$baseName eq {}} {
      set baseName [dict get $program name]
    }
    set descriptorNumber [$writer add [::tclpdf::pdfObj dictionary \
        [my FontType1DescriptorPairs $entry $baseName \
            [$writer ref $fontFileNumber]]]]

    # FirstChar to LastChar covers the whole encoding rather than only what
    # was used: nothing is subsetted here, every one of those glyphs is in the
    # file, and a Widths array that starts where the text happens to start
    # would have to be rebuilt whenever the text changes.
    set first 32
    set last 255
    set entries {}
    for {set code $first} {$code <= $last} {incr code} {
      lappend entries [::tclpdf::pdfObj num [lindex $widths $code]]
    }
    $writer put [dict get $entry number] [::tclpdf::pdfObj dictionary [list \
        Type /Font \
        Subtype /Type1 \
        BaseFont [::tclpdf::pdfObj name $baseName] \
        FirstChar $first \
        LastChar $last \
        Widths [$writer ref [$writer add [::tclpdf::pdfObj arr $entries]]] \
        Encoding /WinAnsiEncoding \
        FontDescriptor [$writer ref $descriptorNumber]]]
    return
  }

  method FontType1DescriptorPairs {entry baseName fontFileRef} {
    set metrics [dict get $entry metrics]
    set program [dict get $entry program]
    set bbox [dict get $metrics bbox]
    if {![llength $bbox]} {
      set bbox [dict get $program bbox]
    }
    if {[llength $bbox] != 4} {
      set bbox {-200 -250 1000 1000}
    }
    set italic [dict get $metrics italicAngle]
    # Nonsymbolic, plus italic (bit 7) and fixed pitch (bit 1) where the
    # metrics say so.
    set flags 32
    if {$italic != 0} {
      incr flags 64
    }
    if {[dict get $metrics fixedPitch]} {
      incr flags 1
    }
    # Ascent, descent and cap height are required (9.8.1 Table 122). An AFM
    # may leave any of them out - or write a zero, which the URW metrics here
    # do and which means the same thing. The bounding box is then the honest
    # substitute, measured from the same outlines.
    set ascent [dict get $metrics ascender]
    if {$ascent eq {} || $ascent == 0} {
      set ascent [lindex $bbox 3]
    }
    set descent [dict get $metrics descender]
    if {$descent eq {} || $descent == 0} {
      set descent [lindex $bbox 1]
    }
    set capHeight [dict get $metrics capHeight]
    if {$capHeight eq {} || $capHeight == 0} {
      set capHeight $ascent
    }
    # StemV has no counterpart in an AFM that is guaranteed to be there -
    # StdVW is optional and both faces in this tree omit it. 80 is the value
    # this package already writes for TrueType; a wrong StemV affects hinting
    # hints, not the glyphs.
    set stemV [dict get $metrics stemV]
    if {$stemV eq {}} {
      set stemV 80
    }
    return [list Type /FontDescriptor \
        FontName [::tclpdf::pdfObj name $baseName] \
        Flags $flags \
        FontBBox [::tclpdf::pdfObj arr [lmap number $bbox {
          ::tclpdf::pdfObj num $number
        }]] \
        ItalicAngle [::tclpdf::pdfObj num $italic] \
        Ascent [::tclpdf::pdfObj num $ascent] \
        Descent [::tclpdf::pdfObj num $descent] \
        CapHeight [::tclpdf::pdfObj num $capHeight] \
        StemV $stemV \
        FontFile $fontFileRef]
  }

  method FontWriteOne {alias entry} {
    if {[dict get $entry kind] eq "type1"} {
      return [my FontWriteType1 $alias $entry]
    }
    set writer [my writer]
    set parsed [dict get $entry parsed]
    set used [dict get $entry used]
    set units [dict get $parsed unitsPerEm]

    # CFF outlines are embedded whole. Subsetting rewrites loca and glyf, and
    # a CFF font has neither - its outlines are charstrings in a table this
    # package does not read. Everything else about the face is the same sfnt
    # structure, which is why the road forks here and not earlier.
    set cff [expr {[dict get $parsed outlines] eq "cff"}]
    if {$cff} {
      set fontBytes [dict get $parsed bytes]
      set mapping {}
      foreach glyph [dict keys $used] {
        dict set mapping $glyph $glyph
      }
    } elseif {[dict get $entry subset]} {
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

    # The font file itself.
    #
    # TrueType goes in as FontFile2 with /Length1, the uncompressed length
    # (9.9). CFF goes in as FontFile3 with /Subtype /OpenType, which is the
    # entry for a complete OpenType file rather than a bare CFF table - the
    # whole sfnt is handed over, cmap and all, and the reader takes what it
    # needs. /Length1 has no meaning there and is left out.
    if {$cff} {
      set fontFileNumber [$writer addStream \
          [list Subtype /OpenType Filter /FlateDecode] \
          [::tclpdf::filter encodeFlate $fontBytes]]
    } else {
      set fontFileNumber [$writer addStream \
          [list Length1 [string length $fontBytes] Filter /FlateDecode] \
          [::tclpdf::filter encodeFlate $fontBytes]]
    }

    # Derived once and passed on: the name has to be the SAME in all three
    # places (descriptor, CID font, Type0 font), and deriving it three times is
    # how two of them would one day disagree.
    #
    # No subset prefix for CFF: the tag MEANS subset (9.9.2), and nothing was
    # subsetted here.
    set baseName [my FontBaseName $parsed $alias \
        [expr {!$cff && [dict get $entry subset]}]]

    set descriptorNumber [$writer add [::tclpdf::pdfObj dictionary \
        [my FontDescriptorPairs $parsed $baseName \
            [$writer ref $fontFileNumber] $cff]]]

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
    #
    # CIDToGIDMap belongs to CIDFontType2 and to nothing else. A CFF face is a
    # CIDFontType0, where the mapping from CID to glyph is the font's own
    # business - and with Identity ordering and no subsetting the two are the
    # same number anyway.
    set pairs [list \
        Type /Font Subtype [expr {$cff ? {/CIDFontType0} : {/CIDFontType2}}] \
        BaseFont [::tclpdf::pdfObj name $baseName] \
        CIDSystemInfo [::tclpdf::pdfObj dictionary [list \
            Registry [::tclpdf::pdfObj str Adobe] \
            Ordering [::tclpdf::pdfObj str Identity] \
            Supplement 0]] \
        FontDescriptor [$writer ref $descriptorNumber] \
        DW 1000 \
        W [my FontWidthArray $parsed $used $units]]
    if {!$cff} {
      set cidToGidNumber [$writer addStream {Filter /FlateDecode} \
          [::tclpdf::filter encodeFlate [my FontCidToGid $mapping]]]
      lappend pairs CIDToGIDMap [$writer ref $cidToGidNumber]
    }
    set descendantNumber [$writer add [::tclpdf::pdfObj dictionary $pairs]]

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

  method FontDescriptorPairs {parsed baseName fontFileRef {cff 0}} {
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
        [expr {$cff ? {FontFile3} : {FontFile2}}] $fontFileRef]
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
      # One glyph may stand for several characters: a ligature. The
      # destination of a bfchar is a UTF-16BE STRING, not a single value, so
      # "ffi" is written as three code units and extracts as three letters.
      # Writing only the first would turn every ligature into a lost word.
      set target {}
      foreach code [dict get $used $glyph] {
        if {$code > 0xFFFF} {
          # Outside the BMP: the target is a surrogate pair.
          set value [expr {$code - 0x10000}]
          append target [format %04X%04X [expr {0xD800 | ($value >> 10)}] \
              [expr {0xDC00 | ($value & 0x3FF)}]]
        } else {
          append target [format %04X $code]
        }
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

package provide tclpdf::font 1.4
