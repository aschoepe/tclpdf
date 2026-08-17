#
# tclpdf - PDF generation for Tcl
#
# pattern - tiling patterns, pattern type 1 (8.7.3.3)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A tiling pattern is a small piece of content the reader repeats across
# whatever is being filled - a hatch, a watermark grid, a security tint.
#
#   $doc pattern create hatch -size {4 4} -script {
#     $doc line -from {0 4} -to {4 0} -stroke {0.8 0.8 0.85} -width 0.3
#   }
#   $doc rect -at {20 20} -size {80 40} -fill {pattern hatch}
#
# The script draws into the tile exactly the way it draws onto a page, because
# the canvas stack in the core redirects it - the same mechanism form XObjects
# use, and the reason neither needs a line of its own in [rect] or [text].
#
# Shading patterns (pattern type 2) are in shading.tcl. Both register under
# /Pattern and both are used through -fill {pattern <name>}, so a caller does
# not have to know which of the two kinds a name refers to.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::pattern {}

oo::define ::tclpdf::document::document {

  # $doc pattern create <name> -size {w h} ?-step {sx sy}? ?-unit u?
  #     ?-matrix {a b c d e f}? ?-origin {x y}? -script {...}
  # $doc pattern names
  # $doc pattern size <name>
  method pattern {subcommand args} {
    switch -- $subcommand {
      create {return [my PatternCreate {*}$args]}
      names {return [dict keys [my state patterns]]}
      size {return [my PatternSize {*}$args]}
      default {
        return -code error "tclpdf: unknown pattern subcommand \"$subcommand\"\
            - known are: create, names, size"
      }
    }
  }

  method PatternCreate {name args} {
    set options [::tclpdf::option parse {
      size {} step {} script {} unit {} matrix {} origin {}
    } $args "pattern create"]
    if {[dict get $options size] eq {}} {
      return -code error "tclpdf: pattern create needs -size {width height}"
    }
    set patterns [my state patterns]
    if {[dict exists $patterns $name]} {
      return -code error "tclpdf: a pattern named \"$name\" already exists"
    }
    # Patterns and the Pattern colour space are PDF 1.2 (Reference 1.7, 4.6
    # and Table 4.12). Before the script runs, so a refused pattern draws
    # nothing.
    my RequireVersion 1.2 "pattern"
    set unit [dict get $options unit]
    lassign [my extent [dict get $options size] $unit] widthPoints heightPoints
    if {$widthPoints <= 0 || $heightPoints <= 0} {
      return -code error "tclpdf: -size of pattern \"$name\" is\
          {[dict get $options size]} - a tile needs a width and a height above zero"
    }
    # The step is how far apart the tiles sit. Equal to the tile size they
    # touch; larger, and the gaps show through - which is what a caller wants
    # for a sparse watermark rather than a hatch.
    if {[dict get $options step] eq {}} {
      set stepX $widthPoints
      set stepY $heightPoints
    } else {
      lassign [my extent [dict get $options step] $unit] stepX stepY
    }
    # Neither may be zero (Table 75: XStep and YStep "shall not be zero") -
    # a tile that repeats every nothing is one a reader cannot lay. Negative
    # is permitted there and left alone.
    foreach {axis step} [list X $stepX Y $stepY] {
      if {$step == 0} {
        return -code error "tclpdf: the ${axis} step of pattern \"$name\"\
            is 0 - a step shall not be zero (ISO 32000-1 Table 75)"
      }
    }
    # Before the canvas is pushed: -origin goes through [coords], and inside
    # the tile that would mirror against the tile's height instead of the
    # page's. And before the script runs, so a refused matrix leaves nothing
    # behind - no object, no resource entry.
    set matrix [my PatternMatrix $name $options]

    my canvas push $widthPoints $heightPoints
    # A tiling pattern is a content stream of its own - same reasoning as a
    # form XObject: an MCID is unique per stream, and this counter is per
    # page. Nothing inside a pattern is marked; the shape that USES the
    # pattern carries the marking.
    set suspended [my state structureSuspend]
    my state structureSuspend 1
    set failed [catch {uplevel #0 [dict get $options script]} result outcome]
    my state structureSuspend $suspended
    set content [my canvas pop]
    if {$failed} {
      return -options $outcome $result
    }

    set pairs [list Type /Pattern PatternType 1 \
        PaintType 1 TilingType 1 \
        BBox [::tclpdf::pdfObj arr [list 0 0 \
            [::tclpdf::pdfObj num $widthPoints] \
            [::tclpdf::pdfObj num $heightPoints]]] \
        XStep [::tclpdf::pdfObj num $stepX] \
        YStep [::tclpdf::pdfObj num $stepY] \
        Resources [[my writer] ref [my reservation output.resources]]]
    if {$matrix ne {}} {
      lappend pairs Matrix [::tclpdf::pdfObj arr \
          [lmap number $matrix {::tclpdf::pdfObj num $number}]]
    }
    set number [my streamObject $pairs $content]
    set resourceName Pt[my PatternCount]
    my resource Pattern $resourceName [[my writer] ref $number]
    dict set patterns $name [dict create resource $resourceName \
        width $widthPoints height $heightPoints]
    my state patterns $patterns
    return $name
  }

  # The /Matrix of a tiling pattern (Table 75), or the empty string for none.
  #
  # Pattern space is bound to the DEFAULT space of the page, not to whatever
  # transformation is active when the shape is painted (8.7.3.1) - the same
  # trap shading.tcl spells out at its PatternType 2 dictionary, and it holds
  # here unchanged, inside a form as much as under an SVG transform. Without a
  # matrix the tiles are laid from the page's bottom left corner: a rectangle
  # at {30 50} gets them cut at whatever phase falls on its edge, and turning
  # or scaling the hatch is only possible inside the tile script.
  #
  # -matrix is the raw thing, six numbers written as they stand - the same
  # words as [transform -matrix] and [shading pattern -matrix]. -origin is the
  # convenient case: a point in DOCUMENT coordinates (unit, y from the top,
  # like -at) that the tile grid starts from, turned into a translation.
  #
  # The matrix belongs to the pattern OBJECT, which is written once - a
  # caller who wants the same hatch anchored at two corners registers it
  # twice, under two names. Filling with a matrix per shape would need a
  # pattern object per fill, and the name would no longer name one thing.
  #
  # Both together are refused rather than combined, the way [transform] lets
  # -matrix silence every other option: a caller who has a matrix has the
  # translation in it already, and "which of the two is applied first" is
  # a question nobody should have to look up.
  method PatternMatrix {name options} {
    set matrix [dict get $options matrix]
    set origin [dict get $options origin]
    if {$matrix ne {} && $origin ne {}} {
      return -code error "tclpdf: pattern \"$name\" takes either -matrix or\
          -origin, not both - a matrix carries its own translation"
    }
    if {$origin ne {}} {
      if {[llength $origin] != 2} {
        return -code error "tclpdf: -origin of pattern \"$name\" is a point\
            {x y}, not \"$origin\""
      }
      return [::tclpdf::geometry translate {*}[my coords {*}$origin]]
    }
    if {$matrix eq {}} {
      return {}
    }
    # Six finite numbers and not singular - the one check every raw -matrix
    # gets (geometry.tcl), here before the pattern object is written. A
    # singular pattern matrix squashes the tiles onto a line: a reader paints
    # nothing or gives up, and no validator objects to a well-formed array in
    # the right place.
    return [::tclpdf::geometry check $matrix "pattern \"$name\""]
  }

  # The tile in the document unit - the BBox of pattern space, UNSCALED: a
  # -matrix that doubles the tile does not change this answer, because taking
  # it apart into a scale and a turn is not something a caller wants done
  # behind the name "size".
  method PatternSize {name} {
    set patterns [my state patterns]
    if {![dict exists $patterns $name]} {
      return -code error "tclpdf: no pattern named \"$name\""
    }
    set pattern [dict get $patterns $name]
    set unit [my cget -unit]
    return [list [::tclpdf::geometry fromPoints [dict get $pattern width] $unit] \
        [::tclpdf::geometry fromPoints [dict get $pattern height] $unit]]
  }

  method PatternCount {} {
    set count [my state patternCount]
    if {$count eq {}} {
      set count 0
    }
    incr count
    my state patternCount $count
    return $count
  }

  # The resource name behind a caller's pattern name, for whichever of the two
  # kinds it is. Used by graphics.tcl when a colour reads {pattern <name>} -
  # that is the one place the two registries have to be looked at together.
  method PatternResource {name} {
    set patterns [my state patterns]
    if {[dict exists $patterns $name]} {
      return [dict get $patterns $name resource]
    }
    set shadings [my state shadings]
    if {[dict exists $shadings $name]} {
      return [dict get $shadings $name]
    }
    return -code error "tclpdf: no pattern named \"$name\" - known are:\
        [join [concat [dict keys $patterns] [dict keys $shadings]] {, }]"
  }
}

package provide tclpdf::pattern 1.2
