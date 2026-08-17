#
# tclpdf - PDF generation for Tcl
#
# pageLabel - what a reader calls each page (12.4.2)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc pageLabels -from 0 -style r
#   $doc pageLabels -from 4 -style D -start 1
#   $doc pageLabels -from 12 -style none -prefix "Appendix "
#
# A page has two numbers: the index the file counts it by, and the number
# printed on it. A reader shows the first unless the file says otherwise, and
# then "go to page 3" lands on the third sheet while the sheet reading "3"
# is the sixth - because there was a cover and a table of contents. Page
# labels are how the file says otherwise: a range starts at a page index and
# names a numbering style, a prefix and a first number, and it runs until the
# next range begins.
#
# For an accessible document this is not a nicety. Matterhorn 15-001 counts
# a visible page number that differs from the page label as a failure - and
# it is one no validator can find, because the visible number is drawn text.
# [pageNumbers] draws the numbers; this module tells the reader what they
# are, and the two have to be set to agree.
#
# The tree has to start at index 0 (7.9.7, 12.4.2). A document that labels
# only its body from page 4 on has said nothing about the pages before it,
# and a number tree with a gap at the front is invalid rather than silent -
# so a range without a style is put in front, which is the standard's own way
# of saying "no number here" (12.4.2: no /S, no numeric portion).
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::pageLabel {
  # The numbering styles of Table 159, plus "none": a range that carries a
  # prefix and nothing else - a cover called "Cover", an insert called
  # "Insert" - is written without /S, which is what the standard provides
  # for it. Checked at the call, because a misspelt style is not an error a
  # validator reports: the reader ignores the key and numbers the range as
  # it pleases.
  variable styles {D R r A a none}
}

oo::define ::tclpdf::document::document {

  # $doc pageLabels ?-from index? ?-style D? ?-prefix text? ?-start 1?
  #   -> the ranges after the call
  #
  # One call is one range, starting at the page INDEX -from - counted from
  # 0, like [page] counts. A second call for the same index replaces the
  # first. Without arguments it answers the ranges set so far, as a
  # dictionary from index to {style prefix start}, in page order.
  method pageLabels {args} {
    variable ::tclpdf::pageLabel::styles
    set ranges [my state pageLabels]
    if {![llength $args]} {
      return $ranges
    }
    set options [::tclpdf::option parse {
      from {} style D prefix {} start 1
    } $args "pageLabels"]
    set from [dict get $options from]
    if {![string is integer -strict $from] || $from < 0} {
      return -code error "tclpdf: pageLabels needs -from, a page index counted\
          from 0 - got \"$from\""
    }
    set style [dict get $options style]
    if {$style ni $styles} {
      return -code error "tclpdf: pageLabels -style must be one of\
          [join $styles {, }] - not \"$style\""
    }
    set start [dict get $options start]
    if {![string is integer -strict $start] || $start < 1} {
      return -code error "tclpdf: pageLabels -start takes a positive integer,\
          not \"$start\""
    }
    # Page labels are PDF 1.3 (Reference 1.7, 8.3.1).
    my RequireVersion 1.3 "pageLabels"
    if {$ranges eq {}} {
      my onSelf catalog PageLabelCatalog
    }
    dict set ranges $from [dict create style $style \
        prefix [dict get $options prefix] start $start]
    # Kept in page order, so the answer reads as the document does and the
    # tree below is written in the order 7.9.7 requires without a second sort.
    set ranges [lsort -integer -stride 2 -index 0 $ranges]
    my state pageLabels $ranges
    return $ranges
  }

  # Written at catalog time as one number tree at a reserved object number,
  # so a second write puts over it rather than beside it.
  method PageLabelCatalog {} {
    set ranges [my state pageLabels]
    if {$ranges eq {}} {
      return
    }
    set pages [my page count]
    # A number tree has to begin at 0. Without a range there the pages before
    # the first one have no label at all, and a reader meeting a tree that
    # starts at 4 may refuse the whole thing - so a range without a style
    # goes in front, which shows no number and claims nothing.
    if {![dict exists $ranges 0]} {
      set ranges [dict merge [dict create 0 {style none prefix {} start 1}] \
          $ranges]
    }
    # In the order [pageLabels] keeps them, which is the ascending order
    # 7.9.7 requires - a reader is free to stop at a key out of sequence.
    set nums {}
    dict for {index range} $ranges {
      if {$index >= $pages} {
        return -code error "tclpdf: pageLabels -from $index names a page the\
            document does not have - it has $pages page(s)"
      }
      set pairs {}
      if {[dict get $range style] ne "none"} {
        lappend pairs S /[dict get $range style]
      }
      if {[dict get $range prefix] ne {}} {
        lappend pairs P [::tclpdf::pdfObj str [dict get $range prefix]]
      }
      # 1 is the default of Table 159 and is left out, like every other
      # default this package does not spell.
      if {[dict get $range start] != 1} {
        lappend pairs St [::tclpdf::pdfObj num [dict get $range start]]
      }
      lappend nums $index [::tclpdf::pdfObj dictionary $pairs]
    }
    set number [my reservation pageLabel.tree]
    [my writer] put $number [::tclpdf::pdfObj dictionary \
        [list Nums [::tclpdf::pdfObj arr $nums]]]
    my catalogEntry PageLabels [[my writer] ref $number]
    return
  }
}

package provide tclpdf::pageLabel 1.0
