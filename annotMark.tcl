#
# tclpdf - PDF generation for Tcl
#
# annotMark - marking a passage of text (ISO 32000-2, 12.5.6.10)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Usage:
#
#   $doc annot highlight -text "the amount due" -at {20 60} \
#       -contents "the amount due"
#   $doc annot underline -quads {{20 70 40 5}} -contents "the term"
#   $doc annot strikeout -text "old price" -at {20 80} -contents "old price"
#   $doc annot squiggly  -text "recieve" -at {20 90} -contents "spelling"
#
# The four annotations of 12.5.6.10 - Highlight, Underline, StrikeOut and
# Squiggly - which mark a stretch of text that is already on the page. They
# attach to annot.tcl, which owns the core; this file is required by the
# dispatcher there when one of the four kinds is named, so a document that
# never marks anything never loads it.
#
# WHY A MODULE OF ITS OWN, and not the rest of annot.tcl. The note and the
# rubber stamp put a picture SOMEWHERE; these four put a picture ON SOMETHING,
# and everything below follows from that one difference:
#
#   the geometry     /QuadPoints - where the marked words stand - which is the
#                    only thing this annotation consists of, and which the
#                    caller should not have to compute. See [AnnotQuads].
#   the appearance   drawn HERE, by this package, without the caller asking:
#                    unlike a note's symbol the picture is fully determined by
#                    the quads and the colour, so there is nothing to leave to
#                    a reader and nothing to refuse under a PDF/A claim. See
#                    [AnnotMarkupAppearance].
#
# Neither question exists for a note or a stamp, and the core knows nothing
# about either.
#
# NOT CALLED annotMarkup, and the name is worth one sentence: in ISO 32000-2,
# 12.5.6.2 a MARKUP ANNOTATION is any annotation a person authors - the note
# and the stamp are markup annotations too, and so is a link's cousin the
# caret. What these four are is a TEXT MARKUP (12.5.6.10), and "mark" is what
# they do to a passage.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::shape 1.0-
package require tclpdf::text 1.0-
package require tclpdf::document 1.0-
package require tclpdf::annot 1.0-

namespace eval ::tclpdf::annotMark {
  # The four kinds: the subcommand, its /Subtype, and the PDF version this
  # package needs for it. Three of the four numbers are the standard's own
  # (12.5.6.10 - Squiggly came with 1.4, the other three with 1.3); the
  # subcommands are registered in annot.tcl, which is where the dispatcher
  # has to know them before this file is loaded.
  #
  # HIGHLIGHT IS THE EXCEPTION AND SAYS 1.4, a floor this package adds
  # rather than one the standard sets. /Highlight itself is 1.3; what needs
  # 1.4 is the appearance drawn for it - a band under the Multiply blend
  # mode, so that the words show through instead of being painted over
  # (AnnotMarkAppearance). Written as 1.3 the refusal came out of [blend]
  # halfway through the drawing, naming neither the annotation nor a way
  # out, while underline and strikeout went through in the same document.
  # A floor belongs where the caller can see it.
  variable markup {
    highlight {Highlight 1.4}
    underline {Underline 1.3}
    strikeout {StrikeOut 1.3}
    squiggly  {Squiggly 1.4}
  }
}

