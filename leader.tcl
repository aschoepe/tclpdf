#
# tclpdf - PDF generation for Tcl
#
# leader - "3. The build .......... 17"
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc leader "Subtotal" "1,234.50" -at {20 100} -width 170
#
# A line with two ends and a run of dots between them, so that the eye keeps
# the row: a table of contents, a price list, a total. The two ends are set as
# text, and the space between them is filled with as many copies of the fill
# string as fit whole.
#
# Why a command of its own rather than a tab stop in [text]: a tab in running
# text needs stop positions, an alignment per stop and an answer to what a tab
# means in a line that wraps - that is mixed setting inside a paragraph, and it
# is a project rather than an option. This does one thing and touches neither
# the line breaker nor the font state.
#
# What it deliberately does NOT do: wrap. Both ends are one line each. A left
# side too long for the width keeps its full length and the dots disappear -
# the amount on the right stays where it belongs, because a right-aligned
# figure that moves is worse than a row that looks tight.
#
# In a tagged document the row is ONE element and the dots are an artifact:
# they carry no information and a reader that spelled them out would read
# "dot dot dot dot" between every heading and its page number.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-
package require tclpdf::text 1.0-

namespace eval ::tclpdf::leader {}

oo::define ::tclpdf::document::document {

  # A row with a filled middle. Returns what [text] returns for one line: the
  # y below it, so that rows can be stacked without measuring again.
  method leader {left right args} {
    my TextInit
    set defaults {at {} width {} fill . gap 1 tag P}
    foreach name $::tclpdf::text::stateOptions {
      dict set defaults $name [my TextGet $name]
    }
    # The line options on top, as [text] takes them: a row is two lines and a
    # fill, and all three run the way -direction says.
    set defaults [dict merge $defaults $::tclpdf::text::runOptions]
    set options [::tclpdf::option parse $defaults $args "leader"]
    # The two ends are positional, not options - they are what the row IS.
    # Carried in the same dictionary so that the drawing takes one argument.
    dict set options left $left
    dict set options right $right
    ::tclpdf::option point [dict get $options at] -at leader
    set width [dict get $options width]
    if {$width eq {}} {
      return -code error "tclpdf: leader needs -width - the row is filled to\
          that width, and without it there is nothing to fill"
    }
    # Checked as [text] checks its width, and before anything is drawn: a
    # negative width put the right hand end to the left of -at, and "abc"
    # failed in Tcl's words from inside the arithmetic below.
    # [text::finite] rather than [string is double]: NaN is a double to Tcl
    # and compares false against everything, so "$width <= 0" waved it past
    # and the row was laid out with a NaN width - see the proc for what that
    # costs downstream.
    if {![::tclpdf::text::finite $width] || $width <= 0} {
      return -code error "tclpdf: -width must be a positive number, not\
          \"$width\""
    }
    set gap [dict get $options gap]
    if {![::tclpdf::text::finite $gap] || $gap < 0} {
      return -code error "tclpdf: -gap takes a distance of 0 or more, not\
          \"$gap\""
    }
    # One element for the whole row rather than one per end: the heading and
    # its page number are one entry, and a reader following the tree should
    # hear them together.
    #
    # An artifact is the first WORD of the tag, not the whole of it: -tag
    # takes the kind as a list, "Artifact Pagination Header" for a running
    # head, exactly as [text] takes it - compared whole, the list was handed
    # to [structure] as a type and refused as one.
    if {[my state tagged] eq "1" && ![my LeaderArtifact $options]} {
      return [my structure [dict get $options tag] -script {
        my LeaderDraw $options
      }]
    }
    return [my LeaderDraw $options]
  }

  # Whether the row is declared an artifact - by the first word of -tag,
  # which is how [text] reads it, the kind following.
  method LeaderArtifact {options} {
    return [expr {[lindex [dict get $options tag] 0] eq "Artifact"}]
  }

  method LeaderDraw {options} {
    lassign [dict get $options at] x y
    set width [dict get $options width]
    # A leader row is a horizontal measurement from end to end: -width is the
    # distance the row spans, [textWidth] measures the two ends along the same
    # axis, and the fill is repeated across the room that is left. In a
    # vertical line every one of those is an answer about the other axis, so
    # the row would be measured across the page and drawn down it. Refused
    # rather than drawn, for the same reason [textPath] refuses it: an option
    # that is accepted and then means something else is worse than one that is
    # not offered. A vertical row of leaders is a column of [text] calls the
    # caller places, since the spacing is his to decide either way.
    if {[dict get $options direction] eq "ttb"} {
      return -code error -errorcode {TCLPDF TEXT DIRECTION ttb leader} \
          "tclpdf: leader takes no -direction ttb - a leader row measures its\
          two ends and its fill along the line, and in a vertical line that is\
          the length down the page rather than a width across it, so the row\
          would be measured on one axis and drawn on the other. Set the pieces\
          as separate text calls down the column, or leave the row horizontal"
    }
    set font [my LeaderFont $options]
    # The ends normally say nothing: an element is already open around them and
    # they join it. Only -tag Artifact has to reach them, or the row would be
    # taken out of the tree while its two ends stayed in it. It reaches them
    # whole, kind and all - and the fill with it: the dots of a running head
    # are as much pagination as its two ends.
    set ends {}
    set fillTag Artifact
    if {[my LeaderArtifact $options]} {
      set ends [list -tag [dict get $options tag]]
      set fillTag [dict get $options tag]
    }
    # The ends first, both at their final position: the fill is what adapts.
    set leftWidth 0
    if {[dict get $options left] ne {}} {
      set leftWidth [my textWidth [dict get $options left] {*}$font]
    }
    set rightWidth 0
    if {[dict get $options right] ne {}} {
      set rightWidth [my textWidth [dict get $options right] {*}$font]
    }
    set gap [dict get $options gap]
    set fill [dict get $options fill]
    set room [expr {$width - $leftWidth - $rightWidth - 2 * $gap}]
    set fillWidth 0
    if {$fill ne {}} {
      set fillWidth [my textWidth $fill {*}$font]
      # A FILL THAT DOES NOT GET LONGER cannot be counted. "As many whole
      # copies as fit" has an answer only while every further copy makes the
      # run wider; -spacing is a number of points of EITHER sign, and once it
      # takes as much off between two copies as one copy is wide, the run
      # SHRINKS with every copy added, every count fits, and the loop below
      # that grows the count while it still fits never ends. Measured: at
      # -size 10 a full stop is 0.98 mm wide, at -spacing -3 ten of them
      # measure 0.28 mm, and [leader] ran for eight seconds without drawing
      # anything before it was stopped.
      #
      # Refused rather than capped at some number: a run that walks backwards
      # over its own left hand end is not a row of leaders whatever the
      # count, and a cap would put a silent, arbitrary number of overlapping
      # marks on the page. A negative -spacing that still leaves the run
      # growing - dots set tighter than the face sets them - is untouched by
      # this, which is what the option is for.
      #
      # Measured as TWO copies against one rather than computed from the
      # spacing: a fill is a STRING, and what happens between two copies of
      # it is the business of the measurement - kerning across the seam, a
      # ligature that forms there - not of arithmetic done here.
      if {[my textWidth [string repeat $fill 2] {*}$font] <= $fillWidth} {
        return -code error -errorcode [list TCLPDF LEADER FILL $fill] \
            "tclpdf: a row of \"$fill\" does not get longer the more copies\
            it holds - the spacing in force takes at least as much off\
            between two copies as one copy is wide, so \"as many as fit\" has\
            no answer and the count would run away. Give a -spacing that\
            leaves the run growing, or a wider -fill"
      }
    }
    # WHERE THE THREE PIECES SIT. The row has a leading end, a trailing end
    # and a fill between them, and "leading" is a matter of reading order: in
    # a right-to-left row the first argument belongs at the RIGHT edge and the
    # second at the left. Only the three anchors change - the -align values
    # stay as they are, because [text] mirrors those itself, and mirroring
    # them here as well would turn them back.
    #
    # The remainder that no whole copy of the fill covers stays in front of
    # the trailing end, on whichever side that is.
    if {[dict get $options direction] eq "rtl"} {
      set leftAt [expr {$x + $width}]
      set fillAt [expr {$x + $width - $leftWidth - $gap}]
      set rightAt $x
    } else {
      set leftAt $x
      set fillAt [expr {$x + $leftWidth + $gap}]
      set rightAt [expr {$x + $width}]
    }
    if {[dict get $options left] ne {}} {
      my text [dict get $options left] -at [list $leftAt $y] {*}$ends {*}$font
    }
    # Whole copies only, and the remainder is left in front of the right hand
    # end. Stretching the last one to fit would mean drawing a partial glyph;
    # spreading the gap over all of them would need character spacing and would
    # make two rows of different lengths line up differently.
    if {$fillWidth > 0 && $room >= $fillWidth} {
      # How many copies: as many as the ROW of them measures within the room,
      # not the room divided by one copy. The two differ as soon as
      # -spacing is in play - Tc goes between every two characters of the
      # run, and one copy measured on its own carries none of it, so the
      # division answered as if there were no spacing and the dots ran past
      # the right hand end. The quotient is the starting point; the run is
      # then measured as it will be drawn and shortened until it fits, or
      # lengthened while it still does - a negative spacing narrows it.
      set count [expr {int($room / $fillWidth)}]
      while {$count > 0
          && [my textWidth [string repeat $fill $count] {*}$font] > $room} {
        incr count -1
      }
      # The growth is guarded by the run itself, not only by the room: a copy
      # that does not make the run longer ends the loop whatever the room
      # says. The refusal above catches the case that matters - a fill whose
      # run shrinks - and this keeps the loop bounded by construction, so a
      # seam that behaves unevenly (a ligature forming across it, a kern) can
      # never turn into a run that goes on for ever.
      set reached [my textWidth [string repeat $fill $count] {*}$font]
      while {1} {
        set longer [my textWidth [string repeat $fill [expr {$count + 1}]] \
            {*}$font]
        if {$longer > $room || $longer <= $reached} {
          break
        }
        incr count
        set reached $longer
      }
      # An artifact: the dots are decoration. Outside a tagged document the
      # option costs nothing, which is why it is not made conditional here.
      if {$count > 0} {
        my text [string repeat $fill $count] -at [list $fillAt $y] \
            -tag $fillTag {*}$font
      }
    }
    if {[dict get $options right] ne {}} {
      my text [dict get $options right] \
          -at [list $rightAt $y] -align right {*}$ends {*}$font
    }
    # One line down, the same step [text -width] takes. Without a width [text]
    # returns nothing at all, so the value is built here rather than passed
    # through - and it is the whole point of the return: rows stack without
    # measuring anything twice.
    return [expr {$y + [::tclpdf::geometry fromPoints \
        [dict get [my TextMerge $font] leading] [my cget -unit]]}]
  }

  # The font options of this call, in the form the text methods take them.
  method LeaderFont {options} {
    set font {}
    foreach name $::tclpdf::text::lineOptions {
      lappend font -$name [dict get $options $name]
    }
    return $font
  }
}

package provide tclpdf::leader 1.3
