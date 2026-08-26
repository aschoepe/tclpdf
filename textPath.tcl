#
# tclpdf - PDF generation for Tcl
#
# textPath - setting a line of text along a path
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc textPath "Bochum - Essen - Duisburg" \
#       -segments {{move 20 60} {curve 60 30 120 90 170 55}} -align center
#
# A seal, a banner, a label following a road on a map: the string is set
# cluster by cluster, each one turned by the tangent of the curve at its own
# position.
#
# PDF has no operator for this - there is no "draw along a path". What it does
# have is one text matrix per show operation, which is enough: walk the path,
# place each cluster where its share of the arc length falls, rotate it by the
# direction the path takes there. The work is therefore not in the drawing but
# in the ARC LENGTH, because glyph widths are measured along the curve and a
# Bezier has no closed form for it.
#
# A CLUSTER, not a glyph, and that is the one thing this module may not take
# apart. A combining mark has no advance and no place of its own: it is set
# against the glyph it hangs on, which GPOS can only do while the two are in
# the same run. Handed on singly the mark loses its base, and it used to land
# on the character after it - see [TextPathAttached] for the measurement. So a
# base and the marks that follow it travel together, and inside the cluster
# the ordinary text road does the work.
#
# So the curve is flattened into short straight pieces once, and everything
# after that is arithmetic on a polyline. The flattening is fine enough that
# the error stays under a tenth of a point at ordinary text sizes, and coarse
# enough that a banner does not cost thousands of segments.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-
package require tclpdf::text 1.0-
package require tclpdf::shape 1.0-

namespace eval ::tclpdf::textPath {
  # How many straight pieces one cubic Bezier is cut into. Measured against a
  # halved step on a 150 mm curve: the glyph positions moved by less than
  # 0.01 mm, so finer buys nothing a reader could see.
  variable steps 48
}

