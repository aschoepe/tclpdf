#
# tclpdf - PDF generation for Tcl
#
# viewerPreferences - how a reader should present the document (12.2)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc viewerPreferences -displayDocTitle 1
#   $doc viewerPreferences -duplex DuplexFlipLongEdge -numCopies 2
#
# A viewer preference is a wish, not a promise: the reader may follow it or
# ignore it, and nothing in the file depends on the answer. Which is why the
# whole dictionary was missing until PDF/UA made one of its keys mandatory -
# DisplayDocTitle true, so that the window shows the document's title instead
# of its file name (UA-1 7.1). A file called "rg-2026-114-v3-final.pdf" says
# nothing to someone listening to it.
#
# Calls accumulate: each one sets the keys it names and leaves the rest alone,
# so a document can state its printing wishes in one place and its window
# wishes in another.
#
# Four keys of Table 150 are deliberately absent: ViewArea, ViewClip, PrintArea
# and PrintClip. They are deprecated in PDF 2.0, and no reader this was tested
# against acts on them - offering them would only invite a document to depend
# on something that does not happen.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::viewerPreferences {
  # The PDF key for each option, in the order Table 150 lists them. The
  # dictionary is written in that order too: a diff between two documents then
  # shows what differs rather than how the keys happened to be set.
  variable keys {
    hideToolbar           HideToolbar
    hideMenubar           HideMenubar
    hideWindowUI          HideWindowUI
    fitWindow             FitWindow
    centerWindow          CenterWindow
    displayDocTitle       DisplayDocTitle
    nonFullScreenPageMode NonFullScreenPageMode
    direction             Direction
    printScaling          PrintScaling
    duplex                Duplex
    pickTrayByPDFSize     PickTrayByPDFSize
    numCopies             NumCopies
  }

  # From which PDF version each key exists (Reference 1.7, Table 8.1). The
  # dictionary itself and the five window keys are 1.2; anything not listed
  # here needs no more than that.
  variable since {
    direction             1.3
    displayDocTitle       1.4
    printScaling          1.6
    duplex                1.7
    pickTrayByPDFSize     1.7
    numCopies             1.7
  }

  # Which options take a boolean rather than a name. Kept apart from the
  # value lists below because a boolean has no fixed spelling to check
  # against - "yes" and 1 are both true and both have to reach the file as
  # the PDF keyword "true".
  variable booleans {
    hideToolbar hideMenubar hideWindowUI fitWindow centerWindow
    displayDocTitle pickTrayByPDFSize
  }

  # The names each remaining option accepts. Checked at the call: a
  # misspelled "DuplexFlipLong" is not an error a validator reports - the
  # reader silently falls back to its default, and the document prints on one
  # side for the rest of its life.
  variable values {
    nonFullScreenPageMode {UseNone UseOutlines UseThumbs UseOC}
    direction             {L2R R2L}
    printScaling          {None AppDefault}
    duplex                {Simplex DuplexFlipShortEdge DuplexFlipLongEdge}
  }
}

oo::define ::tclpdf::document::document {

  # $doc viewerPreferences ?-key value ...?  -> the settings after the call
  #
  # Without arguments it answers what has been set so far, which is what the
  # UA check reads to find out whether DisplayDocTitle is there.
  method viewerPreferences {args} {
    variable ::tclpdf::viewerPreferences::keys
    variable ::tclpdf::viewerPreferences::booleans
    variable ::tclpdf::viewerPreferences::values
    variable ::tclpdf::viewerPreferences::since
    set current [my state viewerPreferences]
    if {![llength $args]} {
      return $current
    }
    # Only the keys this call names are parsed, so the rest keep their value.
    # [option parse] fills in every key it knows about, which would turn each
    # call into a reset of everything else.
    set wanted [::tclpdf::option parse [dict create {*}[join [lmap {option .} \
        $keys {list $option {}}]]] $args "viewerPreferences"]
    dict for {option value} $wanted {
      if {$value eq {}} {
        continue
      }
      if {$option in $booleans} {
        if {![string is boolean -strict $value]} {
          return -code error "tclpdf: viewerPreferences -$option takes a\
              boolean, not \"$value\""
        }
        set value [expr {$value ? 1 : 0}]
      } elseif {[dict exists $values $option]} {
        set allowed [dict get $values $option]
        if {$value ni $allowed} {
          return -code error "tclpdf: viewerPreferences -$option must be one\
              of [join $allowed {, }] - not \"$value\""
        }
      } elseif {$option eq "numCopies"} {
        if {![string is integer -strict $value] || $value < 1} {
          return -code error "tclpdf: viewerPreferences -numCopies takes a\
              positive integer, not \"$value\""
        }
      }
      my RequireVersion [expr {[dict exists $since $option] ?
          [dict get $since $option] : 1.2}] "viewerPreferences -$option"
      dict set current $option $value
    }
    if {[my state viewerPreferences] eq {}} {
      my onSelf catalog ViewerPreferencesCatalog
    }
    my state viewerPreferences $current
    return $current
  }

  # Written at catalog time, like every other catalogue key. An empty
  # dictionary is not written at all: /ViewerPreferences << >> is legal and
  # says nothing, and a reader that meets it has to parse it to find that out.
  method ViewerPreferencesCatalog {} {
    variable ::tclpdf::viewerPreferences::keys
    variable ::tclpdf::viewerPreferences::booleans
    set current [my state viewerPreferences]
    set pairs {}
    dict for {option name} $keys {
      if {![dict exists $current $option]} {
        continue
      }
      set value [dict get $current $option]
      if {$option in $booleans} {
        lappend pairs $name [expr {$value ? "true" : "false"}]
      } elseif {$option eq "numCopies"} {
        lappend pairs $name [::tclpdf::pdfObj num $value]
      } else {
        lappend pairs $name /$value
      }
    }
    if {![llength $pairs]} {
      return
    }
    my catalogEntry ViewerPreferences [::tclpdf::pdfObj dictionary $pairs]
    return
  }
}

package provide tclpdf::viewerPreferences 1.0
