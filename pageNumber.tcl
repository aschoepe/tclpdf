#
# tclpdf - PDF generation for Tcl
#
# pageNumber - "Page 3 of 7" on every page
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc pageNumbers -at {105 285} -align center -size 8
#
# The problem this solves is one of order: while page three is being drawn,
# nobody knows yet that there will be seven. Writing the number at that moment
# is impossible; writing it afterwards means drawing onto a page that is
# already finished.
#
# So the numbers are not drawn when the call is made. The call only records
# what should appear where, and subscribes to beforeWrite - at which point
# every page exists and the total is simply [page count].
#
# Each page gets its number as a form XObject of its own, kept at an object
# number from [reservation] and written afresh on every [write]. That is what
# makes a second write come out identical instead of stacking a second number
# on top of the first: the object is overwritten, not added. Only the one
# operator that invokes it goes into the page's content stream, and only once.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-
package require tclpdf::text 1.0-

namespace eval ::tclpdf::pageNumber {}

oo::define ::tclpdf::document::document {

  # $doc pageNumbers -at {x y} ?-format "Page %n of %m"? ?-align center?
  #                  ?-from 2? ?-total 7? ?font options?
  #
  # %n is the page number, %m the total. -from skips the leading pages, which
  # is how a title page stays unnumbered; the count itself still includes them
  # unless -total says otherwise, because "Page 2 of 7" on the second sheet of
  # seven is what a reader expects.
  method pageNumbers {args} {
    my TextInit
    set defaults {at {} format "Page %n of %m" align left from 1 total {}}
    foreach name $::tclpdf::text::stateOptions {
      dict set defaults $name [my TextGet $name]
    }
    # The line options on top, as [text] takes them: a page number is one
    # line, and "صفحة 3 من 10" is one that runs right to left. The digits of
    # %n and %m come out of it as a number rather than reversed, which is the
    # whole reason the option has to reach this far.
    set defaults [dict merge $defaults $::tclpdf::text::runOptions]
    set options [::tclpdf::option parse $defaults $args "pageNumbers"]
    if {[dict get $options at] eq {}} {
      return -code error -errorcode [list TCLPDF PAGENUMBER ARGUMENT at] \
          "tclpdf: pageNumbers needs -at {x y}"
    }
    if {[llength [dict get $options at]] != 2} {
      return -code error -errorcode [list TCLPDF PAGENUMBER ARGUMENT at] \
          "tclpdf: -at takes two numbers {x y}, got\
          \"[dict get $options at]\""
    }
    if {![string is integer -strict [dict get $options from]]
        || [dict get $options from] < 1} {
      return -code error -errorcode [list TCLPDF PAGENUMBER ARGUMENT from] \
          "tclpdf: -from is a page number counted from 1, got\
          \"[dict get $options from]\""
    }
    # Both checked at the CALL. The number is drawn at write time, and a
    # value refused only there names [write] rather than the call that
    # wrote it - and -total was not refused at all: "abc" went straight
    # into the label as %m.
    set total [dict get $options total]
    if {$total ne {} && (![string is integer -strict $total] || $total < 1)} {
      return -code error -errorcode [list TCLPDF PAGENUMBER ARGUMENT total] \
          "tclpdf: -total is a page count of 1 or more, got\
          \"$total\""
    }
    if {[dict get $options align] ni {left right center centre}} {
      return -code error -errorcode [list TCLPDF PAGENUMBER ARGUMENT align] \
          "tclpdf: -align must be left, right or center,\
          not \"[dict get $options align]\""
    }

    set state [my state pageNumbers]
    if {$state eq {}} {
      set state [dict create runs {} placed {}]
      my onSelf beforeWrite PageNumberWrite
    }
    # Several runs are allowed on purpose - a number at the foot and a chapter
    # line at the head are two calls, not one call with more options.
    dict lappend state runs $options
    my state pageNumbers $state
    return
  }

  # -- writing ------------------------------------------------------------

  method PageNumberWrite {} {
    set state [my state pageNumbers]
    set placed [dict get $state placed]
    set pages [my page count]
    set index 0
    foreach run [dict get $state runs] {
      set total [expr {[dict get $run total] eq {} ? $pages : [dict get $run total]}]
      for {set page 0} {$page < $pages} {incr page} {
        set number [expr {$page + 1}]
        if {$number < [dict get $run from]} {
          continue
        }
        my PageNumberOne $run $page $number $total $index
      }
      incr index
    }
    return
  }

  # One page, one run. The content is rebuilt every time; the object number and
  # the resource name are not.
  method PageNumberOne {run page number total index} {
    set key tclpdf::pageNumber.$index.$page
    set label [string map [list %n $number %m $total] [dict get $run format]]

    # Drawn onto a canvas the size of THIS page, so that [text] converts the
    # coordinates against the right height - a document may mix formats, and
    # the foot of an A5 sheet is not where the foot of an A4 sheet is.
    lassign [my page size $page] width height
    lassign [my extent [list $width $height]] widthPoints heightPoints
    # The number is drawn into a form XObject, which is a content stream of
    # its own - and an MCID is unique per STREAM, not per page. Marking inside
    # it would put a number into the tree that the page's own stream does not
    # have, and the XObject would need a StructParents entry of its own
    # (14.7.5.2). Suspending the marking here and bracketing the [Do] below
    # avoids both: a page number is a pagination artifact, so nothing about it
    # belongs in the tree anyway.
    set suspended [my state structureSuspend]
    my state structureSuspend 1
    my canvas push $widthPoints $heightPoints
    set failed [catch {
      set arguments {}
      foreach name $::tclpdf::text::lineOptions {
        lappend arguments -$name [dict get $run $name]
      }
      my text $label -at [dict get $run at] -align [dict get $run align] \
          {*}$arguments
    } result info]
    set content [my canvas pop]
    my state structureSuspend $suspended
    if {$failed} {
      return -options $info $result
    }

    set objectNumber [my reservation $key]
    # Its own Resources, for the reason spelled out in xObject.tcl: the form
    # names a font, and PDF/A 6.2.2 does not let a stream inherit what it
    # references.
    my streamObject [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [list 0 0 \
            [::tclpdf::pdfObj num $widthPoints] \
            [::tclpdf::pdfObj num $heightPoints]]] \
        Resources [[my writer] ref [my reservation output.resources]]] \
        $content $objectNumber
    # Stable across writes, and readable in the file: run index and page.
    set resourceName XOPN${index}_${page}
    my resource XObject $resourceName [[my writer] ref $objectNumber]

    # The invoking operator goes in ONCE. Appending it again on the second
    # write would draw the same form twice - harmless to look at, and a
    # document that grows with every write.
    set state [my state pageNumbers]
    if {$key ni [dict get $state placed]} {
      # Bracketed as an artifact, because the Do itself is content on the page
      # and unmarked content is a defect under PDF/UA.
      set open ""
      set close ""
      if {[my state tagged] eq "1"} {
        # Pagination, not the default Layout: a page number is exactly what
        # that artifact type is for (14.8.2.2), and a reader can then leave
        # it out of the running text on purpose rather than by accident.
        #
        # And the subtype, which UA-1 7.8 asks for, comes from where the
        # number sits: above the middle of the page it is a running head,
        # below it a running foot. This is the one place that KNOWS - a
        # caller writing their own header has to say so with
        # "-tag {Artifact Pagination Header}".
        lassign [dict get $run at] . top
        lassign [my page size $page] . pageHeight
        set subtype [expr {$top * 2 < $pageHeight ? "Header" : "Footer"}]
        set mark [my StructureMark Artifact [list Pagination $subtype]]
        set open [my StructureBegin $mark]
        set close [my StructureEnd $mark]
      }
      my content "${open}q /$resourceName Do Q\n$close" $page
      dict lappend state placed $key
      my state pageNumbers $state
    }
    return
  }
}

package provide tclpdf::pageNumber 1.5
