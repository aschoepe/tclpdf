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
    set options [::tclpdf::option parse $defaults $args "leader"]
    # The two ends are positional, not options - they are what the row IS.
    # Carried in the same dictionary so that the drawing takes one argument.
    dict set options left $left
    dict set options right $right
    ::tclpdf::option point [dict get $options at] -at leader
    if {[dict get $options width] eq {}} {
      return -code error "tclpdf: leader needs -width - the row is filled to\
          that width, and without it there is nothing to fill"
    }
    # One element for the whole row rather than one per end: the heading and
    # its page number are one entry, and a reader following the tree should
    # hear them together.
    if {[my state tagged] eq "1" && [dict get $options tag] ne "Artifact"} {
      return [my structure [dict get $options tag] -script {
        my LeaderDraw $options
      }]
    }
    return [my LeaderDraw $options]
  }

  method LeaderDraw {options} {
    lassign [dict get $options at] x y
    set width [dict get $options width]
    set font [my LeaderFont $options]
    # The ends normally say nothing: an element is already open around them and
    # they join it. Only -tag Artifact has to reach them, or the row would be
    # taken out of the tree while its two ends stayed in it.
    set ends {}
    if {[dict get $options tag] eq "Artifact"} {
      set ends [list -tag Artifact]
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
    }
    if {[dict get $options left] ne {}} {
      my text [dict get $options left] -at [list $x $y] {*}$ends {*}$font
    }
    # Whole copies only, and the remainder is left in front of the right hand
    # end. Stretching the last one to fit would mean drawing a partial glyph;
    # spreading the gap over all of them would need character spacing and would
    # make two rows of different lengths line up differently.
    if {$fillWidth > 0 && $room >= $fillWidth} {
      set count [expr {int($room / $fillWidth)}]
      set run [string repeat $fill $count]
      # An artifact: the dots are decoration. Outside a tagged document the
      # option costs nothing, which is why it is not made conditional here.
      my text $run -at [list [expr {$x + $leftWidth + $gap}] $y] \
          -tag Artifact {*}$font
    }
    if {[dict get $options right] ne {}} {
      my text [dict get $options right] \
          -at [list [expr {$x + $width}] $y] -align right {*}$ends {*}$font
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
    foreach name $::tclpdf::text::stateOptions {
      lappend font -$name [dict get $options $name]
    }
    return $font
  }
}

package provide tclpdf::leader 1.0