oo::define ::tclpdf::document::document {

  # -- the text markups (12.5.6.10) ----------------------------------------

  # Highlight, underline, strike-out and squiggly underline. One method for
  # the four, because they differ in exactly two things - the /Subtype and
  # the shape drawn into the appearance - and a copy per kind is three copies
  # waiting to drift.
  method AnnotMarkup {kind args} {
    variable ::tclpdf::annotMark::markup
    lassign [dict get $markup $kind] subtype version
    set options [::tclpdf::option parse {
      text {} lines {} at {} align left anchor baseline leading {} quads {}
      contents {} title {} colour {} color {} opacity {} appearance {} date {}
    } $args "annot $kind"]
    set options [my AnnotColourOption $options "annot $kind"]
    set quads [my AnnotQuads $kind $options]
    # The rectangle is the union of the quadrilaterals, and it has to
    # CONTAIN them: 12.5.6.10 says the quads "shall be contained within the
    # region specified by the annotation's Rect entry", and a reader that
    # clips to /Rect draws half a highlight otherwise.
    set box [my AnnotUnion $quads]
    set rect [my AnnotRectangle [lrange $box 0 1] [lrange $box 2 3] \
        "annot $kind"]
    my RequireVersion $version "annot $kind"
    # A colour every markup has, because the markup IS the colour: /C is what
    # a reader paints the quads in when it draws them itself, and it is what
    # the appearance below is drawn in. Yellow for the highlight, as every
    # marker pen is; red for the three that draw a line, because a line in
    # the text colour is not visible as a remark.
    if {[dict get $options colour] eq {}} {
      dict set options colour \
          [expr {$kind eq "highlight" ? {1 0.92 0.23} : {0.85 0.15 0.15}}]
    }
    set pairs [list QuadPoints [my AnnotQuadPoints $quads]]
    return [my AnnotWrite $subtype $rect $options $pairs 4 $quads]
  }

  # The quadrilaterals of a markup, as {x y w h} rectangles in the document's
  # unit, counted from the top left corner like everything else in this API.
  #
  # THREE ROADS, AND THE TWO CONVENIENT ONES ARE THE POINT OF THIS METHOD. A
  # caller who has just drawn a line of text knows what they drew and where;
  # what they do NOT know without doing the package's own arithmetic is how
  # tall the line is and how far the glyphs reach below the baseline. So the
  # markup repeats what the [text] call said and lets this file measure.
  #
  #   -text    ONE line. The string and the -at of the [text] call that drew
  #            it, and the box comes from the same font state that set it:
  #
  #              $doc text "the amount due" -at {20 60}
  #              $doc annot highlight -text "the amount due" -at {20 60}
  #
  #   -lines   A PARAGRAPH, as [$doc textLines $string -width $w] broke it,
  #            with -at the point the [text] call was given. One quad per
  #            line, one leading apart - and one annotation, because a marked
  #            passage is one remark:
  #
  #              $doc text $paragraph -at {20 110} -width 170
  #              $doc annot highlight -at {20 110} \
  #                  -lines [$doc textLines $paragraph -width 170]
  #
  #   -quads   THE RECTANGLES THEMSELVES, for a passage this package did not
  #            set, a table cell whose geometry the caller already has, a
  #            justified block, and anything the measurement cannot follow.
  #
  # The width is [textWidth]'s, which is the width that was drawn - the same
  # method the line breaker and the table measure with; the height is the
  # ascent above the baseline plus the descent below it, so the band covers
  # the capitals and the descenders and nothing else. -align and -anchor say
  # what the [text] call said, because both move the string relative to -at.
  #
  # What the measuring roads do NOT follow, and say so rather than guess: a
  # justified paragraph, whose lines were stretched after they were measured;
  # indents and paragraph spacing, which are the block's and not a constant
  # leading; and a Type 3 face, which has no descender to read. All three
  # end in -quads, and each refusal names it.
  method AnnotQuads {kind options} {
    set roads {}
    foreach road {text lines quads} {
      if {[dict get $options $road] ne {}} {
        lappend roads -$road
      }
    }
    if {[llength $roads] > 1} {
      return -code error -errorcode [list TCLPDF ANNOT QUADS BOTH $kind] \
          "tclpdf: annot $kind was given [join $roads { and }], and they are\
          three ways of saying the same thing - -text measures the rectangle
          of one line this package set, -lines those of a paragraph it broke,\
          -quads gives the rectangles directly. Pass one of them"
    }
    if {![llength $roads]} {
      return -code error -errorcode [list TCLPDF ANNOT QUADS NONE $kind] \
          "tclpdf: annot $kind needs -text {string} with the -at of the\
          \[\$doc text\] call that drew it, -lines with what\
          \[\$doc textLines\] answered for a paragraph, or -quads\
          {{x y w h} ...} with the rectangles to mark. Without one of them\
          there is nothing to mark: /QuadPoints is what a text markup\
          consists of (ISO 32000-2, 12.5.6.10)"
    }
    if {[dict get $options quads] ne {}} {
      return [my AnnotGivenQuads $kind [dict get $options quads]]
    }
    if {[dict get $options text] ne {}} {
      return [list [my AnnotTextQuad $kind $options \
          [dict get $options text] [lindex [my AnnotAt $kind $options] 1]]]
    }
    return [my AnnotLineQuads $kind $options]
  }

  # The rectangles as the caller gave them, checked.
  method AnnotGivenQuads {kind quads} {
    set result {}
    foreach quad $quads {
      if {[llength $quad] != 4} {
        return -code error -errorcode [list TCLPDF ANNOT QUADS SHAPE $quad] \
            "tclpdf: every entry of -quads is one rectangle {x y w h},\
            counted from the top left corner as -at is everywhere else -\
            not \"$quad\""
      }
      foreach value $quad {
        if {![string is double -strict $value]} {
          return -code error -errorcode \
              [list TCLPDF ANNOT QUADS NUMBER $value] \
              "tclpdf: -quads holds numbers, not \"$value\""
        }
      }
      lassign $quad -> -> width height
      if {$width <= 0 || $height <= 0} {
        return -code error -errorcode [list TCLPDF ANNOT QUADS EMPTY $quad] \
            "tclpdf: the rectangle {$quad} of -quads has no width or no\
            height - a markup of no area marks nothing and no reader draws it"
      }
      lappend result $quad
    }
    return $result
  }

  # -at, checked once for both measuring roads.
  method AnnotAt {kind options} {
    set at [dict get $options at]
    if {[llength $at] != 2 || ![string is double -strict [lindex $at 0]]
        || ![string is double -strict [lindex $at 1]]} {
      return -code error -errorcode [list TCLPDF ANNOT QUADS AT $kind] \
          "tclpdf: the measuring roads of annot $kind need -at {x y} as well\
          - the same point the \[\$doc text\] call was given, because that is\
          where the line stands - not \"$at\""
    }
    return $at
  }

  # A PARAGRAPH, marked line by line.
  #
  # -lines takes what [$doc textLines $string -width $w] answered and -at the
  # point the [text] call was given, and it walks down the block one leading
  # at a time. The leading is the one the block itself used - the text state's,
  # which is 1.2 times the size unless [font -leading] said otherwise - so the
  # rectangles cannot come to disagree with the lines they cover. A caller who
  # broke the block differently says so with -leading.
  #
  # ONE ANNOTATION WITH SEVERAL QUADS, not one annotation per line, and that
  # is what 12.5.6.10 provides for: "an array of 8 x n numbers specifying the
  # coordinates of n quadrilaterals". A marked passage is one remark and gets
  # one description - which under PDF/UA is the difference between a reader
  # announcing it once and announcing it four times.
  method AnnotLineQuads {kind options} {
    lassign [my AnnotAt $kind $options] x y
    my TextInit
    set state [my TextMerge {}]
    set leading [dict get $options leading]
    if {$leading eq {}} {
      set leading [::tclpdf::geometry fromPoints [dict get $state leading] \
          [my cget -unit]]
    } elseif {![string is double -strict $leading] || $leading <= 0} {
      return -code error -errorcode \
          [list TCLPDF ANNOT QUADS LEADING $leading] \
          "tclpdf: -leading of annot $kind is the line spacing the block was\
          set with, in [my cget -unit] and above zero, not \"$leading\".\
          Leave it out and the text state's own leading is used, which is\
          what the block used"
    }
    set quads {}
    foreach line [dict get $options lines] {
      # [textLines -hyphens 1] answers dictionaries rather than strings, and
      # both shapes are taken: what is marked is the text of the line either
      # way, and a caller who asked for the hyphens should not have to strip
      # them out again.
      if {[llength $line] > 1 && [dict exists $line text]} {
        set line [dict get $line text]
      }
      if {$line ne {}} {
        lappend quads [my AnnotTextQuad $kind $options $line $y]
      }
      set y [expr {$y + $leading}]
    }
    if {![llength $quads]} {
      return -code error -errorcode [list TCLPDF ANNOT QUADS EMPTYLINES $kind] \
          "tclpdf: -lines of annot $kind holds no line with anything in it -\
          there is nothing to mark"
    }
    return $quads
  }

  # The rectangle one line covers, measured from the state a [text] call would
  # use: the width [textWidth] answers, the ascent above the baseline and the
  # descent below it.
  method AnnotTextQuad {kind options text y} {
    if {[string first \n $text] >= 0} {
      return -code error -errorcode [list TCLPDF ANNOT QUADS LINES $kind] \
          "tclpdf: -text of annot $kind marks ONE line, and \"$text\" holds a\
          line break. Break the text with \[\$doc textLines\] and hand the\
          lines to -lines"
    }
    my TextInit
    set state [my TextMerge {}]
    set x [lindex [my AnnotAt $kind $options] 0]
    set width [my textWidth $text]
    switch -- [dict get $options align] {
      left {set left $x}
      right {set left [expr {$x - $width}]}
      center - centre {set left [expr {$x - $width / 2.0}]}
      default {
        return -code error -errorcode \
            [list TCLPDF ANNOT QUADS ALIGN [dict get $options align]] \
            "tclpdf: -align of annot $kind repeats what the \[\$doc text\]\
            call said - left, right or center - not\
            \"[dict get $options align]\". A justified paragraph is the one\
            case the measurement cannot follow: every line but the last was\
            stretched to the block's width, and \[textWidth\] answers the width\
            it was set at. Mark that one through -quads"
      }
    }
    # The ascent above the baseline is [TextLift]'s, which is the very number
    # -anchor top shifts a line by - so the band's top edge is where the
    # letters start, whichever road the caller took.
    set ascent [my TextLift $state top]
    set descent [my AnnotDescent $state $kind]
    if {[my TextAnchor [dict get $options anchor]] eq "top"} {
      # -anchor top put the TOP of the line at -at, so the box starts there.
      set top $y
    } else {
      set top [expr {$y - $ascent}]
    }
    if {$width <= 0} {
      return -code error -errorcode [list TCLPDF ANNOT QUADS EMPTYTEXT $kind] \
          "tclpdf: annot $kind was given a line of no width to mark - an\
          empty string has no rectangle"
    }
    return [list $left $top $width [expr {$ascent + $descent}]]
  }

  # How far the current face reaches BELOW the baseline, in the document's
  # unit and at the size the text state holds.
  #
  # THE EMBEDDED HALF IS [FontDescender] IN font.tcl, which is where it
  # belongs and where it went on 2026-08-24 - this method said so itself
  # before that, carrying all three branches of it and noting that it "becomes
  # one line and should". What is left here is the part that is this module's
  # own: a face this document never embedded, whose descender comes from the
  # metrics the package ships, and the Type 3 refusal.
  #
  # A Type 3 face is refused rather than guessed at: its glyphs are content
  # streams with a font matrix of the caller's choosing, [Type3Ascender]
  # answers from the box the caller declared, and there is no descender
  # anywhere to read. -quads is the way, and the message says so.
  method AnnotDescent {state kind} {
    set font [dict get $state resolved]
    set size [dict get $state size]
    if {![my TextEmbedded $font]} {
      set descender [dict get [::tclpdf::afm descriptor $font] Descender]
      return [::tclpdf::geometry fromPoints \
          [expr {abs($descender) * $size / 1000.0}] [my cget -unit]]
    }
    if {[my FontKind $font] eq "type3"} {
      return -code error -errorcode [list TCLPDF ANNOT QUADS TYPE3 $font] \
          "tclpdf: -text of annot $kind measures the line's box from the\
          face's ascender and descender, and the Type 3 face \"$font\" has\
          neither - its glyphs are content streams and the only vertical\
          measure it carries is the box \[\$doc font type3\] was given. Pass\
          the rectangle to -quads instead"
    }
    return [::tclpdf::geometry fromPoints [my FontDescender $font $size] \
        [my cget -unit]]
  }

  # The smallest {x y w h} holding every quad.
  method AnnotUnion {quads} {
    set lefts {}
    set tops {}
    set rights {}
    set bottoms {}
    foreach quad $quads {
      lassign $quad x y width height
      lappend lefts $x
      lappend tops $y
      lappend rights [expr {$x + $width}]
      lappend bottoms [expr {$y + $height}]
    }
    set left [::tcl::mathfunc::min {*}$lefts]
    set top [::tcl::mathfunc::min {*}$tops]
    return [list $left $top \
        [expr {[::tcl::mathfunc::max {*}$rights] - $left}] \
        [expr {[::tcl::mathfunc::max {*}$bottoms] - $top}]]
  }

  # /QuadPoints: eight numbers per quad, and the ORDER is the one trap in
  # this whole file. 12.5.6.10 lists the corners as x1 y1 x2 y2 x3 y3 x4 y4,
  # and the text of ISO 32000 describes them counterclockwise while every
  # producer and every reader in the field writes them as upper-left,
  # upper-right, lower-left, lower-right - a Z, not a loop. The note in
  # 32000-2 concedes the point ("the ordering ... is not in accordance with
  # the specification in ISO 32000-1"), and a file written the other way has
  # its highlights drawn as bow ties by Acrobat. The Z is what goes out here,
  # and [pdftoppm] on the examples is what checked it.
  method AnnotQuadPoints {quads} {
    set numbers {}
    foreach quad $quads {
      lassign $quad x y width height
      lassign [my coords $x $y] x0 y0
      lassign [my coords [expr {$x + $width}] [expr {$y + $height}]] x1 y1
      foreach value [list $x0 $y0 $x1 $y0 $x0 $y1 $x1 $y1] {
        lappend numbers [::tclpdf::pdfObj num $value]
      }
    }
    return [::tclpdf::pdfObj arr $numbers]
  }

  # The appearance of a text markup, drawn HERE and by nothing else.
  #
  # This is the half of the file that makes the markups conform without the
  # caller lifting a finger: /AP is required of every annotation (Table 166)
  # and a PDF/A file without one fails veraPDF 6.3.3, and unlike a note's
  # symbol the picture is fully determined - the quads and the colour are
  # all there is to a highlight.
  #
  # Drawn into a form the size of the annotation's rectangle, in the caller's
  # own coordinates: [FormBegin] mirrors [coords] against the form's height,
  # so every drawing method of the package works unchanged and the quads only
  # have to move from the page's origin to the rectangle's top left corner.
  #
  # NO TRANSPARENCY GROUP, and that is the one deliberate difference from
  # [form create]. The highlight blends MULTIPLY against what is already on
  # the page - that is what makes the text show through the marker rather
  # than disappear under it - and an isolated group would have it blend
  # against a transparent backdrop instead, which composites to the plain
  # colour: measured with pdftoppm, the text vanished under the band.
  #
  # It is NOT registered as an /XObject resource: an appearance is reached
  # through /AP and through nothing else, and a name in the resource
  # dictionary would offer the band to any content stream that cared to say
  # Do. Same rule [FieldAppearanceStream] follows.
  method AnnotMarkupAppearance {subtype number rect quads colour} {
    # The form, the failure, the /Resources and the reservation are
    # [AnnotAppearanceForm]'s in annot.tcl - shared since 2026-08-25, when
    # the geometry annotations wanted the same thing and it would have been
    # the fourth copy of it in the tree.
    set left [dict get $rect left]
    set top [dict get $rect top]
    # The script runs in THIS frame - [AnnotAppearanceForm] uplevels it - so
    # "my" reaches the private drawing method and the locals above are in
    # reach without being threaded through as arguments. The same arrangement
    # [layer draw -script] uses.
    return [my AnnotAppearanceForm $rect annot.ap.$number {
      foreach quad $quads {
        lassign $quad x y width height
        my AnnotMarkupShape $subtype [expr {$x - $left}] [expr {$y - $top}] \
            $width $height $colour
      }
    }]
  }

  # One quad, drawn. Everything is derived from the quad's own height, so a
  # markup on 8 pt text and one on 40 pt text look like the same instrument.
  method AnnotMarkupShape {subtype x y width height colour} {
    # A fourteenth of the line's box: the stroke weight of an underline in a
    # text face, near enough that it reads as one at every size, and thick
    # enough to survive a 150 dpi raster - which is what the examples are
    # checked at.
    set thickness [expr {$height / 14.0}]
    switch -- $subtype {
      Highlight {
        # Multiply, or the band is paint over the words: it darkens what is
        # under it and leaves black text black (11.3.5.2). PDF 1.4, which
        # [blend] pins.
        my rect -at [list $x $y] -size [list $width $height] -fill $colour \
            -blend Multiply
      }
      Underline {
        # Along the bottom edge of the box, which is the descender line - an
        # underline sits below the tails, not through them.
        my rect -at [list $x [expr {$y + $height - $thickness}]] \
            -size [list $width $thickness] -fill $colour
      }
      StrikeOut {
        # Through the middle of the box. With the box running from the
        # ascender to the descender that lands just above the middle of the
        # lowercase letters, which is where a struck line belongs.
        my rect -at [list $x [expr {$y + ($height - $thickness) / 2.0}]] \
            -size [list $width $thickness] -fill $colour
      }
      Squiggly {
        # A zigzag along the bottom edge, its amplitude a tenth of the box
        # and its wavelength four times that - the proportions a reader draws
        # it in, and coarse enough to stay a zigzag at 150 dpi rather than
        # turning into a thick line: measured at a twelfth it came out of
        # pdftoppm as a dense sawtooth.
        set amplitude [expr {$height / 10.0}]
        set step [expr {$amplitude * 2.0}]
        set base [expr {$y + $height}]
        set points {}
        set high 0
        for {set at 0} {$at < $width} {set at [expr {$at + $step}]} {
          lappend points [expr {$x + $at}] \
              [expr {$high ? $base - 2.0 * $amplitude : $base}]
          set high [expr {!$high}]
        }
        lappend points [expr {$x + $width}] \
            [expr {$high ? $base - 2.0 * $amplitude : $base}]
        my polygon -points $points -close 0 -stroke $colour \
            -width [expr {$thickness * 0.8}] -join round -cap round
      }
    }
    return
  }
}

package provide tclpdf::annotMark 1.1
