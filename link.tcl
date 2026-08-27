#
# tclpdf - PDF generation for Tcl
#
# link - clickable areas, as link annotations (12.5.6.5)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc link -at {20 100} -size {60 6} -url https://example.org/
#   $doc link -at {20 110} -size {60 6} -page 3
#
# A link is not drawn - it is a rectangle laid over whatever is already there.
# Drawing the text and marking it up are two calls on purpose: the text may be
# a table cell, a heading or nothing at all.
#
# Two details matter for PDF/A and neither is obvious. The annotation must
# have its Print flag set (/F 4): an archived document has to look the same
# printed as on screen, and a validator rejects one that could differ. And it
# gets a zero-width border, because the default is a visible frame that no
# caller asked for.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::link {}

oo::define ::tclpdf::document::document {

  method link {args} {
    set options [::tclpdf::option parse {
      at {} size {} url {} page {} to {} zoom {} tooltip {} structure {}
    } $args "link"]
    if {[dict get $options at] eq {} || [dict get $options size] eq {}} {
      return -code error -errorcode [list TCLPDF LINK ARGUMENT rect] \
          "tclpdf: link needs -at {x y} and -size {w h}"
    }
    if {[dict get $options url] eq {} && [dict get $options page] eq {}
        && [dict get $options structure] eq {}} {
      return -code error -errorcode [list TCLPDF LINK ARGUMENT target] \
          "tclpdf: link needs -url, -page or -structure"
    }
    # ONE TARGET, and the manual says so: "to a URL, to a page, OR to a named
    # structure element" (:886). The code below decides -url over -structure
    # over -page and drops the loser without a word, so [link -url ... -page
    # 2] wrote a URL link and the caller believed in a page jump. Refused
    # instead, and named: two targets in one call is a mistake at the call,
    # the way [pattern -matrix] with [-origin] is.
    #
    # -to and -zoom belong to a PAGE destination (12.3.2.2), so they are the
    # loser's options wherever the target is not a page.
    foreach {winner losers} {url {page to zoom} structure {to zoom}} {
      if {[dict get $options $winner] eq {}} {
        continue
      }
      foreach loser $losers {
        if {[dict get $options $loser] eq {}} {
          continue
        }
        return -code error -errorcode [list TCLPDF LINK ARGUMENT $winner] \
            "tclpdf: link -$winner and -$loser name two\
            different targets - a link goes to a URL, to a page or to a\
            named structure element, never to two (ISO 32000-1 12.5.6.5).\
            Drop -$loser, or drop -$winner"
      }
    }
    # -zoom without -to is the same silence one level down: a destination
    # with no position is /Fit, the whole page (see [DestinationArray]), and
    # a magnification has no place in it. [initialView] refuses the pair the
    # other way round - -to and -zoom without a page - for the same reason.
    if {[dict get $options zoom] ne {} && [dict get $options to] eq {}} {
      return -code error -errorcode [list TCLPDF LINK ARGUMENT zoom] \
          "tclpdf: link -zoom says how close a reader comes to\
          a place on the page, and no place was given - add -to {x y}, or\
          drop -zoom; without -to the destination shows the whole page"
    }
    # Every number before anything is written. -at and -to are points and
    # answer as points do everywhere (TCLPDF OPTION POINT); -size is two
    # numbers as well, and the arithmetic below used to reach [expr] first -
    # "link -at {a b}" came back as ARITH DOMAIN, in Tcl's words.
    ::tclpdf::option point [dict get $options at] -at "link"
    ::tclpdf::option point [dict get $options size] -size "link"
    if {[dict get $options to] ne {}} {
      ::tclpdf::option point [dict get $options to] -to "link"
    }
    if {[dict get $options zoom] ne {}} {
      # 12.3.2.2 Table 151: in an /XYZ destination a zoom of 0 "has the same
      # meaning as a null value" - the magnification the reader is already
      # at - so 0 is a number to act on. Below it there is none to mean, and
      # [initialView] has refused it since it was written (:1188); [link]
      # wrote /XYZ x y -1 instead.
      set zoom [dict get $options zoom]
      if {![::tclpdf::option finite $zoom] || $zoom < 0} {
        return -code error -errorcode [list TCLPDF LINK ARGUMENT zoom] \
            "tclpdf: link -zoom is a magnification of 0 or\
            more, 1 being actual size and 0 the magnification the reader is\
            already at - not \"$zoom\""
      }
    }
    lassign [dict get $options size] width height
    # A RECTANGLE NOBODY CAN CLICK. A link is its /Rect and nothing else -
    # there is no drawing under it that could still be hit - so a width or a
    # height of zero makes an annotation no pointer ever reaches, and under
    # PDF/UA one a screen reader announces and cannot follow. A negative
    # size writes the corners the other way round: allowed by 7.9.5, which
    # says a reader normalises them, and a mistake at the call all the same.
    # [image place] and [form place] refuse both; so does this now.
    foreach {edge value} [list width $width height $height] {
      if {$value <= 0} {
        return -code error -errorcode [list TCLPDF LINK ARGUMENT size] \
            "tclpdf: link -size {$width $height} - the $edge is\
            $value, and a link is nothing but its rectangle: with no area\
            there is nothing to click. Give it the extent of the text it\
            covers"
      }
    }
    # NOT INSIDE A FORM, A TILE OR THE PAGE-NUMBER XOBJECT. An annotation
    # belongs to a PAGE and its /Rect is in the page's default user space
    # (ISO 32000-2 12.5.2) - a content stream of its own has neither. Drawn
    # inside [form create] the rectangle was computed against the form's
    # height and then hung on the page: measured 2026-08-27, a link at {5 5}
    # in a 50x20 mm form placed at {100 100} came out in the bottom left
    # corner of the page, where nothing is drawn, and a second [form place]
    # did not give it a second rectangle either.
    #
    # Refused early and with nothing written yet, in the words [annot] uses
    # for the same mistake (TCLPDF ANNOT PLACE form): the caller means a
    # clickable area over the form, and the way to that is to place the form
    # first and lay the link over where it landed.
    #
    # Measured on the STREAM IDENTITY, not on the marking switch: [canvas id]
    # answers {stream <serial>} for a form XObject, a tiling pattern and the
    # page-number XObject and {page <index>} for a page (page.tcl), while
    # structureSuspend is also set by a table drawing a pagination artifact -
    # where a link is perfectly legitimate.
    if {[lindex [my canvas id] 0] eq "stream"} {
      return -code error -errorcode [list TCLPDF LINK PLACE form] \
          "tclpdf: a link cannot be placed inside a form; place\
          it on the page after form place - an annotation belongs to a page\
          and its rectangle is in the page's coordinates (ISO 32000-2\
          12.5.2), which a form, a pattern or a page-number XObject does not\
          have"
    }
    # WHERE THIS LINK GOES, as one comparable value. Two link annotations
    # may share a Link structure element only while they go to the SAME
    # place (ISO 14289-2 8.2.5.20, Examples 2 and 3), so the target has to be
    # something two links can be held against each other by - which the
    # serialised action dictionary is not, and the raw -url is not either
    # (the same address written twice with a different escape is one target).
    # The URI is normalised the way it is written, by [LinkUri].
    if {[dict get $options url] ne {}} {
      set target [list url [my LinkUri [dict get $options url]]]
    } elseif {[dict get $options structure] ne {}} {
      set target [list structure [dict get $options structure]]
    } else {
      set target [list page [dict get $options page] \
          [dict get $options to] [dict get $options zoom]]
    }
    my LinkTargetGuard $target
    # Annotation flags (/F) and actions (/A, the URI link) are PDF 1.1
    # (Reference 1.7, Table 8.15 and 8.5); a 1.0 file has neither.
    my RequireVersion 1.1 "link"
    lassign [dict get $options at] left top
    lassign [my coords $left [expr {$top + $height}]] x0 y0
    lassign [my coords [expr {$left + $width}] $top] x1 y1

    set pairs [list Type /Annot Subtype /Link \
        Rect [::tclpdf::pdfObj arr [list \
            [::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] \
            [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1]]] \
        Border [::tclpdf::pdfObj arr {0 0 0}] \
        F 4]
    if {[dict get $options tooltip] ne {}} {
      lappend pairs Contents [my Str [dict get $options tooltip]]
    }
    if {[dict get $options url] ne {}} {
      lappend pairs A [::tclpdf::pdfObj dictionary [list \
          S /URI URI [my Str [my LinkUri [dict get $options url]]]]]
    } elseif {[dict get $options structure] ne {}} {
      # A structure destination names the ELEMENT rather than a place on a
      # page (12.3.2.3), so the link still lands on the right thing after the
      # content has moved. PDF/UA-2 asks for internal targets to be written
      # this way. It needs a tagged document and a 2.0 file, and the guard
      # says so rather than writing a destination that points at nothing.
      #
      # Written as an action (/A), not as /Dest: a GoTo carries the structure
      # destination in /SD AND a page destination in /D (32000-2 Table 202),
      # so a reader that does not know /SD still lands on the right page.
      # The method builds the pair; what it holds is described there.
      my StructureDestinationGuard "link -structure"
      lappend pairs A [my structureDestination [dict get $options structure]]
    } else {
      # The page may not exist yet - a link forward at a page added later
      # is allowed, and [Destination] says at write time if it never came.
      lappend pairs Dest [my Destination [dict get $options page] \
          [dict get $options to] [dict get $options zoom] \
          "link -page [dict get $options page] on page [my page current]"]
    }
    # Reserved before the dictionary is written, because the StructParent that
    # goes INTO it can only be asked for once the object has a number.
    set number [[my writer] add [::tclpdf::pdfObj dictionary $pairs]]
    if {[my state tagged] eq "1"} {
      set key [my StructureAnnotation $number]
      if {$key ne {}} {
        lappend pairs StructParent $key
        [my writer] put $number [::tclpdf::pdfObj dictionary $pairs]
      }
    }
    my AnnotationOnPage [my page current] [[my writer] ref $number]
    # Remembered as a record - see [LinkRecord], which says why the two UA
    # questions may not be put to the serialised dictionary.
    my LinkRecord [my page current] $number \
        [expr {[dict get $options tooltip] ne {}}] $target
    return $number
  }

  # ONE TARGET PER Link ELEMENT, refused before the second annotation is
  # written - but only where the claim that asks for it already stands.
  #
  # ISO 14289-2 8.2.5.20: "Link annotations that target different locations
  # shall be in separate Link or Reference structure elements". The same
  # clause allows several annotations that go to the same place, which is
  # the ordinary case - an icon and the word beside it, two lines of a
  # wrapped link - so it is the TARGETS that are counted, not the
  # annotations. A reader announces one link and would otherwise have two
  # places to follow it to.
  #
  # Said at the call when [ua -part 2] has already been claimed, and at the
  # write otherwise ([UaCheckLinks]): a claim made after the drawing cannot
  # be refused at a call that has already happened, and the write is where
  # this package makes good on every promise it took on late.
  method LinkTargetGuard {target} {
    if {[my state tagged] ne "1" || [my state ua] eq {}
        || [dict get [my state ua] part] != 2} {
      return
    }
    set element [my StructureCurrent]
    if {$element eq {}} {
      return
    }
    set type [dict get [lindex [my state structure] $element] type]
    if {$type ni {Link Reference}} {
      return
    }
    foreach other [my LinkTargetsIn $element] {
      if {$other eq $target} {
        continue
      }
      return -code error -errorcode [list TCLPDF LINK PLACE target] \
          "tclpdf: this $type structure element already holds a\
          link to another target - PDF/UA-2 wants link annotations that go to\
          different places in separate Link or Reference elements (8.2.5.20),\
          because a reader announces the element once. Close the $type and\
          open a second one around the second link"
    }
    return
  }

  # The distinct targets of the link annotations that joined one structure
  # element. The one place that answers it: [LinkTargetGuard] asks it of the
  # element that is open, [linksSharingElement] of every element in the tree.
  method LinkTargetsIn {element} {
    set targets {}
    dict for {page links} [my state links] {
      foreach link $links {
        set owner [my StructureAnnotationElement [dict get $link number]]
        if {[lindex $owner 0] ne $element} {
          continue
        }
        if {[dict get $link target] ni $targets} {
          lappend targets [dict get $link target]
        }
      }
    }
    return $targets
  }

  # Which Link or Reference structure elements hold link annotations with
  # more than one target, as {page type count} - the fact behind ISO 14289-2
  # 8.2.5.20, established here and judged by ua.tcl, exactly as
  # [linksWithoutContents] and [linksWithoutElement] are. The page is the one
  # the FIRST of the links sits on, which is where the caller has to look.
  method linksSharingElement {types} {
    if {[my state tagged] ne "1"} {
      return {}
    }
    set seen {}
    set problems {}
    dict for {page links} [my state links] {
      foreach link $links {
        set owner [my StructureAnnotationElement [dict get $link number]]
        lassign $owner element type
        if {$element eq {} || $type ni $types || [dict exists $seen $element]} {
          continue
        }
        dict set seen $element 1
        set targets [my LinkTargetsIn $element]
        if {[llength $targets] > 1} {
          lappend problems [list [expr {$page + 1}] $type [llength $targets]]
        }
      }
    }
    return $problems
  }

  # Which link annotations carry no Contents, by page. Empty when every one
  # of them has a description.
  #
  # PDF/UA makes Contents mandatory (7.18.5): a link is announced by that
  # text, and without it a reader says "link" and stops. The fact is
  # established here, where the annotations are, and judged by ua.tcl - the
  # same division as fonts.
  #
  # A tooltip is what fills it, so the fix is one option on the call that
  # created the link rather than anything structural.
  method linksWithoutContents {} {
    set missing {}
    dict for {page links} [my state links] {
      foreach link $links {
        if {![dict get $link described]} {
          lappend missing [expr {$page + 1}]
        }
      }
    }
    return $missing
  }

  # Which link annotations are not inside a structure element of one of the
  # given types, by page - a Link, unless the caller says otherwise. Empty
  # when every one of them is.
  #
  # PDF/UA wants a link annotation nested in a Link element (UA-1 7.18.5,
  # Matterhorn 28-011 - veraPDF fails one that is not; UA-2 8.2.5.20 lets a
  # Reference do as well, which is why the types are the caller's): the
  # element is where a reader finds the text that goes with the rectangle.
  # A link drawn outside any element joins no element at all, one drawn
  # inside an open P joins the P; neither is a Link. The fact is established
  # here and judged by ua.tcl, as [linksWithoutContents] is; the element an
  # annotation joined is structure.tcl's to answer.
  method linksWithoutElement {{types Link}} {
    set missing {}
    dict for {page links} [my state links] {
      foreach link $links {
        # In an untagged document there is no element to have joined, and
        # the structure module is not asked - it may not even be loaded.
        if {[my state tagged] eq "1"
            && [my StructureAnnotationOwner [dict get $link number]] in $types} {
          continue
        }
        lappend missing [expr {$page + 1}]
      }
    }
    return $missing
  }

  # One link, remembered as a RECORD rather than looked up again later in the
  # serialised annotation dictionary. Called once per [link], at the call,
  # which is the only moment at which both facts are known for certain: that
  # this annotation is a link, and whether a -tooltip filled its /Contents.
  #
  # Both questions used to be put to [[my writer] body $number] with a regular
  # expression, and both answers were wrong in both directions - the body is
  # text, and every string in it is text too:
  #
  #   /Contents      matched inside the URI of the link itself, so
  #                  [link -url https://example.org/Contents] counted as
  #                  described. veraPDF then failed the finished file under
  #                  7.18.1 and 7.18.5 - the claim had already been made.
  #   /Subtype /Link matched inside the /Contents of a NOTE quoting those
  #                  words, so [annot note -contents "... /Subtype /Link ..."]
  #                  counted as a link annotation. The write died with "1 link
  #                  annotation is not inside a Link structure element" for a
  #                  link the document does not have.
  #
  # [state annots] cannot answer either question: output.tcl keeps indirect
  # references there ("12 0 R"), one list per page, and a reference says
  # nothing about what it points at. So the module that makes the links keeps
  # the list of the links - page -> list of {number N described 0|1} - which
  # is also all ua.tcl needs to know that a document has any at all.
  # TARGET is the third fact, and it is kept for the same reason as the other
  # two: where a link goes is known here and nowhere else afterwards. A page
  # destination that points forward is an indirect reference by the time the
  # dictionary is written, and a structure destination is an action naming
  # two reserved objects - neither says which page or which element the
  # caller asked for. See [LinkTargetGuard] for what the value looks like.
  method LinkRecord {page number described target} {
    set links [my state links]
    dict lappend links $page [dict create number $number \
        described $described target $target]
    my state links $links
    return
  }

  # The URI as the file may carry it: 7-bit ASCII (ISO 32000-1 Table 206),
  # everything else percent-encoded from its UTF-8 bytes (RFC 3986 2.1).
  #
  # Handed to [str] as it came, a URL with an umlaut in it became a UTF-16BE
  # hex string - readable to a Tcl programmer and to no browser: what a reader
  # passes on is the bytes of the string, and the reader was never told which
  # encoding they were in. Measured with https://ü.de/ä, which arrived as
  # <feff0068...00fc...>.
  #
  # What stays as it is: the unreserved and the reserved characters of RFC
  # 3986 2.2 and 2.3, and the percent sign - so an already encoded %C3%BC is
  # not encoded a second time. Everything else, a space included, becomes
  # %XX per byte, which is what a browser does to the same address.
  method LinkUri {url} {
    set kept {ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789}
    append kept {-._~} {:/?#[]@} {!$&'()*+,;=} %
    set result {}
    foreach byte [split [encoding convertto utf-8 $url] {}] {
      if {[string first $byte $kept] >= 0} {
        append result $byte
      } else {
        binary scan $byte cu code
        append result [format %%%02X $code]
      }
    }
    return $result
  }

  # Annotations are collected per page and picked up when the page is
  # written. Kept in the scratch state rather than pushed into output.tcl, so
  # that a document without links costs nothing.
}

package provide tclpdf::link 1.9