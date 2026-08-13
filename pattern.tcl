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

  # $doc pattern create <name> -size {w h} ?-step {sx sy}? ?-spacing? -script {...}
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
    set options [::tclpdf::option parse {size {} step {} script {} unit {}} \
        $args "pattern create"]
    if {[dict get $options size] eq {}} {
      return -code error "tclpdf: pattern create needs -size {width height}"
    }
    set patterns [my state patterns]
    if {[dict exists $patterns $name]} {
      return -code error "tclpdf: a pattern named \"$name\" already exists"
    }
    set unit [dict get $options unit]
    lassign [my extent [dict get $options size] $unit] widthPoints heightPoints
    # The step is how far apart the tiles sit. Equal to the tile size they
    # touch; larger, and the gaps show through - which is what a caller wants
    # for a sparse watermark rather than a hatch.
    if {[dict get $options step] eq {}} {
      set stepX $widthPoints
      set stepY $heightPoints
    } else {
      lassign [my extent [dict get $options step] $unit] stepX stepY
    }

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
    set number [my streamObject $pairs $content]
    set resourceName Pt[my PatternCount]
    my resource Pattern $resourceName [[my writer] ref $number]
    dict set patterns $name [dict create resource $resourceName \
        width $widthPoints height $heightPoints]
    my state patterns $patterns
    return $name
  }

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

package provide tclpdf::pattern 1.1
