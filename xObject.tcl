#
# tclpdf - PDF generation for Tcl
#
# xObject - form XObjects, drawn once and placed many times (8.10)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A form XObject is a piece of content stored ONCE and referenced wherever it
# appears - a logo on five pages is stored once, not five times, and the file
# stops growing with the page count.
#
# Usage:
#
#   $doc form create letterhead -size {210 40} -script {
#     $doc rect -at {0 0} -size {210 40} -fill {0.9 0.9 0.95}
#     $doc text "Musterfirma GmbH" -at {10 15} -size 14
#   }
#   $doc form place letterhead -at {0 0}
#   $doc page add
#   $doc form place letterhead -at {0 0}      ;# no second copy in the file
#
# Inside the script coordinates count from the FORM's top left corner, exactly
# as they count from the page's everywhere else - {0 0} is the top left, y
# grows downwards, and every drawing method works unchanged. What differs is
# only the reference: [coords] mirrors against the form height instead of the
# page height, which is what the canvas stack in the core is for.
#
# Keeping one convention matters more than it looks. PDF itself puts a form's
# origin at its BOTTOM left, and passing that through to the caller would mean
# the same [rect] call behaves differently depending on where it stands.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::xObject {}

oo::define ::tclpdf::document::document {

  # $doc form create <name> -size {w h} -script {...}
  # $doc form place  <name> ?-at {x y}? ?-scale 1.5? ?-rotate 15?
  # $doc form names
  # $doc form size <name>
  method form {subcommand args} {
    switch -- $subcommand {
      create {return [my FormCreate {*}$args]}
      place {return [my FormPlace {*}$args]}
      names {return [dict keys [my state forms]]}
      size {return [my FormSize {*}$args]}
      default {
        return -code error "tclpdf: unknown form subcommand \"$subcommand\" -\
            known are: create, place, names, size"
      }
    }
  }

  method FormCreate {name args} {
    set options [::tclpdf::option parse {size {} script {} unit {}} $args \
        "form create"]
    if {[dict get $options size] eq {}} {
      return -code error "tclpdf: form create needs -size {width height}"
    }
    # An empty -script is allowed: a form with no content is a valid object
    # and useful as a placeholder. Only the size is genuinely required, since
    # the bounding box cannot be guessed from an empty script.
    set forms [my state forms]
    if {[dict exists $forms $name]} {
      return -code error "tclpdf: a form named \"$name\" already exists"
    }
    lassign [my extent [dict get $options size] [dict get $options unit]] \
        widthPoints heightPoints

    # The script draws onto a temporary page whose height is the form height -
    # that way [coords] mirrors against the right value and every existing
    # drawing method works unchanged inside a form.
    my FormBegin $widthPoints $heightPoints
    set failed [catch {uplevel #0 [dict get $options script]} result options0]
    set content [my FormEnd]
    if {$failed} {
      return -options $options0 $result
    }

    set pairs [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [list 0 0 \
            [::tclpdf::pdfObj num $widthPoints] \
            [::tclpdf::pdfObj num $heightPoints]]]]
    # No /Resources of its own: the form inherits the page tree's dictionary,
    # which is where fonts and images already live. A private copy would mean
    # embedding the same font twice.
    set number [my streamObject $pairs $content]
    set resourceName XO[my FormCount]
    my resource XObject $resourceName [[my writer] ref $number]
    dict set forms $name [dict create resource $resourceName \
        width $widthPoints height $heightPoints]
    my state forms $forms
    return $name
  }

  method FormPlace {name args} {
    set options [::tclpdf::option parse \
        {at {} scale 1 rotate 0 opacity {}} $args "form place"]
    set forms [my state forms]
    if {![dict exists $forms $name]} {
      return -code error "tclpdf: no form named \"$name\" - known are:\
          [join [dict keys $forms] {, }]"
    }
    set form [dict get $forms $name]
    lassign [expr {[dict get $options at] eq {} ? {0 0} : [dict get $options at]}] x y

    # -at names the TOP left corner, like rect - so the placement matches how
    # the rest of the API is used, even though the form's own origin is at its
    # bottom left.
    set height [dict get $form height]
    set heightUnit [::tclpdf::geometry fromPoints $height [my cget -unit]]
    lassign [my coords $x [expr {$y + $heightUnit * [dict get $options scale]}]] px py

    my save
    if {[dict get $options opacity] ne {}} {
      my opacity [dict get $options opacity]
    }
    set matrix [::tclpdf::geometry translate $px $py]
    if {[dict get $options rotate] != 0} {
      set matrix [::tclpdf::geometry multiply \
          [::tclpdf::geometry rotate [dict get $options rotate]] $matrix]
    }
    if {[dict get $options scale] != 1} {
      set matrix [::tclpdf::geometry multiply \
          [::tclpdf::geometry scale [dict get $options scale]] $matrix]
    }
    my content "[join [lmap number $matrix {::tclpdf::pdfObj num $number}] { }] cm\n"
    my content "[::tclpdf::pdfObj name [dict get $form resource]] Do\n"
    my restore
    return $name
  }

  method FormSize {name} {
    set forms [my state forms]
    if {![dict exists $forms $name]} {
      return -code error "tclpdf: no form named \"$name\""
    }
    set form [dict get $forms $name]
    set unit [my cget -unit]
    return [list [::tclpdf::geometry fromPoints [dict get $form width] $unit] \
        [::tclpdf::geometry fromPoints [dict get $form height] $unit]]
  }

  method FormCount {} {
    set count [my state formCount]
    if {$count eq {}} {
      set count 0
    }
    incr count
    my state formCount $count
    return $count
  }

  # Redirect drawing into the form. The canvas stack in the core does the
  # work, so every existing method - shapes, text, even a nested form - keeps
  # working inside a form without knowing that forms exist.
  method FormBegin {width height} {
    my canvas push $width $height
    return
  }

  method FormEnd {} {
    return [my canvas pop]
  }
}

package provide tclpdf::xObject 1.0
