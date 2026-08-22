#
# tclpdf - PDF generation for Tcl
#
# type3 - fonts whose glyphs are content streams (ISO 32000-2, 9.6.4)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A Type 3 font has no font program. Its glyphs ARE content streams - the same
# operators a page is drawn with - kept in a /CharProcs dictionary under glyph
# names, addressed through an /Encoding with a /Differences array, and measured
# by a /Widths array whose numbers are in GLYPH space rather than in
# thousandths of the em. That is the whole of the format, and it is why this
# module is small: everything that draws exists already.
#
#   $doc font define marks -ascent 750
#   $doc font glyph marks + -width 800 -script {
#     $doc line -from {100 375} -to {700 375} -stroke black -width 80
#     $doc line -from {400 75} -to {400 675} -stroke black -width 80
#   }
#   $doc font -family marks -size 12
#   $doc text "+" -at {20 30}
#
# THE API, and why it is this one.
#
# [font define] and [font glyph] sit under [font], beside [font embed], because
# they answer the same question - which face does this document have - and a
# caller should not have to know that one face came out of a file and the other
# out of a script. An alias defined here is a family name like any other:
# [font -family], [textWidth], a table cell and a paragraph all take it, and
# nothing outside text.tcl has to be told that a third kind of font exists.
#
# THE SUBJECT of [font glyph] is the CHARACTER, not the glyph name. A glyph
# name is an internal detail of the format; what a caller writes is [text "+"],
# and the package's job is to get from the one to the other. So the character
# is the argument, the character code is assigned here, the glyph name is
# derived from the character (uniXXXX, the Adobe convention - -name overrides
# it where a readable file matters), and /ToUnicode falls out of the same
# mapping instead of having to be stated a second time. A font whose glyphs
# were named by the caller would need all three said by hand, and any two of
# them could then disagree.
#
# THE SCRIPT draws exactly as a form XObject's script draws: {0 0} is the TOP
# LEFT of the glyph's frame, y grows downwards, and every drawing method works
# unchanged, because the canvas stack in the core redirects them (see
# xObject.tcl, [FormBegin]). Keeping the one convention costs one number to
# remember - the baseline sits at y = the ascent - and buys that [rect] behaves
# the same inside a glyph as it does on a page. The script runs in the CALLER's
# frame, not the global one, so a document held in a local variable is visible;
# [layer draw] takes the level the same way and for the same measured reason.
#
# THE UNIT inside the script is the glyph unit, whatever the document unit is.
# The drawing methods write the document unit converted to points, so the glyph
# stream begins with a "cm" that scales those points back to glyph units - one
# operator per glyph, written only when the document unit is not the point.
# Doing it in the FontMatrix instead would be wrong: /Widths and the d0/d1
# operands are in glyph space and are stated by the caller in glyph units, so
# scaling the matrix would move the drawing and the advance apart.
#
# d0 OR d1 (9.6.4, Table 111). d1 declares that the glyph "specifies only
# shape, not colour", and the norm is explicit about the consequence: a glyph
# description that begins with d1 "should not execute any operators that set
# the colour ... any use of such operators shall be ignored". Every drawing
# method of this package sets a colour - a rectangle writes its "rg" - so under
# d1 the glyph would silently come out in the text colour whatever the script
# said. That is the wrong default, and it is why -color own (d0, "both its
# shape and its colour") is the default here. -color text writes d1, which is
# what a glyph that is to follow the text colour like a letter wants; it then
# needs -bbox, because d1's bounding box is binding - "the declared bounding
# box shall be correct" - and nothing here can measure what an arbitrary script
# paints.
#
# WHAT IS NOT WRITTEN: no /FontBBox unless the caller states one with -bbox.
# Table 110 allows exactly that - "If all four elements of the rectangle are
# zero, a PDF processor shall make no assumptions about glyph sizes based on
# the font bounding box. If any element is non-zero, the font bounding box
# shall be accurate." A box guessed from the ascent would be a claim about
# drawings this module never sees.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::type3 {}

