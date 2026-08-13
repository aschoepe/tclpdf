#
# tclpdf - PDF generation for Tcl
#
# graphics - paths, graphics state and transparency (8.4, 8.5)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The methods here attach themselves to the document class with [oo::define]
# when the module is loaded, which is what keeps the core from growing with
# every feature. Loading is triggered by the first call - see the topic table
# in document.tcl.
#
# Everything goes through Style and Paint. Those two exist because the same
# five lines - colour, width, dash, then the right painting operator - would
# otherwise be repeated in every shape, each version slightly different. The
# painting operator in particular has six spellings (f, S, B, f*, B*, n) and
# picking the wrong one produces a shape that is there but invisible.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::color 1.0-
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::graphics {}

oo::define ::tclpdf::document::document {

  # -- graphics state -----------------------------------------------------

  # q and Q (8.4.2). Always in pairs - an unbalanced q leaves the rest of the
  # page in whatever state the last shape left behind.
  method save {} {
    my content "q\n"
    return
  }

  method restore {} {
    my content "Q\n"
    return
  }

  # $doc transform -at {150 200} -rotate 20
  # $doc transform -translate {10 10} -rotate 45 -scale 2 -skew {0 0}
  #
  # Two different things, and the difference matters:
  #
  #   -at {x y}         a POINT in document coordinates to rotate, scale or
  #                     skew ABOUT. Everything drawn afterwards still uses
  #                     normal document coordinates.
  #   -translate {dx dy} a DELTA: dx to the right, dy DOWNWARDS, matching the
  #                     top-left origin the rest of the API uses.
  #
  # -at is what "put a rotated stamp there" needs. It works by moving to the
  # point, transforming, and moving back - so the page height stays the
  # reference and [coords] keeps working for every shape that follows. Doing
  # it with -translate instead mirrors the y axis a second time and the shape
  # lands somewhere else entirely.
  #
  # Applied in the order translate, rotate, skew, scale. Wrap it in save and
  # restore, or it stays in force for the rest of the page.
  method transform {args} {
    set options [::tclpdf::option parse {
      at {} translate {} rotate {} scale {} skew {} matrix {}
    } $args]
    if {[dict get $options matrix] ne {}} {
      set matrix [dict get $options matrix]
    } else {
      set matrix [::tclpdf::geometry identity]
      if {[dict get $options at] ne {}} {
        # To the origin FIRST: a point q ends up at (q - p) rotated, plus p.
        # The other order rotates the whole page about the origin and then
        # shifts, which puts the shape somewhere else entirely.
        lassign [my coords {*}[dict get $options at]] px py
        set matrix [::tclpdf::geometry multiply $matrix \
            [::tclpdf::geometry translate [expr {-$px}] [expr {-$py}]]]
      }
      if {[dict get $options translate] ne {}} {
        lassign [dict get $options translate] dx dy
        set matrix [::tclpdf::geometry multiply $matrix \
            [::tclpdf::geometry translate [my distance $dx] [expr {-[my distance $dy]}]]]
      }
      if {[dict get $options rotate] ne {}} {
        set matrix [::tclpdf::geometry multiply $matrix \
            [::tclpdf::geometry rotate [dict get $options rotate]]]
      }
      if {[dict get $options skew] ne {}} {
        lassign [dict get $options skew] alpha beta
        set matrix [::tclpdf::geometry multiply $matrix \
            [::tclpdf::geometry skew $alpha $beta]]
      }
      if {[dict get $options scale] ne {}} {
        set matrix [::tclpdf::geometry multiply $matrix \
            [::tclpdf::geometry scale {*}[dict get $options scale]]]
      }
      if {[dict get $options at] ne {}} {
        # And back again - the counterpart to the shift above. Both negative
        # puts the shape off the page; both positive rotates about the origin
        # and then moves. Neither produces an error, only a shape in the wrong
        # place, which is why the pair is written out here rather than folded
        # into the loop above.
        lassign [my coords {*}[dict get $options at]] px py
        set matrix [::tclpdf::geometry multiply $matrix \
            [::tclpdf::geometry translate $px $py]]
      }
    }
    my content "[join [lmap number $matrix {::tclpdf::pdfObj num $number}] { }] cm\n"
    return $matrix
  }

  # Set colour, line width, dash pattern, caps and joins without drawing.
  method style {args} {
    my content [my GraphicsStyle [::tclpdf::option parse {
      fill {} stroke {} width {} dash {} cap {} join {} miter {} opacity {}
      blend {}
    } $args]]
    return
  }

  # Constant alpha via an ExtGState resource (11.6.6). Measured the most
  # frequent feature of the whole corpus at 62.5 % - watermarks, logos, the
  # shaded every-other-row of a table.
  method opacity {value {which both}} {
    set name [my GraphicsOpacity $value $which]
    my content "[::tclpdf::pdfObj name $name] gs\n"
    return $name
  }

  # $doc blend Multiply
  #
  # The blend mode decides how a colour is combined with what is already on the
  # page: Normal replaces it, Multiply darkens, Screen lightens, and the rest of
  # the sixteen do what their names say. Like the alpha it is graphics state, so
  # it holds until changed - and like the alpha a shape can take it per call
  # through -blend, which wraps it in the shape's own q/Q.
  method blend {mode} {
    set name [my GraphicsBlend $mode]
    my content "[::tclpdf::pdfObj name $name] gs\n"
    return $name
  }

  # The sixteen standard modes (11.3.5). Deliberately NOT accepted:
  #
  #   Compatible - deprecated since 1.4 and identical to Normal, so it says
  #   nothing a reader could act on. The array form of /BM is deprecated too;
  #   this writes a single name.
  #
  # PDF/A: parts 2 and 3 permit every standard mode, and part 1 - which allows
  # only Normal - is refused by [pdfa] for other reasons anyway, so there is
  # nothing to check here.
  method GraphicsBlend {mode} {
    set known {Normal Multiply Screen Overlay Darken Lighten ColorDodge
        ColorBurn HardLight SoftLight Difference Exclusion Hue Saturation
        Color Luminosity}
    set match [lsearch -exact -nocase $known $mode]
    if {$match < 0} {
      if {[string equal -nocase $mode Compatible]} {
        return -code error "tclpdf: the blend mode Compatible is deprecated\
            and means Normal - name Normal instead"
      }
      return -code error "tclpdf: unknown blend mode \"$mode\" - known are:\
          [join $known {, }]"
    }
    # The spelling of the standard, whatever the caller typed: a name is a
    # name, and /multiply is not /Multiply to a reader.
    set mode [lindex $known $match]
    set name GB$mode
    if {[my resource ExtGState $name] eq {}} {
      my resource ExtGState $name [[my writer] ref [[my writer] add \
          [::tclpdf::pdfObj dictionary [list Type /ExtGState \
              BM [::tclpdf::pdfObj name $mode]]]]]
    }
    return $name
  }

  # The resource without writing the operator - so that a shape can put the
  # "gs" INSIDE its own q/Q instead of leaking the alpha into the rest of the
  # page. Writing it from here directly used to place it before the "q" that
  # GraphicsStyle now emits, which is exactly the leak this separation ends.
  method GraphicsOpacity {value {which both}} {
    if {![string is double -strict $value] || $value < 0 || $value > 1} {
      return -code error "tclpdf: opacity is a number from 0 to 1, not \"$value\""
    }
    set pairs {Type /ExtGState}
    if {$which in {fill both}} {
      lappend pairs ca [::tclpdf::pdfObj num $value]
    }
    if {$which in {stroke both}} {
      lappend pairs CA [::tclpdf::pdfObj num $value]
    }
    # One resource per distinct value, reused across the document: a name
    # derived from the value is what makes that automatic.
    set name GS[string map {. _ - m} $value][string index $which 0]
    if {[my resource ExtGState $name] eq {}} {
      my resource ExtGState $name \
          [[my writer] ref [[my writer] add [::tclpdf::pdfObj dictionary $pairs]]]
    }
    return $name
  }

  # -- shared internals ---------------------------------------------------

  # Does this call set anything that outlives the shape?
  #
  # Colour, line width, dash, caps, joins and alpha are all GRAPHICS STATE
  # (8.4.1): they survive the painting operator and apply to everything drawn
  # afterwards. So "rect -width 3 -dash {2 2}" used to make the NEXT line thick
  # and dashed as well, with nothing in that call to explain it - measured in
  # the content stream. A shape that sets any of them is therefore wrapped in
  # q/Q by GraphicsStyle and GraphicsPaint together.
  #
  # [style] deliberately does NOT guard: its whole purpose is to set the state
  # until changed, which is what the manual promises.
  method GraphicsGuarded {options} {
    foreach key {fill stroke width dash cap join miter opacity blend} {
      if {[dict exists $options $key] && [dict get $options $key] ne {}} {
        return 1
      }
    }
    return 0
  }

  # Colour, line width, dash and joins - the part every shape needs and none
  # of them should spell out.
  method GraphicsStyle {options {guard 0}} {
    set result {}
    # In a tagged document a shape is marked content like anything else:
    # inside an open Figure it belongs to that Figure, and everywhere else it
    # is decoration and says so. Under PDF/UA content that is neither counts
    # as a defect.
    #
    # The bracket opens here and closes in GraphicsPaint, the two ends of
    # every primitive in this package - seven methods share them, and putting
    # it in each of them is how the pair drifts apart. The mark travels
    # through the state because the two are separate calls; shapes do not
    # nest, so one slot is enough.
    if {[my state tagged] eq "1"} {
      set mark [my StructureMark auto]
      my state structureShape $mark
      append result [my StructureBegin $mark]
    }
    if {$guard && [my GraphicsGuarded $options]} {
      append result "q\n"
    }
    foreach {key which} {fill fill stroke stroke} {
      if {[dict exists $options $key] && [dict get $options $key] ne {}} {
        append result [::tclpdf::color operator \
            [::tclpdf::color parse [my GraphicsColour [dict get $options $key]]] \
            $which] "\n"
      }
    }
    if {[dict exists $options opacity] && [dict get $options opacity] ne {}} {
      append result "[::tclpdf::pdfObj name \
          [my GraphicsOpacity [dict get $options opacity]]] gs\n"
    }
    # A second "gs" rather than one combined state: the operator is cumulative
    # (11.6.6), so setting the mode leaves the alpha standing and the two stay
    # one resource each instead of one per combination.
    if {[dict exists $options blend] && [dict get $options blend] ne {}} {
      append result "[::tclpdf::pdfObj name \
          [my GraphicsBlend [dict get $options blend]]] gs\n"
    }
    if {[dict exists $options width] && [dict get $options width] ne {}} {
      append result "[::tclpdf::pdfObj num [my distance [dict get $options width]]] w\n"
    }
    if {[dict exists $options dash] && [dict get $options dash] ne {}} {
      set dash [dict get $options dash]
      if {$dash in {none solid {}}} {
        append result "\[\] 0 d\n"
      } else {
        set lengths [lmap number $dash {::tclpdf::pdfObj num [my distance $number]}]
        append result "\[[join $lengths { }]\] 0 d\n"
      }
    }
    if {[dict exists $options cap] && [dict get $options cap] ne {}} {
      set caps {butt 0 round 1 square 2}
      set cap [dict get $options cap]
      if {![dict exists $caps $cap]} {
        return -code error "tclpdf: line cap must be butt, round or square,\
            not \"$cap\""
      }
      append result "[dict get $caps $cap] J\n"
    }
    if {[dict exists $options join] && [dict get $options join] ne {}} {
      set joins {miter 0 round 1 bevel 2}
      set style [dict get $options join]
      if {![dict exists $joins $style]} {
        return -code error "tclpdf: line join must be miter, round or bevel,\
            not \"$style\""
      }
      append result "[dict get $joins $style] j\n"
    }
    if {[dict exists $options miter] && [dict get $options miter] ne {}} {
      append result "[::tclpdf::pdfObj num [dict get $options miter]] M\n"
    }
    return $result
  }

  # Translate a caller's colour into one the colour module can read.
  #
  # Only {pattern <name>} needs translating, and it needs it here because the
  # caller's name is a document-wide alias while the content stream wants the
  # resource name. The colour module knows colour spaces, the document knows
  # names - neither could do this alone.
  method GraphicsColour {spec} {
    if {[llength $spec] == 2 && [string tolower [lindex $spec 0]] eq "pattern"} {
      package require tclpdf::pattern
      return [list pattern [my PatternResource [lindex $spec 1]]]
    }
    return $spec
  }

  # The painting operator. Six spellings, and the wrong one draws nothing at
  # all without any error - which is why this is derived rather than typed.
  method GraphicsPaint {options {guard 0}} {
    set hasFill [expr {[dict exists $options fill] && [dict get $options fill] ne {}}]
    set hasStroke [expr {[dict exists $options stroke] && [dict get $options stroke] ne {}}]
    set evenOdd [expr {[dict exists $options rule]
        && [dict get $options rule] eq "evenodd"}]
    # The counterpart to the "q" GraphicsStyle wrote - the same condition, so
    # the two cannot get out of step.
    set close [expr {$guard && [my GraphicsGuarded $options] ? "Q\n" : ""}]
    # And the counterpart to the bracket it opened. It goes AFTER the Q, so
    # the marked content encloses the whole thing rather than crossing it -
    # BDC and q have to nest, not overlap (14.6.1).
    if {[my state tagged] eq "1"} {
      set mark [my state structureShape]
      my state structureShape {}
      append close [my StructureEnd $mark]
    }
    if {$hasFill && $hasStroke} {
      return [expr {$evenOdd ? "B*\n" : "B\n"}]$close
    }
    if {$hasFill} {
      return [expr {$evenOdd ? "f*\n" : "f\n"}]$close
    }
    if {$hasStroke} {
      return "S\n$close"
    }
    # Neither given: end the path without painting, so the path construction
    # does not leak into whatever comes next.
    return "n\n$close"
  }

}

package provide tclpdf::graphics 1.2
