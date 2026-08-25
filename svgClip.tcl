#
# tclpdf - PDF generation for Tcl
#
# svgClip - what stays visible: clip paths and masks
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Two SVG properties limit what of an element reaches the page, and PDF has
# a device for each: clip-path becomes a clipping path (W n), mask becomes a
# luminosity soft mask in an ExtGState. Neither is an approximation - the
# shapes are the same shapes, and the mask's grey value IS the alpha.
#
# What the corpus asked for, measured on 2026-08-25 over every SVG on this
# machine (15046 files, both spellings - the element and the attribute):
#
#   clip-path   33 files, and inside those clipPath elements: 184 rect,
#               3 path, 1 polygon. Not one carries a transform, and all 181
#               clipPathUnits say userSpaceOnUse
#   mask         4 files, all four maskUnits userSpaceOnUse
#   clip-rule    5 spellings, all evenodd - so W* is needed, not just W
#
# THAT MEASUREMENT CORRECTED THE ONE BEFORE IT, and the correction is the
# reason this module is as narrow as it is. The roadmap carried "clipPath
# 7.8 %, mask 6.0 %, filter 4.2 % of 167 files", which reads as 13, 10 and 7
# files - and led to "twenty to forty times more frequent than first
# measured". Counted absolutely rather than as a percentage of a sample, it
# is 33, 4 and 2. The sample had excluded a 492-file collection in which 24
# of the 33 clip paths live, so clip-path came out too LOW and the other two
# too high.
#
# objectBoundingBox units are therefore not built for either property: they
# do not occur once in 15046 files. They are reported through [svg info]
# like any other omission rather than silently ignored, and the element is
# then drawn UNCLIPPED - visible and complete beats invisible or wrongly
# cut, and [svg info] says which it was.
#
# Filters are not here and are not coming. Two files in the whole corpus
# carry one, both the same publisher's documentation logo, and the only
# primitive in either is feColorMatrix - a per-pixel operation that PDF has
# no operator for. Drawing it would mean rasterising the drawing, which is
# what this module exists to avoid.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::xml 1.0-
package require tclpdf::svgPath 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::svgClip {
}