oo::define ::tclpdf::document::document {

  # $doc font define <alias> ?-matrix {a b c d e f}? ?-ascent n?
  #                          ?-bbox {x y w h}?
  #
  # Reached through [font define] in text.tcl, which is where the level of the
  # caller's frame is taken.
  method Type3Define {alias args} {
    set options [::tclpdf::option parse \
        {matrix {0.001 0 0 0.001 0 0} ascent {} bbox {}} $args \
        "font define"]
    if {[dict exists [my state fonts] $alias]} {
      return -code error "tclpdf: a font named \"$alias\" already exists"
    }
    set matrix [dict get $options matrix]
    if {[llength $matrix] != 6} {
      return -code error "tclpdf: -matrix of font define is six numbers\
          {a b c d e f} mapping glyph space to text space (ISO 32000-2,\
          Table 110), not \"$matrix\""
    }
    foreach number $matrix {
      if {![string is double -strict $number]} {
        return -code error "tclpdf: -matrix of font define takes numbers,\
            not \"$number\""
      }
    }
    # The horizontal scale is what turns a width in glyph units into an
    # advance. Zero or below is not a scale: every glyph would advance
    # nowhere or backwards, and /Widths would say one thing while the text
    # did another. (The VERTICAL scale, matrix[3], governs the ascent - a
    # vertical measure - and is what [Type3Ascender] uses below.)
    if {[lindex $matrix 0] <= 0} {
      return -code error "tclpdf: the first number of -matrix is the\
          horizontal scale from glyph space to text space and has to be above\
          zero - 0.001 for the usual 1000-unit glyph space, not\
          \"[lindex $matrix 0]\""
    }
    # A font matrix maps glyph space to text space and a mapping has to be
    # invertible: a singular one (determinant ad - bc zero) collapses every
    # glyph onto a line or a point and no reader can lay text out with it.
    # a > 0 above rules out the common degenerate case but not, say, a shear
    # that folds the vertical axis away. Tested on the numbers AS THEY WILL BE
    # WRITTEN - rounded to the six places the FontMatrix carries - so that a
    # scale small enough to round to zero (below 5e-7) is refused here rather
    # than written as a singular matrix a validator would pass.
    lassign [lmap number $matrix {expr {round($number * 1e6) / 1e6}}] a b c d
    if {$a * $d - $b * $c == 0} {
      return -code error "tclpdf: -matrix of font define maps glyph space to\
          text space and has to be invertible, but {$matrix} is singular\
          (determinant zero to the six places a FontMatrix is written in) -\
          such a matrix flattens every glyph to nothing"
    }
    # THE ONE NUMBER a caller has to remember: how far above the baseline the
    # script's frame begins, in glyph units. It is where {0 0} sits inside
    # [font glyph], and it is the ascent the line hangs from under
    # -anchor top. 0.8 of the em by default, which is where the baseline of a
    # real face sits in its em square.
    #
    # There is no -descent to go with it, and that is deliberate rather than
    # an omission: nothing in this package asks a font how far it descends -
    # not the line advance, which is 1.2 times the size, not the paragraph,
    # not the table - and Table 120 puts Descent among the entries "required
    # EXCEPT for Type 3 fonts". An option that acts on nothing is worse than
    # no option: it reads as if it did something.
    set ascent [dict get $options ascent]
    if {$ascent eq {}} {
      # 0.8 of the VERTICAL em: the ascent is a vertical measure, so it is
      # counted against matrix[3] (the vertical scale), the same factor
      # [Type3Ascender] turns it back into points with. With the default
      # diagonal matrix a == d, so this is unchanged for the common case.
      #
      # The MAGNITUDE of that scale, because -ascent is a count of glyph
      # units and those are never negative: a matrix with d below zero is a
      # glyph space turned over, which is invertible and therefore allowed,
      # and 0.8/d would hand such a font a default the check below then
      # refuses - naming an option the caller never wrote.
      set ascent [expr {0.8 / abs([lindex $matrix 3])}]
    }
    if {![string is double -strict $ascent] || $ascent < 0} {
      return -code error "tclpdf: -ascent of font define is the height of the\
          glyph frame above the baseline, in glyph units, 0 or more - not\
          \"$ascent\""
    }
    set bbox [dict get $options bbox]
    if {$bbox ne {}} {
      set bbox [my Type3Box $bbox $ascent "-bbox of font define"]
    }
    set fonts [my state fonts]
    dict set fonts $alias [dict create kind type3 matrix $matrix \
        ascent $ascent bbox $bbox glyphs {} codes {} number {}]
    my state fonts $fonts
    if {[my state type3Hooked] eq {}} {
      my state type3Hooked 1
      # On resources, like the embedded faces: the event fires after every
      # beforeWrite subscriber has drawn - [pageNumbers] writes its labels
      # there, and those labels may be set in this very font - and before the
      # catalog checks that walk the fonts.
      my onSelf resources Type3Write
    }
    return $alias
  }

  # $doc font glyph <alias> <char> -width n -script {...}
  #                                ?-name g? ?-color own|text? ?-bbox {x y w h}?
  #
  # LEVEL is the caller's frame, handed down from [font] - see the head of
  # this file.
  method Type3Glyph {level alias char args} {
    set options [::tclpdf::option parse \
        {width {} script {} name {} color own bbox {}} $args "font glyph"]
    set fonts [my state fonts]
    if {![dict exists $fonts $alias]} {
      return -code error "tclpdf: no font named \"$alias\" - a Type 3 font is\
          created with \[font define\]"
    }
    set entry [dict get $fonts $alias]
    if {[dict get $entry kind] ne "type3"} {
      return -code error "tclpdf: \"$alias\" is an embedded face and its\
          glyphs come out of its font file - \[font glyph\] draws the glyphs\
          of a Type 3 font, which is what \[font define\] makes"
    }
    # ONE CHARACTER, counted in code points and not in string elements.
    # [string length] counts the second under Tcl 8.6: a character beyond the
    # BMP is stored there as a surrogate pair and measures 2, so this used to
    # refuse under 8.6 what it took under 9 - measured on 2026-08-21 against
    # the 1499 characters of a colour emoji face, 1314 of which lie beyond the
    # BMP. [split {}] counts code points under both, measured with 8.6.18 and
    # 9.0.4: it hands the pair back as ONE element, and [scan %c] reads the
    # real code point out of it - 128512 for U+1F600 either way, which is what
    # the character code, the glyph name and the ToUnicode map below are built
    # from.
    if {[llength [split $char {}]] != 1} {
      return -code error "tclpdf: \[font glyph\] takes the ONE character the\
          glyph is drawn for, not \"$char\""
    }
    if {[dict exists $entry codes $char]} {
      return -code error "tclpdf: font \"$alias\" already has a glyph for\
          [my Type3Codepoint $char]"
    }
    set width [dict get $options width]
    if {![string is double -strict $width] || $width < 0} {
      return -code error "tclpdf: -width of font glyph is the advance in\
          glyph units, 0 or more, not \"$width\""
    }
    # -script IS REQUIRED, and the asymmetry it used to have with -bbox is why
    # this stands here: an omitted -bbox under -color text is refused below, an
    # omitted -script was not refused at all. What came out was a glyph holding
    # nothing but its width operator - a blank mark that sets, measures and
    # extracts, with neither a reader nor a validator reporting it. That is the
    # very shape this package refuses elsewhere by name: a face whose outlines
    # are all empty (TCLPDF FONT OUTLINES), a colour glyph whose layers all
    # draw nothing (TCLPDF COLORFONT EMPTY).
    #
    # An EMPTY body is a different thing and stays legal: a glyph that advances
    # and draws nothing is a space, and a Type 3 font carrying one is doing
    # what /Widths is for. [option parse] cannot tell the two apart - both
    # arrive as the empty string - so the arguments are read once more for the
    # option's presence, exactly as [structure] reads them for its own -script.
    if {"script" ni [lmap {option value} $args {string trimleft $option -}]} {
      return -code error "tclpdf: font glyph needs -script, the body that draws\
          the glyph - a glyph drawn by nothing sets and measures as a blank\
          mark with nothing reporting it. A glyph meant to advance and draw\
          nothing, a space, takes an empty -script {}"
    }
    if {[dict get $options color] ni {own text}} {
      return -code error "tclpdf: -color of font glyph is own - the glyph\
          brings its own colours (d0) - or text - it describes only its shape\
          and is painted in the colour of the text (d1, ISO 32000-2,\
          Table 111), not \"[dict get $options color]\""
    }
    set bbox [dict get $options bbox]
    if {$bbox ne {}} {
      set bbox [my Type3Box $bbox [dict get $entry ascent] \
          "-bbox of font glyph"]
    } elseif {[dict get $options color] eq "text"} {
      # d1's box is binding: "The declared bounding box shall be correct - in
      # other words, sufficiently large to enclose the entire glyph. If any
      # marks fall outside this bounding box, the result is
      # implementation-dependent." What the script paints cannot be measured
      # here, so the caller states it or takes d0.
      return -code error "tclpdf: -color text needs -bbox {x y w h} - the\
          bounding box of a d1 glyph is binding (ISO 32000-2, Table 111) and\
          cannot be measured from a script"
    }
    set name [dict get $options name]
    if {$name eq {}} {
      # The Adobe convention: a glyph standing for U+0041 is called uni0041.
      # Chosen over a serial number because it survives the file being read
      # by something that has no ToUnicode map - and because a human opening
      # the PDF can see what the glyph is for.
      set code [scan $char %c]
      set name [expr {$code > 0xFFFF ? [format u%05X $code]
          : [format uni%04X $code]}]
    }
    if {[string length $name] == 0 || [regexp {[\s()<>\[\]{}/%]} $name]} {
      return -code error "tclpdf: -name of font glyph is a glyph name and\
          cannot be empty or carry white space or a PDF delimiter, not\
          \"$name\""
    }
    foreach {other record} [dict get $entry glyphs] {
      if {[dict get $record name] eq $name} {
        return -code error "tclpdf: font \"$alias\" already has a glyph named\
            \"$name\" - a CharProcs key names one glyph (ISO 32000-2,\
            Table 110)"
      }
    }
    set code [my Type3Code $alias $entry $char]
    set stream [my Type3Stream $level $alias $entry $width $bbox \
        [dict get $options color] [dict get $options script]]
    # Read back rather than kept from above: the script may have defined
    # further glyphs of its own, and writing the entry this method started
    # with would drop them.
    set fonts [my state fonts]
    set entry [dict get $fonts $alias]
    dict set entry glyphs $code [dict create name $name width $width \
        char $char stream $stream]
    dict set entry codes $char $code
    dict set fonts $alias $entry
    my state fonts $fonts
    return $name
  }

  # The character code a glyph is addressed by.
  #
  # The character's own code point where the encoding has room for it, which
  # makes the strings in the content stream readable - "(ab) Tj" for the text
  # ab, exactly as the example in 9.6.4 has it - and the /Differences array
  # short. A character outside that range takes the highest free code instead:
  # an encoding has 256 slots and a symbol at U+26A0 has to sit in one of them
  # whatever its code point is. /ToUnicode carries the character back either
  # way, so nothing downstream depends on which of the two roads a glyph took.
  method Type3Code {alias entry char} {
    set used {}
    foreach {code record} [dict get $entry glyphs] {
      dict set used $code 1
    }
    set point [scan $char %c]
    if {$point >= 1 && $point <= 255 && ![dict exists $used $point]} {
      return $point
    }
    for {set code 255} {$code >= 1} {incr code -1} {
      if {![dict exists $used $code]} {
        return $code
      }
    }
    return -code error "tclpdf: the Type 3 font \"$alias\" has no free\
        character code left - such a font is addressed by single bytes and\
        holds at most 255 glyphs (ISO 32000-2, 9.6.5.3)"
  }

  # A box given as {x y w h} in the script's frame, as the glyph space
  # rectangle {llx lly urx ury} the norm asks for. One conversion, used by the
  # font box and by every glyph box - the script counts y downwards from the
  # top of the frame, glyph space counts it upwards from the baseline.
  method Type3Box {box ascent what} {
    if {[llength $box] != 4} {
      return -code error "tclpdf: $what is {x y width height} in the\
          coordinates of the glyph script, not \"$box\""
    }
    foreach number $box {
      if {![string is double -strict $number]} {
        return -code error "tclpdf: $what takes numbers, not \"$number\""
      }
    }
    lassign $box x y width height
    if {$width < 0 || $height < 0} {
      return -code error "tclpdf: $what takes a width and a height of 0 or\
          more, not \"$width\" and \"$height\""
    }
    return [list $x [expr {$ascent - $y - $height}] [expr {$x + $width}] \
        [expr {$ascent - $y}]]
  }

  # The content stream of one glyph: the width operator, the unit correction,
  # and whatever the script drew.
  method Type3Stream {level alias entry width bbox color script} {
    set numbers [list [::tclpdf::pdfObj num $width] 0]
    if {$color eq "text"} {
      foreach number $bbox {
        lappend numbers [::tclpdf::pdfObj num $number]
      }
      lappend numbers d1
    } else {
      lappend numbers d0
    }
    set stream "[join $numbers { }]\n"
    # The document unit reaches the stream through [coords] and [distance],
    # which write points. The glyph coordinate system is not points, so the
    # points are scaled back - see the head of this file. A document in pt
    # needs no correction and gets none.
    set factor [::tclpdf::geometry toPoints 1 [my cget -unit]]
    set ascent [dict get $entry ascent]
    my FormBegin [expr {$width * $factor}] [expr {$ascent * $factor}]
    set failed [catch {uplevel #$level $script} result info]
    set content [my FormEnd]
    if {$failed} {
      return -options $info $result
    }
    if {$color eq "text"} {
      my Type3RefuseImage $alias $content
    }
    if {$factor != 1.0} {
      set scale [::tclpdf::pdfObj num [expr {1.0 / $factor}] 6]
      append stream "$scale 0 0 $scale 0 0 cm\n"
    }
    append stream $content
    return $stream
  }

  # A d1 glyph "shall not include an image, other than an image mask" (ISO
  # 32000-2, 9.6.4, Table 111). d1 declares that the glyph specifies only
  # shape, not colour, and a reader is free to ignore its colour operators; an
  # image carries its own colour and would come out at the reader's discretion.
  # An image mask is exempt - it is a stencil painted in the current colour,
  # which is the one thing a shape-only glyph is meant to hold.
  #
  # Read off the glyph's own content: an image is placed with a "<name> Do",
  # and the name is one this document registered for a NON-stencil picture (a
  # stencil mask carries the "stencil" flag). A form XObject is a Do as well
  # but is not an image, so it does not match, and neither does a mask placed
  # as a stencil.
  #
  # THE GLYPH'S OWN CONTENT, and no further: a picture placed inside a form
  # XObject that the glyph then places is not caught. Reaching it would mean
  # reading the form's stream back out of the writer, inflating it and walking
  # every form it places in turn - and a form carries no content in the state,
  # only its resource name and its size. Named here rather than left as a
  # surprise: the direct case is the one a caller writes, and it is refused.
  method Type3RefuseImage {alias content} {
    set placed {}
    foreach {whole name} [regexp -all -inline \
        {/([^\s/\[\]<>(){}%]+)\s+Do} $content] {
      dict set placed $name 1
    }
    if {![dict size $placed]} {
      return
    }
    dict for {imageAlias image} [my state images] {
      if {[dict get $image stencil]} {
        continue
      }
      set parts [expr {[dict exists $image parts]
          ? [dict get $image parts] : [list $image]}]
      foreach part $parts {
        if {[dict exists $part resource]
            && [dict exists $placed [dict get $part resource]]} {
          return -code error "tclpdf: a -color text glyph of the Type 3 font\
              \"$alias\" places the image \"$imageAlias\" - a d1 glyph\
              specifies only shape and shall not include an image other than\
              an image mask (ISO 32000-2, 9.6.4, Table 111); draw it with\
              -color own, or place the image through a stencil mask"
        }
      }
    }
    return
  }

  # -- what the text module asks ------------------------------------------

  # The resource name, registered on first use - so a font defined and never
  # used costs no object, exactly as an embedded face does not.
  #
  # Through [FontResource], not beside it: a Type 3 font keeps its entry in
  # the same state dictionary an embedded face does, and reserving the object
  # on first use is the same act under a different resource name.
  method Type3Resource {alias} {
    return [my FontResource $alias T3]
  }

  # A string as the character codes that will be drawn for it.
  #
  # THE single place that turns characters into codes for a Type 3 font, so
  # that measuring and drawing cannot answer differently - the defect that has
  # already been paid for once, where a line was measured with kerning and
  # drawn without.
  #
  # A character the font has no glyph for is an error carrying the same
  # -errorcode as every other missing glyph, so one handler covers a standard
  # face, an embedded face and this.
  method Type3Encode {alias text} {
    set glyphs [dict get [my state fonts] $alias codes]
    set codes {}
    set position 0
    foreach char [split $text {}] {
      # The three characters that never reach a font: a soft hyphen is an
      # offer to break and the breaker has already put a real hyphen where it
      # took one, a zero width space is a break opportunity, and a byte order
      # mark is what a file read without stripping it carries. Same rule as
      # afm.tcl and font.tcl - a face is not asked for a glyph it should
      # never draw.
      if {$char in "­ ​ ﻿"} {
        incr position
        continue
      }
      if {![dict exists $glyphs $char]} {
        set u [my Type3Codepoint $char]
        return -code error \
            -errorcode [list TCLPDF FONT GLYPH $u $position $alias] \
            "tclpdf: the Type 3 font \"$alias\" has no glyph for character $u\
            (position $position) - draw one with \[font glyph\]"
      }
      lappend codes [dict get $glyphs $char]
      incr position
    }
    return $codes
  }

  # The width of a string in points, and how many glyphs it is.
  #
  # The widths are the ones in /Widths, in glyph space, so the measurement and
  # the file cannot disagree: what a reader advances by is width * a * size,
  # where a is the horizontal scale of the font matrix (Table 110 - "These
  # widths shall be interpreted in glyph space as specified by FontMatrix").
  method Type3Points {alias string size} {
    set entry [dict get [my state fonts] $alias]
    set codes [my Type3Encode $alias $string]
    set total 0
    foreach code $codes {
      set total [expr {$total + [dict get $entry glyphs $code width]}]
    }
    return [list [expr {$total * [lindex [dict get $entry matrix] 0] * $size}] \
        [llength $codes]]
  }

  # The ascent at a given size, in points - what [-anchor top] hangs a line
  # from. The frame the glyphs were drawn in, through the same scale as a
  # width.
  method Type3Ascender {alias size} {
    set entry [dict get [my state fonts] $alias]
    # matrix[3], the VERTICAL scale: the ascent is a height in glyph units, so
    # it maps to text space through the vertical factor of the font matrix, not
    # the horizontal one a width uses. With the default diagonal matrix the two
    # are equal; they part only under an explicit -matrix whose scales differ.
    return [expr {[dict get $entry ascent]
        * [lindex [dict get $entry matrix] 3] * $size}]
  }

  # What the file says about itself, in the shape [font info] answers for an
  # embedded face.
  method Type3Info {alias} {
    set entry [dict get [my state fonts] $alias]
    return [dict create \
        family $alias \
        postScript $alias \
        glyphs [dict size [dict get $entry glyphs]] \
        unitsPerEm [expr {1.0 / [lindex [dict get $entry matrix] 0]}] \
        fsType {} \
        permission "not stated - a Type 3 font has no font program" \
        characters [dict size [dict get $entry codes]]]
  }

  # U+XXXX, the spelling the error code contract uses.
  method Type3Codepoint {char} {
    return U+[format %04X [scan $char %c]]
  }

  # -- writing ------------------------------------------------------------

  method Type3Write {} {
    dict for {alias entry} [my state fonts] {
      if {[dict get $entry kind] ne "type3"
          || [dict get $entry number] eq {}} {
        # Not this module's, or defined and never used - no objects for it.
        continue
      }
      my Type3WriteOne $alias $entry
    }
    return
  }

  method Type3WriteOne {alias entry} {
    set writer [my writer]
    set glyphs [dict get $entry glyphs]
    if {![dict size $glyphs]} {
      return -code error "tclpdf: the Type 3 font \"$alias\" is used but has\
          no glyphs - draw at least one with \[font glyph\]"
    }
    set codes [lsort -integer [dict keys $glyphs]]
    set first [lindex $codes 0]
    set last [lindex $codes end]

    # One stream per glyph. Every object number comes from [reservation], so
    # a document written twice fills the same objects again instead of
    # growing a second set of glyphs nothing points at.
    set procs {}
    foreach code $codes {
      set record [dict get $glyphs $code]
      set number [my streamObject {} [dict get $record stream] \
          [my reservation type3.$alias.glyph.$code]]
      lappend procs [dict get $record name] [$writer ref $number]
    }

    # The Differences array covers every code, and consecutive codes share
    # one number - which is what the array is for (9.6.5).
    set differences {}
    set previous {}
    foreach code $codes {
      if {$previous eq {} || $code != $previous + 1} {
        lappend differences $code
      }
      lappend differences [::tclpdf::pdfObj name \
          [dict get $glyphs $code name]]
      set previous $code
    }

    # "For character codes outside the range FirstChar to LastChar, the width
    # shall be 0" - and a gap inside the range is such a code.
    set widths {}
    for {set code $first} {$code <= $last} {incr code} {
      lappend widths [::tclpdf::pdfObj num [expr {[dict exists $glyphs $code]
          ? [dict get $glyphs $code width] : 0}]]
    }

    # /ToUnicode is what makes the text extractable and searchable. Without
    # it a reader has nothing but the glyph names, and a Type 3 font's names
    # are its own invention: the codes mean nothing outside this one font.
    # Written unconditionally, for the same reason it is written for the
    # embedded faces.
    set used {}
    foreach code $codes {
      dict set used $code [list [scan [dict get $glyphs $code char] %c]]
    }
    set toUnicode [my streamObject {} [my FontToUnicode $used 1] \
        [my reservation type3.$alias.toUnicode]]

    set pairs [list Type /Font Subtype /Type3 \
        FontMatrix [::tclpdf::pdfObj arr [lmap number [dict get $entry matrix] {
          ::tclpdf::pdfObj num $number 6
        }]] \
        CharProcs [::tclpdf::pdfObj dictionary $procs] \
        Encoding [::tclpdf::pdfObj dictionary [list Type /Encoding \
            Differences [::tclpdf::pdfObj arr $differences]]] \
        FirstChar $first \
        LastChar $last \
        Widths [$writer ref [$writer put \
            [my reservation type3.$alias.widths] \
            [::tclpdf::pdfObj arr $widths]]] \
        FontBBox [::tclpdf::pdfObj arr [lmap number [my Type3FontBox $entry] {
          ::tclpdf::pdfObj num $number
        }]] \
        Resources [::tclpdf::pdfObj dictionary \
            [my Type3ResourcePairs $alias $glyphs]] \
        ToUnicode [$writer ref $toUnicode] \
        FontDescriptor [$writer ref [$writer put \
            [my reservation type3.$alias.descriptor] \
            [::tclpdf::pdfObj dictionary [my Type3DescriptorPairs $alias]]]]]
    $writer put [dict get $entry number] [::tclpdf::pdfObj dictionary $pairs]
    return
  }

  # The resource dictionary of the glyph streams: the entries whose NAMES the
  # streams actually mention, picked out of the document's own dictionary.
  #
  # 7.8.3 asks for exactly that - "Content streams that define the glyph
  # descriptions of a Type 3 font shall include a Resources entry in the Type 3
  # font dictionary specifying all the resources used by all the content
  # streams in the CharProcs dictionary" - and the obvious shortcut, pointing
  # at the one shared dictionary every page and every form XObject points at,
  # is what a form may do and this may not: that dictionary carries this very
  # font, so the font would contain itself. Measured on 2026-08-21 with
  # veraPDF 1.30.2, which walked font -> Resources -> Font -> font until it
  # died with a StackOverflowError and produced no report at all; qpdf and
  # poppler said nothing, and the file rendered.
  #
  # By NAME rather than by what the scripts registered while they ran: a glyph
  # that uses an ExtGState the page had already registered adds nothing, and a
  # difference before and after would miss it. A name that matches nothing -
  # /DeviceRGB, the tag of a marked-content sequence - matches no resource
  # either and drops out.
  method Type3ResourcePairs {alias glyphs} {
    set names {}
    dict for {code record} $glyphs {
      foreach {whole name} [regexp -all -inline \
          {/([^\s/\[\]<>(){}%]+)} [dict get $record stream]] {
        dict set names $name 1
      }
    }
    set pairs {}
    foreach category {ExtGState ColorSpace Pattern Shading XObject Font
        Properties} {
      set inner {}
      dict for {name value} [my resource $category] {
        # The names read out of the stream are ESCAPED - [pdfObj name] wrote
        # them, so a resource keyed "Pantone 877 C" appears there as
        # "Pantone#20877#20C". The dictionary key is the raw name, so it is
        # escaped the same way before the lookup; matching the raw key against
        # the escaped stream name found nothing and dropped every resource
        # whose name carried a space or a delimiter (a caller-aliased
        # separation, ICC space or font) out of /Resources.
        set written [string range [::tclpdf::pdfObj name $name] 1 end]
        if {![dict exists $names $written]} {
          continue
        }
        if {$category eq "Font" && $name eq "T3$alias"} {
          # A glyph of this font drawn with this font: the CharProcs stream
          # would invoke the very font description it is part of, and no
          # reader can end that. Refused here rather than written, because
          # what comes out is a file that hangs whoever opens it.
          return -code error "tclpdf: a glyph of the Type 3 font \"$alias\"\
              sets text in that same font - a glyph description cannot invoke\
              the font it belongs to"
        }
        lappend inner $name $value
      }
      if {[llength $inner]} {
        lappend pairs $category [::tclpdf::pdfObj dictionary $inner]
      }
    }
    return $pairs
  }

  # The font bounding box: what the caller stated, or four zeros.
  #
  # Table 110 makes the second one an answer rather than an omission - "If all
  # four elements of the rectangle are zero, a PDF processor shall make no
  # assumptions about glyph sizes based on the font bounding box. If any
  # element is non-zero, the font bounding box shall be accurate." A box
  # derived from the ascent would be a claim about drawings this module never
  # sees, and an inaccurate one puts the result at the reader's discretion.
  method Type3FontBox {entry} {
    if {[dict get $entry bbox] eq {}} {
      return {0 0 0 0}
    }
    return [dict get $entry bbox]
  }

  # The descriptor, which Table 110 requires in a tagged document and which
  # costs one object everywhere else. Four entries: for a Type 3 font,
  # FontBBox, Ascent, Descent, CapHeight and StemV are all "required EXCEPT
  # for Type 3 fonts" (Table 120), and the metrics they would carry are in
  # /Widths and in the glyph streams already.
  #
  # Symbolic (bit 3, value 4): the encoding of this font is its own - its
  # glyph names are invented here and its codes mean nothing outside it -
  # which is exactly what the flag says. 9.8.2 allows one of the two, and
  # nonsymbolic would claim the standard Latin set.
  method Type3DescriptorPairs {alias} {
    return [list Type /FontDescriptor \
        FontName [::tclpdf::pdfObj name $alias] \
        Flags 4 \
        ItalicAngle 0]
  }
}

package provide tclpdf::type3 1.0