oo::define ::tclpdf::document::document {

  # $doc textPath <string> -segments {...} ?-align left|center|right?
  #               ?-offset 0? ?-side above|below? ?font options?
  #
  # -offset lifts the baseline off the path, in the document unit - a negative
  # value sets the text below it. -align places the string along the path the
  # same way it places it along a straight baseline: at the start, centred on
  # the middle, or ending at the end.
  method textPath {string args} {
    my TextInit
    set defaults {segments {} align left offset 0 tag P}
    foreach name $::tclpdf::text::stateOptions {
      dict set defaults $name [my TextGet $name]
    }
    # The line options on top, exactly as [text] takes them: a path is still
    # one line, and -direction is a property of the line.
    set defaults [dict merge $defaults $::tclpdf::text::runOptions]
    set options [::tclpdf::option parse $defaults $args "textPath"]
    if {![llength [dict get $options segments]]} {
      return -code error -errorcode [list TCLPDF TEXT PATH segments] \
          "tclpdf: textPath needs -segments"
    }
    # The same refusals [path] gives, from the same place: a wrong operand
    # count or a non-number used to crash in the arc-length arithmetic
    # instead of being refused by name.
    ::tclpdf::shape::checkSegments [dict get $options segments]
    # A LINE FEED IS REFUSED HERE, by name and before anything is written -
    # the same refusal [text] makes for a single line, in the same words.
    # This road measures character by character through [textWidth], which
    # does NOT refuse a line feed but splits at it and answers the widest
    # line; the refusal then came out of [TextRun] as "no glyph for U+000A",
    # with "BT" written and, in a tagged document, the mark of the run open.
    if {[string first \n $string] >= 0} {
      return -code error -errorcode [list TCLPDF TEXT PATH linefeed] \
          "tclpdf: textPath sets one line along one path, and the string has\
          a line feed at position [string first \n $string] - set each line\
          on a path of its own"
    }
    # And a string with nothing in it sets no glyph. In a tagged document the
    # bracket below would then hold nothing at all: an element in the tree
    # that a reader announces and that has no content, which is what
    # [text -height max] refuses in as many words ("no empty paragraph
    # element"). Untagged it draws nothing either way, and saying so is
    # better than a call that does nothing and answers a length.
    if {$string eq {}} {
      return -code error -errorcode [list TCLPDF TEXT PATH empty] \
          "tclpdf: textPath needs a string to set - an empty one sets no\
          glyph, and in a tagged document it would leave an element with\
          nothing in it"
    }
    set state [my TextMerge [my TextPathOverrides $options]]

    set points [my TextPathFlatten [dict get $options segments]]
    # Two POINTS, so four numbers - counting coordinates let a lone [move]
    # through, and the text then had nowhere to run.
    if {[llength $points] < 4} {
      return -code error -errorcode [list TCLPDF TEXT PATH points] \
          "tclpdf: a path for text needs at least two points"
    }
    lassign [my TextPathLengths $points] lengths total
    # A path of no length is two points on top of each other - allowed by the
    # count above, and nothing can be placed along it: every glyph fails at
    # [TextPathPoint] and the run comes out empty, with the mark of a tagged
    # document bracketing nothing. Refused for the same reason the empty
    # string is.
    if {$total <= 0} {
      return -code error -errorcode [list TCLPDF TEXT PATH length] \
          "tclpdf: the path for this text has no length - its points all lie\
          on the same spot, so there is nowhere along it to set a glyph"
    }

    # Where the string starts on the path, from its own width - the same
    # decision [text] makes for a straight line, only measured along the curve.
    set width [my textWidth $string {*}[my TextPathOverrides $options]]
    # Mirrored the same way [text] mirrors it, and through the same method:
    # -align names the edge the text starts at IN READING ORDER, so on a path
    # that runs right to left "left" is the far end of the path.
    switch -- [my TextAlign [dict get $options align] $state] {
      left {set cursor 0}
      right {set cursor [expr {$total - $width}]}
      center - centre {set cursor [expr {($total - $width) / 2.0}]}
      default {
        return -code error -errorcode [list TCLPDF TEXT PATH align] \
            "tclpdf: -align must be left, right or center,\
            not \"[dict get $options align]\""
      }
    }

    set offset [dict get $options offset]
    # [text::finite] rather than [string is double]: NaN and Inf ARE doubles
    # to Tcl, so both came through here and died in the arithmetic below -
    # "sin($radians) * $offset" - after the mark of a tagged run had been
    # opened. With -tag Artifact that left the artifact bracket standing and
    # every later paragraph of the page was swallowed by it: pdfinfo
    # -struct-text showed a document whose two following paragraphs did not
    # exist for a reader.
    if {![::tclpdf::text::finite $offset]} {
      # Any sign - below the path is a place too - but a number, and said
      # so here: "abc" used to fail in Tcl's words from inside the loop.
      return -code error -errorcode [list TCLPDF TEXT PATH offset] \
          "tclpdf: -offset takes a distance in the document\
          unit, not \"$offset\""
    }
    # -spacing has no operator here: on a path every cluster is placed by
    # hand, and Tc only applies to a text object that runs on a straight line.
    # So the gap has to go into the cursor, once BETWEEN each pair - which is
    # exactly the count [textWidth] uses for the whole string, and what kept
    # the two apart until now: the alignment measured a length that never got
    # drawn, 44.3715 against 32.7298 mm at -spacing 3.
    #
    # Counted per GLYPH, not per cluster: [textWidth] counts every glyph of
    # the string, and a cluster of two writes its own Tc inside its own text
    # object. Both halves are in the loop below.
    #
    # In the document unit, because the cursor is: the option is in points
    # like every other font size.
    set gap [::tclpdf::geometry fromPoints [dict get $state spacing] \
        [my cget -unit]]

    # One bracket around the whole run. Text on a path is placed cluster by
    # cluster, so bracketing inside the loop would make one element per letter
    # - a reader would announce them singly. -tag works as it does on [text].
    #
    # Opened HERE, after the path, the width and the alignment have all been
    # accepted: opened first, a path too short for text left the BDC standing
    # in the stream with no EMC to close it, and everything after it on the
    # page was read as part of an element that had refused to exist.
    set mark {}
    if {[my state tagged] eq "1"} {
      set mark [my StructureMark [dict get $options tag]]
      my content [my StructureBegin $mark]
    }
    set characters [split $string {}]
    set overrides [my TextPathOverrides $options]
    # Every character measured ONCE, in logical order, before anything is
    # placed. The loop needs the advance anyway, and the same number answers
    # the other question this has to ask first - see [TextPathAttached].
    set widths [lmap char $characters {my textWidth $char {*}$overrides}]
    set attached [my TextPathAttached $characters $widths]

    # The CLUSTERS in the order they are DRAWN. Along a straight baseline
    # [TextShow] turns the whole glyph run round in one go; here each cluster
    # is placed by hand, so the loop walks the same pieces instead - which is
    # why both ask [TextPieces] for them, and both join a mark to its base
    # through [TextCluster]. A number keeps its own order inside a
    # right-to-left line on a path exactly as it does on a baseline.
    #
    # [TextCluster] answers in whole PIECES, and a piece may be a run of
    # digits; the pieces are therefore taken apart again into one cluster per
    # character, with the marks left hanging on the character before them.
    # Taking them apart is what keeps the bytes of every line without a mark:
    # each of its clusters is one character, exactly as before.
    set direction [dict get $state direction]
    set pieces [my TextPieces [lmap char $characters {scan $char %c}] $direction]
    set clusters {}
    foreach piece [my TextCluster $pieces $attached $direction] {
      lassign $piece from to
      for {set index $from} {$index <= $to} {incr index} {
        if {$index > $from && [lindex $attached $index]} {
          lset clusters end 1 $index
        } else {
          lappend clusters [list $index $index]
        }
      }
    }
    # EVERYTHING THE LOOP CAN STILL FAIL ON IS CAUGHT, so that the mark is
    # closed before the error travels on - the guard [text] holds around its
    # own drawing (text.tcl) and the one this road did not have. What is left
    # to fail here is what only the placing meets: a glyph a face lacks in a
    # cluster the measuring pass above did not ask about in the same shape,
    # and any arithmetic on a value that got this far.
    set first 1
    set failed [catch {
    foreach cluster $clusters {
      lassign $cluster from to
      if {!$first} {
        set cursor [expr {$cursor + $gap}]
      }
      set first 0
      # The path advances by the width of the BASE, not of the cluster: a
      # combining mark has no advance of its own - measured, DejaVu Sans, the
      # acute of U+0301 is 0 - and the marks are drawn INSIDE the base's own
      # text object, where the ordinary text road places them.
      set advance [lindex $widths $from]
      # The character spacing, though, is written between every pair of
      # GLYPHS, and [TextRun] writes a "Tc" into the text object of the
      # cluster as well - so the gaps a cluster holds internally travel with
      # the cursor. Left out, the drawn line comes out narrower than
      # [textWidth] measured it and -align center drifts by exactly that much.
      set step [expr {$advance + $gap * ($to - $from)}]
      # The glyph is placed at its own MIDDLE and turned there: measuring the
      # angle at the left edge tips every letter slightly into the curve, and
      # on a tight radius the line visibly fans out.
      lassign [my TextPathPoint $points $lengths [expr {$cursor + $advance / 2.0}]] \
          x y angle
      if {$x ne {}} {
        # Back off half the advance along the baseline, so the glyph's own
        # middle lands where it was measured.
        set radians [expr {$angle * acos(-1) / 180.0}]
        # The offset runs perpendicular to the baseline, and a positive one
        # lifts the text ABOVE the path - which in document coordinates, where
        # y grows downwards, means subtracting it.
        set px [expr {$x - cos($radians) * $advance / 2.0
            - sin($radians) * $offset}]
        set py [expr {$y + sin($radians) * $advance / 2.0
            - cos($radians) * $offset}]
        my TextRun [string range $string $from $to] $state $px $py $angle
      }
      set cursor [expr {$cursor + $step}]
    }
    } result info]
    if {[llength $mark]} {
      my content [my StructureEnd $mark]
    }
    if {$failed} {
      return -options $info $result
    }
    return $total
  }

  # -- internals ----------------------------------------------------------

  # Which characters of the string hang on the one before them: one flag per
  # character, in logical order - the shape [TextCluster] reads.
  #
  # WHY THIS QUESTION HAS TO BE ASKED AT ALL. Everywhere else in the package a
  # line reaches the font as a whole, and GPOS mark attachment then places a
  # combining mark against the glyph it hangs on. This module takes the string
  # apart, and a mark handed on ALONE has no base left in its run: there is
  # nothing for GPOS to attach it to. Measured before the clusters existed,
  # DejaVu Sans, "Ma" + U+0301 + "rz" on a straight path - the acute and the
  # "r" both came out at x 86.20463, the accent lying on the letter after it.
  # So the mark is bound to its base BEFORE the loop runs, and the cluster is
  # what gets placed.
  #
  # THE TEST IS THE ADVANCE, and it is the one the package already treats as
  # what makes a character a combining mark: [FontRunWidth] says so in as many
  # words - "the combining acute has an advance of 0". It is asked through
  # [textWidth], so it holds for every kind of face without a second road -
  # a TrueType face answers out of its hmtx, the standard fourteen out of the
  # shipped metrics, a Type 1 out of its AFM, a Type 3 out of its glyph space.
  #
  # The exception is named rather than measured, because measuring cannot tell
  # it apart: the three characters of [neverDrawn] have no advance either and
  # are not marks. A soft hyphen folded into the cluster in front of it would
  # change the bytes of a document that has one, and it hangs on nothing.
  # A flag for EVERY position, including the zeroes - unlike [FontRunMarks],
  # which answers {} for a run without a mark. The loop that takes the pieces
  # apart again indexes this list per character, and an answer that is
  # sometimes empty would have to be read two ways.
  method TextPathAttached {characters widths} {
    return [lmap char $characters width $widths {
      expr {$width == 0 && $char ni $::tclpdf::text::neverDrawn}
    }]
  }

  # Only the font options, without the ones textPath owns - [textWidth] would
  # refuse -segments.
  #
  # Kerning and ligatures are forced OFF here, and not as a matter of taste:
  # this module places one glyph at a time and adds up the advances it
  # measured one at a time. Measuring the whole string with pair kerning would
  # give a total that is smaller than that sum, and -align center or right
  # would place the string by a width it never draws. Measured with DejaVu at
  # 20 points, the two differed by 4.4 mm over 50 mm of text.
  #
  # Ligatures are off for the same reason and one of its own: a ligature is
  # one glyph made from several characters, and this loop hands [TextRun] a
  # single character at a time, so it could never form one anyway.
  # The direction travels with them: this method feeds [textWidth], and a
  # right-to-left script it was not told about is refused there.
  method TextPathOverrides {options} {
    set result {}
    foreach name $::tclpdf::text::lineOptions {
      if {$name in {kerning ligatures}} {
        lappend result -$name 0
        continue
      }
      lappend result -$name [dict get $options $name]
    }
    return $result
  }

  # The path as a polyline in the DOCUMENT unit: {x y x y ...}. Curves are cut
  # into straight pieces here and nowhere else. The segments arrive checked:
  # [textPath] ran ::tclpdf::shape::checkSegments before calling this.
  method TextPathFlatten {segments} {
    variable ::tclpdf::textPath::steps
    set points {}
    set x 0
    set y 0
    foreach segment $segments {
      set kind [lindex $segment 0]
      set numbers [lrange $segment 1 end]
      switch -- $kind {
        move {
          lassign $numbers x y
          lappend points $x $y
        }
        line {
          lassign $numbers x y
          lappend points $x $y
        }
        curve {
          lassign $numbers x1 y1 x2 y2 x3 y3
          for {set step 1} {$step <= $steps} {incr step} {
            set t [expr {double($step) / $steps}]
            set u [expr {1.0 - $t}]
            lappend points [expr {$u*$u*$u*$x + 3*$u*$u*$t*$x1
                + 3*$u*$t*$t*$x2 + $t*$t*$t*$x3}]
            lappend points [expr {$u*$u*$u*$y + 3*$u*$u*$t*$y1
                + 3*$u*$t*$t*$y2 + $t*$t*$t*$y3}]
          }
          set x $x3
          set y $y3
        }
        close {
          if {[llength $points] >= 2} {
            lappend points [lindex $points 0] [lindex $points 1]
            set x [lindex $points 0]
            set y [lindex $points 1]
          }
        }
      }
    }
    return $points
  }

  # The cumulative length at each point, and the total.
  method TextPathLengths {points} {
    set lengths 0
    set total 0
    for {set index 2} {$index < [llength $points]} {incr index 2} {
      set dx [expr {[lindex $points $index] - [lindex $points $index-2]}]
      set dy [expr {[lindex $points $index+1] - [lindex $points $index-1]}]
      set total [expr {$total + hypot($dx, $dy)}]
      lappend lengths $total
    }
    return [list $lengths $total]
  }

  # Position and direction at a distance along the path. Returns {x y angle},
  # or {{} {} {}} for a distance outside it - a string longer than its path
  # loses the glyphs that do not fit rather than piling them up at the end.
  method TextPathPoint {points lengths distance} {
    if {$distance < 0 || $distance > [lindex $lengths end]} {
      return [list {} {} {}]
    }
    set index 1
    set count [llength $lengths]
    while {$index < $count - 1 && [lindex $lengths $index] < $distance} {
      incr index
    }
    set before [lindex $lengths $index-1]
    set after [lindex $lengths $index]
    set span [expr {$after - $before}]
    set share [expr {$span > 0 ? ($distance - $before) / $span : 0}]

    set ax [lindex $points [expr {2 * ($index - 1)}]]
    set ay [lindex $points [expr {2 * ($index - 1) + 1}]]
    set bx [lindex $points [expr {2 * $index}]]
    set by [lindex $points [expr {2 * $index + 1}]]
    set x [expr {$ax + ($bx - $ax) * $share}]
    set y [expr {$ay + ($by - $ay) * $share}]

    # The angle [text -rotate] takes: positive turns the same way the page
    # coordinates do, and y grows downwards - so a path running up the page
    # needs the sign of dy reversed.
    set angle [expr {atan2($ay - $by, $bx - $ax) * 180.0 / acos(-1)}]
    return [list $x $y $angle]
  }
}

package provide tclpdf::textPath 1.9