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
package require tclpdf::text 1.0-
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
    if {[dict get $style fill] ne {}} {
      my rect -at [list $x $y] -size [list $width $height] \
          -fill [dict get $style fill]
    }
    my TableDrawBorder $style $x $y $width $height
    if {[llength $art]} {
      my content [my StructureEnd $art]
    }

    set lines [dict get $cell lines]
    if {![llength $lines]} {
      return
    }
    set padding [dict get $style padding]
    set leading [dict get $cell leading]
    set textHeight [expr {[llength $lines] * $leading}]
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
    foreach line $lines {
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
            # operator that aligns on a character.
            my text [string range $line 0 $separator-1] -at [list $at $top] \
                -anchor top -align [my TextAlign right $state] \
                {*}[my TableFont $style] -color [dict get $style color]
            my text [string range $line $separator end] -at [list $at $top] \
                -anchor top -align [my TextAlign left $state] \
                {*}[my TableFont $style] -color [dict get $style color]
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
          -color [dict get $style color]
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
    # looking for a typo.
    if {$border ni {none all horizontal vertical outer}} {
      return -code error "tclpdf: unknown table border \"$border\" - known are:\
          none, all, horizontal, vertical, outer"
    }
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

package provide tclpdf::tableDraw 1.3
