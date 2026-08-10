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

    if {[dict get $style fill] ne {}} {
      my rect -at [list $x $y] -size [list $width $height] \
          -fill [dict get $style fill]
    }
    my TableDrawBorder $style $x $y $width $height

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

    set align [dict get $style align]
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
          set at [expr {$x + $width - $padding - [dict get $cell tail]}]
          set anchor right
          set separator [string first [dict get $cell decimal] $line]
          if {$separator >= 0} {
            # The head is set right-aligned to the separator position, the
            # tail left-aligned from it - two calls, because there is no PDF
            # operator that aligns on a character.
            my text [string range $line 0 $separator-1] -at [list $at $top] \
                -anchor top -align right -family [dict get $style family] \
                -style [dict get $style fontStyle] -size [dict get $style size] \
                -color [dict get $style color]
            my text [string range $line $separator end] -at [list $at $top] \
                -anchor top -align left -family [dict get $style family] \
                -style [dict get $style fontStyle] -size [dict get $style size] \
                -color [dict get $style color]
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
      my text $line -at [list $at $top] -anchor top -align $anchor \
          -family [dict get $style family] -style [dict get $style fontStyle] \
          -size [dict get $style size] -color [dict get $style color]
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
    # silence - "outer" in particular, which reads like it should work and is
    # not implemented. A table without rules looks like a theme choice, so
    # nobody goes looking for a typo.
    if {$border ni {none all horizontal vertical}} {
      return -code error "tclpdf: unknown table border \"$border\" - known are:\
          none, all, horizontal, vertical"
    }
    if {$border eq "none" || [dict get $style lineWidth] <= 0} {
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

  # NOT CALLED FROM ANYWHERE, and kept on purpose rather than deleted quietly.
  #
  # It is the finished half of "-border outer": a frame around a whole section,
  # drawn once instead of per cell. What is missing is the other half - the
  # place in table.tcl that knows where a section begins and ends and would
  # call this once it is done. Until then TableDrawBorder refuses "outer"
  # rather than letting it draw nothing, which is what it did before.
  method TableDrawOutline {style x y width height} {
    if {[dict get $style lineWidth] <= 0} {
      return
    }
    my rect -at [list $x $y] -size [list $width $height] \
        -stroke [dict get $style lineColor] -width [dict get $style lineWidth]
    return
  }
}

package provide tclpdf::tableDraw 1.0
