#
# tclpdf - PDF generation for Tcl
#
# tableDraw - putting one measured cell onto the page
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Everything here works on a cell that has already been measured: it knows its
# width, its wrapped lines and its resolved style. Nothing is decided at this
# point, which is why page breaks are possible - see tableLayout.tcl.
#
# This is a private sub-module behind the [table] facade.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::shape 1.0-
# 1.26 for [text -runs 1 -width ... -breakHyphen], one broken line of runs.
package require tclpdf::text 1.26-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::tableDraw {}

oo::define ::tclpdf::document::document {

  # Draw one cell at {x y} - the top left corner - with the height the row
  # settled on.
  method TableDrawCell {cell x y height} {
    set style [dict get $cell resolved]
    set width [dict get $cell width]

    # Fill and rules carry no meaning: they are decoration, and in a tagged
    # document they say so. Without the bracket they would be content that
    # belongs to no element, which a UA validator counts as a defect and a
    # reader may try to announce.
    set art {}
    if {[my state tagged] eq "1"} {
      set art [my StructureMark Artifact]
      my content [my StructureBegin $art]
    }
    # THE DRAWING IS BRACKETED, and that is the whole of it: the mark is
    # written before the cell is painted, and a refusal in between - an
    # unknown colour in the style is the everyday one - used to swallow the
    # EMC. The document then carried an artifact bracket that never closed,
    # every later mark of the DOCUMENT was suppressed (StructureMark returns
    # empty while the flag stands), and veraPDF passed the file with 0 failed
    # checks over 764 rules. Measured 2026-08-25: BDC=6 EMC=5, two paragraphs
    # afterwards with no mark of their own.
    #
    # Same shape as pattern.tcl and pageNumber.tcl: what is opened is closed
    # on both roads, and the error travels on unchanged.
    set failed [catch {
      if {[dict get $style fill] ne {}} {
        my rect -at [list $x $y] -size [list $width $height] \
            -fill [dict get $style fill]
      }
      my TableDrawBorder $style $x $y $width $height
    } drawError drawOptions]
    if {[llength $art]} {
      my content [my StructureEnd $art]
    }
    if {$failed} {
      return -options $drawOptions $drawError
    }

    set lines [dict get $cell lines]
    if {![llength $lines]} {
      return
    }
    # One flag per line, saying whether the "-" that line ends on is a break
    # the breaker made or a character of the text - see TableMeasure, which
    # reads both off the same answer. Defaulted rather than demanded: a
    # didParseCell hook may hand back a cell it built itself, and a cell
    # without the key is a cell whose lines nobody hyphenated.
    set hyphens {}
    if {[dict exists $cell hyphens]} {
      set hyphens [dict get $cell hyphens]
    }
    # A list of a different length is no list at all here: [foreach] over two
    # lists pads the short one with the empty string, and an empty string is
    # not a boolean, so the cell would be refused rather than drawn. A hook
    # that rewrites the lines and leaves the flags where they were is the way
    # that happens.
    if {[llength $hyphens] != [llength $lines]} {
      set hyphens [lrepeat [llength $lines] 0]
    }
    set padding [dict get $style padding]
    set leading [dict get $cell leading]
    set textHeight [expr {[llength $lines] * $leading}]
    # A cell measured as runs (TableMeasure) draws every line as the pairs
    # it came back as - the second road below. Defaulted like the flags: a
    # hook may hand back a cell it built itself.
    set runs {}
    if {[dict exists $cell runs]} {
      set runs [dict get $cell runs]
    }
    # Vertical placement inside the cell. The default is top, because a table
    # whose rows are all one line looks identical either way and the
    # difference only shows once something wraps - by which time a middle
    # default would have moved every other row too.
    switch -- [dict get $style valign] {
      middle {set top [expr {$y + ($height - $textHeight) / 2.0}]}
      bottom {set top [expr {$y + $height - $textHeight - $padding}]}
      default {set top [expr {$y + $padding}]}
    }

    # THE SIDE THE TEXT STARTS AT, in reading order. -align on a cell means
    # the same as it does on [text]: under rtl "left" is the right hand edge.
    # Mirrored through the same method, so the two cannot drift - and mirrored
    # BACK when the value is passed on, because [text] mirrors it again and
    # two mirrorings are none.
    set state [dict create direction [dict get $style direction]]
    set align [my TextAlign [dict get $style align] $state]
    # NO -hyphenate ON THESE CALLS, and that is measured rather than
    # overlooked. The lines below were broken in TableMeasure, hyphens and
    # all, and each is drawn as ONE line: [text] without -width never opens a
    # breaker, so the option would reach a road that does not read it. Handed
    # on here as well it changed not one byte of a tagged German table -
    # compared qdf against qdf on 2026-08-24, 4138 bytes either way.
    #
    # The cell therefore cannot draw a break the measurement did not make.
    # That is not a promise the two lists keep in step with each other; it is
    # the same list. Where the package has been bitten before - the font
    # options of TableFont - two lists existed and one grew a key. Here there
    # is nothing to grow.
    #
    # -breakHyphen IS handed on, and it is the opposite case. A break hyphen
    # is not a character of the text (14.8.2.6), so a tagged document sets it
    # in a Span with an empty ActualText and extraction gives the word back
    # whole. The breaker knows which lines end on one; the STRINGS do not,
    # which is why the flags travel beside them from TableMeasure to here.
    # Until they did, a tagged table extracted as "Betriebskostenab-rechnung".
    #
    # The line is NOT cut up here, and that is the point of doing it this way:
    # the cutting happens inside [text], in the same text object, after the
    # position of the line has been computed from the WHOLE string. So the
    # drawn line starts where the measured one said it starts, at the same Td,
    # for every alignment - which a cell that cut the string itself and made
    # two calls could not promise.
    foreach line $lines hyphen $hyphens {
      # A LINE OF RUNS is drawn by [text -runs 1], which needs the width
      # the line was broken to - a run is a thing of a paragraph, and the
      # line, measured to fit that width, breaks into itself again; so the
      # pieces are set in their faces, the underlines, strikes and link
      # rectangles recorded and drawn, all by the one road every paragraph
      # takes; in a tagged document the marks land in the TD or TH the row
      # opened, as the plain lines' marks do, and a link annotation hangs
      # on that cell (a Link element for a url run is not built, for a cell
      # as for a paragraph). -breakHyphen travels with it: the one case
      # [text] takes the option beside -width, and it holds [text] to ONE
      # line. The three alignments are the block's own, from the same left
      # edge the plain road starts at, so the first baseline of a cell of
      # runs sits where the plain cell beside it sits - measured,
      # table-27.2. decimal cannot reach a BODY cell here: TableRuns
      # refuses it; a head or foot cell without a digit was set to right
      # by TableStyle before, as a plain heading over such a column is.
      if {[llength $runs]} {
        my text $line -runs 1 -width [my TableInner $width $padding] \
            -at [list [expr {$x + $padding}] $top] -anchor top \
            -align [my TextAlign $align $state] {*}[my TableFont $style] \
            -color [dict get $style color] -breakHyphen $hyphen
        set top [expr {$top + $leading}]
        continue
      }
      # What [text] is told about the trailing hyphen. Kept in a variable
      # rather than written into the calls: the option is refused for a
      # string with no hyphen in it (text.tcl), and the decimal road below
      # draws the HEAD of a line as a call of its own - a head that ends
      # before the separator and carries no "-" at all.
      set breakArg [list -breakHyphen $hyphen]
      switch -- $align {
        decimal {
          # The decimal separators line up, whatever comes before them. The
          # column measured how wide the widest tail is (separator plus the
          # digits after it); every cell hangs its own tail into that space,
          # so 4.0000 and 5.50 and 23.54 sit one under the other.
          #
          # Right alignment only looks the same while every number has the
          # same number of decimals - which is exactly the case a test uses
          # and a real price list does not.
          #
          # AND THIS ONE DOES NOT MIRROR under rtl, which is why it sits in
          # front of the switch on the mirrored side: a decimal column holds
          # numbers, and numbers are set left to right in every script that
          # uses them - the digits of a right-to-left line come out as a
          # number for the same reason. So the column keeps its separator
          # where it is, and only the two -align values are handed on in the
          # form that survives [text] mirroring them.
          set at [expr {$x + $width - $padding - [dict get $cell tail]}]
          set anchor right
          set separator [string first [dict get $cell decimal] $line]
          if {$separator >= 0} {
            # The head is set right-aligned to the separator position, the
            # tail left-aligned from it - two calls, because there is no PDF
            # operator that aligns on a character. Unless the separator opens
            # the line (",50"): the head is empty then, and drawing it wrote
            # a bare "() Tj" into the stream.
            if {$separator > 0} {
              my text [string range $line 0 $separator-1] -at [list $at $top] \
                  -anchor top -align [my TextAlign right $state] \
                  {*}[my TableFont $style] -color [dict get $style color]
            }
            # The TAIL carries the break, whatever the head looks like: the
            # tail is what the line ends on.
            my text [string range $line $separator end] -at [list $at $top] \
                -anchor top -align [my TextAlign left $state] \
                {*}[my TableFont $style] -color [dict get $style color] \
                {*}$breakArg
            set top [expr {$top + $leading}]
            continue
          }
          # No separator at all - a dash, a word, an integer. Set flush with
          # where the separators are, so a column of amounts stays a column.
        }
        right {
          set at [expr {$x + $width - $padding}]
          set anchor right
        }
        center {
          set at [expr {$x + $width / 2.0}]
          set anchor center
        }
        default {
          set at [expr {$x + $padding}]
          set anchor left
        }
      }
      my text $line -at [list $at $top] -anchor top \
          -align [my TextAlign $anchor $state] {*}[my TableFont $style] \
          -color [dict get $style color] {*}$breakArg
      set top [expr {$top + $leading}]
    }
    return
  }

  # The cell's rules. Four separate lines rather than a rectangle, because a
  # table almost never wants all four: "horizontal" is the common look, and a
  # stroked rectangle cannot express it.
  method TableDrawBorder {style x y width height} {
    set border [dict get $style border]
    # An unknown value used to fall through every branch and draw NOTHING, in
    # silence. A table without rules looks like a theme choice, so nobody goes
    # looking for a typo. It is refused before the cell is measured - see
    # TableStyleCheck in tableLayout.tcl, which holds the list - so that the
    # cell's fill is not on the page when the rules are refused.
    #
    # "outer" draws nothing per cell on purpose: the frame belongs to the
    # section as a whole and is drawn once, by TableDrawFrame.
    if {$border in {none outer} || [dict get $style lineWidth] <= 0} {
      return
    }
    set colour [dict get $style lineColor]
    set thickness [dict get $style lineWidth]
    set right [expr {$x + $width}]
    set bottom [expr {$y + $height}]
    if {$border in {all horizontal}} {
      my line -from [list $x $y] -to [list $right $y] \
          -stroke $colour -width $thickness
      my line -from [list $x $bottom] -to [list $right $bottom] \
          -stroke $colour -width $thickness
    }
    if {$border in {all vertical}} {
      my line -from [list $x $y] -to [list $x $bottom] \
          -stroke $colour -width $thickness
      my line -from [list $right $y] -to [list $right $bottom] \
          -stroke $colour -width $thickness
    }
    return
  }

  # The frame for "-border outer", drawn once per page rather than four rules
  # per cell. Only TableRun can call this: it is the one place that knows where
  # what was drawn on this page begins and ends - a table breaking over three
  # pages gets three frames, not one that runs off the paper.
  #
  # Height comes from two y coordinates rather than a height because the caller
  # has exactly those: where the section started and where it ended.
  method TableDrawFrame {style widths left top bottom} {
    if {[dict get $style border] ne "outer" || $bottom <= $top} {
      return
    }
    set width 0
    foreach column $widths {
      set width [expr {$width + $column}]
    }
    my TableDrawOutline $style $left $top $width [expr {$bottom - $top}]
    return
  }

  # A frame around a whole section: one rectangle instead of a rule per cell.
  method TableDrawOutline {style x y width height} {
    if {[dict get $style lineWidth] <= 0} {
      return
    }
    my rect -at [list $x $y] -size [list $width $height] \
        -stroke [dict get $style lineColor] -width [dict get $style lineWidth]
    return
  }
}

package provide tclpdf::tableDraw 1.8