oo::define ::tclpdf::document::document {

  # One property as it stands on ONE element: the presentation attribute, and
  # the style="" declaration that beats it. A declaration in style="" is a
  # CSS declaration and outranks a presentation attribute (SVG 1.1, 6.4), and
  # that is true of every property this module reads - clip-path, mask and
  # clip-rule alike. Here once, so the three cannot drift: clip-rule used to
  # be the one read straight off the attribute, and style="clip-rule:evenodd"
  # then filled the hole in the shape it was supposed to punch.
  method SvgClipProperty {node property} {
    set value [::tclpdf::xml attribute $node $property]
    foreach {-> key text} [regexp -all -inline {([-a-z]+)\s*:\s*([^;]+)} \
        [::tclpdf::xml attribute $node style]] {
      if {$key eq $property} {
        set value [string trim $text]
      }
    }
    return $value
  }

  # The id a clip-path or mask property points at, or the empty string.
  #
  # Neither property is inherited (SVG 1.1, 14.3.5 and 14.4), so the node's
  # own attribute and its own style="" are the only places looked at - a
  # group carrying clip-path must not clip its children a second time each.
  method SvgClipReference {node property} {
    set value [my SvgClipProperty $node $property]
    if {$value eq {} || $value eq "none"} {
      return {}
    }
    if {![regexp {^url\(\s*['"]?#([^'")\s]+)} $value -> id]} {
      return {}
    }
    return $id
  }

  # Open whatever limits this element's visibility, and answer how many
  # brackets the caller has to close again. Nothing opened, nothing to
  # close: the usual answer is 0 and costs one dict lookup.
  method SvgClipEnter {node} {
    set opened 0
    set clip [my SvgClipReference $node clip-path]
    set mask [my SvgClipReference $node mask]
    if {$clip eq {} && $mask eq {}} {
      return 0
    }
    # The clipping path first and the mask second, so that the mask's own
    # ExtGState is set inside the clip rather than beside it: a masked
    # element that is also clipped has to obey both.
    if {$clip ne {}} {
      set operators [my SvgClipOperators $clip]
      if {$operators ne {}} {
        my SvgSave
        incr opened
        my content $operators
        # W and W* take the same two winding rules a fill does, and the
        # property is spelled clip-rule rather than fill-rule (SVG 14.3.5).
        #
        # ONLY THE CLIPPING SHAPES ARE ASKED. The same section says clip-rule
        # "applies to graphics elements within a clipPath", and the element
        # doing the referring is not one of those - it is being clipped, not
        # clipping. Read here first, it overruled the shape that does carry
        # the property: an evenodd clipPath referenced from an element with
        # no clip-rule of its own came out as W, and the hole in the shape
        # was filled in instead of punched out.
        my content \
            "[expr {[my SvgClipRuleOf $clip] eq "evenodd" ? {W*} : {W}}] n\n"
      }
    }
    if {$mask ne {}} {
      set name [my SvgClipMask $mask]
      if {$name ne {}} {
        my SvgSave
        incr opened
        my content "[::tclpdf::pdfObj name $name] gs\n"
      }
    }
    return $opened
  }

  # The clip-rule of the clipping shapes themselves. A clipPath's children
  # may each carry one; the package writes ONE path with all of them in it,
  # so the rule has to be common. Measured: all five spellings in the corpus
  # sit on the shape, none on the referring element, and no clipPath mixes
  # two - so the first one found rules the path, and a second, different one
  # is reported rather than silently overruled.
  #
  # AND IT IS AN INHERITED PROPERTY (SVG 1.1, 6.2), so the <clipPath> element
  # itself is asked before its children: <clipPath clip-rule="evenodd"> with
  # plain shapes inside is the file's way of saying it once instead of on
  # every shape, and looking only at the children's own attributes answered
  # "no rule" and wrote W.
  #
  # AND SO ARE ITS ANCESTORS, since 2026-08-25. A clipPath sits in a <defs>
  # inside the <svg>, and either of those may carry the property for
  # everything below it - the same one sentence of 6.2. Until [xml parent]
  # existed the walk could only go downwards and this level was out of reach;
  # the reasoning for building the way up rather than gathering the property
  # during [SvgCollect] is in xml.tcl at [parent].
  method SvgClipRuleOf {id} {
    set node [my SvgDefinition $id]
    if {$node eq {}} {
      return {}
    }
    set inherited [my SvgClipRuleInherited $node]
    set rule {}
    foreach child [::tclpdf::xml children $node] {
      set own [my SvgClipProperty $child clip-rule]
      if {$own eq {}} {
        set own $inherited
      }
      if {$own eq {}} {
        continue
      }
      if {$rule eq {} } {
        set rule $own
      } elseif {$own ne $rule} {
        my SvgSkipped clip-rule
      }
    }
    return $rule
  }

  # What a clipPath inherits from what encloses it: the nearest ancestor that
  # states clip-rule, its own value included, or the empty string when none of
  # them does.
  #
  # The way up stops at the <svg> root, where [xml parent] answers the empty
  # string - and in the usual file the first question already ends the walk,
  # because the clipPath either states the property or its <defs> does not.
  #
  # HOW OFTEN, counted on 2026-08-25 over all 14 998 SVG on this machine: not
  # one clipPath inherits clip-rule from an ancestor. It is built anyway, and
  # not out of tidiness - inheritance is what the property MEANS, a file that
  # says it once at the top of the drawing was read as saying nothing at all,
  # and the wrong winding rule is the failure this whole module is about: a
  # hole filled in rather than punched out, on a page every checker calls
  # correct.
  method SvgClipRuleInherited {node} {
    return [my SvgInherited $node clip-rule]
  }

  # The nearest ancestor that names an inherited property, the node itself
  # included - attribute or style="", whichever it wrote.
  #
  # Written for clip-rule and general because the question is: SVG 1.1, 6.2
  # makes a whole list of properties inherited, and everything reached
  # through a reference rather than by being walked into - a <clipPath>, the
  # content of a <mask> - starts from nothing unless somebody asks upward.
  # The walk stops at the first answer, which is what inheritance means.
  method SvgInherited {node property} {
    while {$node ne {}} {
      set value [my SvgClipProperty $node $property]
      if {$value ne {}} {
        return $value
      }
      set node [::tclpdf::xml parent $node]
    }
    return {}
  }

  # The style a referenced subtree starts from: the initial values, with
  # every inherited property its ancestors name written over them.
  #
  # A <mask> is declared under <defs> and drawn where it is USED, so nothing
  # walks into it and its content began from the bare initial values - a
  # mask under a <g fill="white"> painted black, which in a luminosity mask
  # means "hide everything". The list of what inherits is svg.tcl's, in one
  # place, because it is the same list the element walk uses.
  method SvgInheritedStyle {node} {
    variable ::tclpdf::svg::inherited
    set style [dict create fill black stroke none]
    foreach property $inherited {
      set value [my SvgInherited $node $property]
      if {$value ne {}} {
        dict set style $property $value
      }
    }
    return $style
  }

  # The path operators of a <clipPath>, in the element's own coordinates.
  #
  # Several children become several subpaths of ONE path, which is what
  # makes their union the clipping region - PDF has no operator for
  # intersecting two clipping paths in the other direction, and a second
  # W n would narrow rather than widen.
  method SvgClipOperators {id} {
    set node [my SvgDefinition $id]
    if {$node eq {}} {
      # A dangling reference. SVG 1.1 renders the element unclipped in this
      # case (14.3.5 refers to the error processing of 3.6), which is what
      # happens here - counted, so [svg info] shows it.
      my SvgSkipped clip-path
      return {}
    }
    if {[string map {svg: {}} [::tclpdf::xml name $node]] ne "clipPath"} {
      my SvgSkipped clip-path
      return {}
    }
    set units [::tclpdf::xml attribute $node clipPathUnits]
    if {$units ne {} && $units ne "userSpaceOnUse"} {
      # objectBoundingBox, which does not occur once in the corpus. The
      # element is drawn whole rather than cut by a box worked out from the
      # wrong space.
      my SvgSkipped clipPathUnits
      return {}
    }
    set operators {}
    foreach child [::tclpdf::xml children $node] {
      set name [string map {svg: {}} [::tclpdf::xml name $child]]
      if {[::tclpdf::xml attribute $child transform] ne {}} {
        # Not one of the 188 clipPath elements measured carries a transform.
        # Honouring it would mean mapping the shape helpers' output through
        # a matrix, which they do not take - so it is reported instead of
        # quietly dropped, which would cut the wrong region.
        my SvgSkipped clip-transform
        continue
      }
      switch -- $name {
        path {
          append operators [::tclpdf::svgPath operators \
              [::tclpdf::xml attribute $child d] $::tclpdf::svg::identity]
        }
        rect - circle - ellipse - polyline - polygon {
          append operators [my SvgShape $name $child]
        }
        default {
          # <text> and <use> may clip too (SVG 14.3.5). Neither occurs in
          # the corpus, and a text clip needs the glyph outlines the text
          # road does not hand back.
          my SvgSkipped clip-$name
        }
      }
    }
    return $operators
  }

  # A <mask> as a luminosity soft mask.
  #
  # The grey value of the mask's rendering IS the alpha: white shows the
  # element, black hides it, and PDF works that out itself once the group is
  # declared /S /Luminosity. Nothing has to be sampled or converted here -
  # which is exactly why this is worth building and a filter is not.
  #
  # Returns the ExtGState resource name, or the empty string when the mask
  # cannot be honoured - the element is then drawn unmasked, and [svg info]
  # says so.
  method SvgClipMask {id} {
    set node [my SvgDefinition $id]
    if {$node eq {} ||
        [string map {svg: {}} [::tclpdf::xml name $node]] ne "mask"} {
      my SvgSkipped mask
      return {}
    }
    # THE TWO UNIT ATTRIBUTES HAVE DIFFERENT DEFAULTS, and reading them as
    # one was wrong in both directions (found 2026-08-25, the day this was
    # built). SVG 1.1, 14.4: maskContentUnits defaults to userSpaceOnUse -
    # which is what this module draws - while maskUnits defaults to
    # objectBoundingBox and governs the mask REGION, not its content. Read
    # as one, a mask with no attribute at all was accepted and the written
    # out default was refused: exactly backwards.
    set contentUnits [::tclpdf::xml attribute $node maskContentUnits]
    if {$contentUnits ne {} && $contentUnits ne "userSpaceOnUse"} {
      my SvgSkipped maskContentUnits
      return {}
    }
    # The region. Left out, it is -10% to 110% of the object's box, which is
    # everything the mask draws and then some - so the bounds of the content
    # are the honest answer. Written out in user space it is a rectangle
    # this module can honour; in the default units it would need the box of
    # the element being masked, which is not known here.
    set region {}
    set stated {}
    foreach key {x y width height} {
      set value [::tclpdf::xml attribute $node $key]
      if {$value ne {}} {
        lappend stated $key
        lappend region [my SvgLength $value 0]
      }
    }
    set regionUnits [::tclpdf::xml attribute $node maskUnits]
    if {[llength $stated] && $regionUnits ne "userSpaceOnUse"} {
      # A region in fractions of a box this module does not have.
      my SvgSkipped maskUnits
      return {}
    }
    if {[llength $stated] && [llength $stated] != 4} {
      # Half a rectangle says less than none: the missing half would fall
      # back to a percentage of a box that is not being read either.
      my SvgSkipped maskRegion
      set region {}
    }
    # A soft mask is transparency, and transparency is PDF 1.4 (ISO 32000-1,
    # 11.6.5). Asked before anything is drawn, so an older document is told
    # what it lacks instead of getting a resource no reader will honour.
    my RequireVersion 1.4 "svg mask"
    set cached [my state svgMaskNames]
    if {$cached ne {} && [dict exists $cached $id]} {
      return [dict get $cached $id]
    }
    # The capture is the same one a transparency group uses, which is why it
    # lives in svgElement.tcl rather than twice.
    # THE CONTENT INHERITS, like every other subtree (SVG 1.1, 6.2). Handed
    # an empty style it started from no fill at all, so a shape without one
    # of its own painted nothing, the bounds came back empty and the mask
    # was dropped as "draws nothing" - the element then went out UNMASKED.
    # The initial value of fill is black (SVG 11.3), which is what SvgRoot
    # gives the drawing itself.
    lassign [my SvgCapture {
      foreach child [::tclpdf::xml children $node] {
        my SvgElement $child [my SvgStyle $node [my SvgInheritedStyle $node]]
      }
    }] content bounds
    if {$bounds eq {}} {
      # A mask that draws nothing is a mask of black: it would hide the
      # element entirely. Reported and dropped - an element that vanishes
      # without a word is the failure this package keeps out.
      my SvgSkipped mask
      return {}
    }
    my SvgGroupBox {*}$bounds
    if {[llength $region] == 4} {
      # x, y, width, height as the four corners the BBox takes.
      lassign $region regionX regionY regionWidth regionHeight
      set bounds [list $regionX $regionY [expr {$regionX + $regionWidth}] \
          [expr {$regionY + $regionHeight}]]
    }
    # /CS is REQUIRED here, unlike in a plain transparency group: a
    # luminosity mask needs a colour space to have a luminosity at all
    # (ISO 32000-1, 11.6.5.2). DeviceGray is the one that says what the
    # group means and costs no output intent of its own.
    set pairs [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [lmap value $bounds {::tclpdf::pdfObj num $value}]] \
        Group [::tclpdf::pdfObj dictionary {S /Transparency CS /DeviceGray I true}] \
        Resources [[my writer] ref [my reservation output.resources]]]
    set sequence [my state svgMaskSeq]
    if {$sequence eq {}} {
      set sequence 0
    }
    my state svgMaskSeq [incr sequence]
    set form [[my writer] ref [my streamObject $pairs $content]]
    # /BC black: outside the BBox the mask has no value, and SVG says an
    # area the mask does not cover is fully transparent (14.4).
    set state [::tclpdf::pdfObj dictionary [list Type /ExtGState \
        SMask [::tclpdf::pdfObj dictionary [list S /Luminosity G $form \
            BC [::tclpdf::pdfObj arr {0}]]]]]
    set name svgMask$sequence
    my resource ExtGState $name [[my writer] ref [[my writer] add $state]]
    if {$cached eq {}} {
      set cached [dict create]
    }
    dict set cached $id $name
    my state svgMaskNames $cached
    return $name
  }
}

package provide tclpdf::svgClip 1.0
