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
#   $doc initialView -pageMode UseOutlines -pageLayout TwoColumnLeft
#   $doc initialView -page 1 -to {20 40} -zoom 1
#
# [initialView] is the second half of the same question and a COMMAND OF ITS
# OWN, not three more options here. /PageMode, /PageLayout and /OpenAction
# are entries of the document CATALOGUE (12.3.2, Table 28), not of the
# viewer preferences dictionary, and the difference is not bookkeeping:
#
#   - What [viewerPreferences] answers IS the dictionary that goes into
#     /ViewerPreferences, and the PDF/UA check reads that answer to find
#     DisplayDocTitle in it (ua.tcl). Three catalogue keys mixed into it
#     would make the return value mean two things at once.
#   - This dictionary already has a NonFullScreenPageMode, and its value
#     list overlaps /PageMode's in four of six words. A -pageMode beside
#     -nonFullScreenPageMode in one call, taking UseNone, UseOutlines,
#     UseThumbs and UseOC either way and meaning something different, is
#     the kind of pair a caller can only tell apart by trying both.
#   - A viewer preference is a wish a reader may ignore; /PageMode and
#     /OpenAction are what a reader does when the file opens.
#
# They live in THIS FILE because the topic is the same one - how a reader
# should present the document - and a second module for two catalogue keys
# would be a file for one idea split in half.
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

  # -- the initial view (Table 28) ------------------------------------------

  # What /PageMode and /PageLayout accept, in the order Table 28 lists them,
  # and from which PDF version each value exists. A misspelt name is not an
  # error a validator reports either: the reader falls back on its default -
  # UseNone, SinglePage - and the document opens the ordinary way for the
  # rest of its life.
  variable initialValues {
    pageMode   {UseNone UseOutlines UseThumbs FullScreen UseOC UseAttachments}
    pageLayout {SinglePage OneColumn TwoColumnLeft TwoColumnRight
                TwoPageLeft TwoPageRight}
  }

  # The four values younger than the keys that hold them (Table 28), by the
  # option they belong to.
  variable initialSince {
    pageMode   {UseOC 1.5 UseAttachments 1.6}
    pageLayout {TwoPageLeft 1.5 TwoPageRight 1.5}
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
          return -code error -errorcode [list TCLPDF VIEWERPREFERENCES ARGUMENT $option] \
              "tclpdf: viewerPreferences -$option takes a\
              boolean, not \"$value\""
        }
        set value [expr {$value ? 1 : 0}]
      } elseif {[dict exists $values $option]} {
        set allowed [dict get $values $option]
        if {$value ni $allowed} {
          return -code error -errorcode [list TCLPDF VIEWERPREFERENCES ARGUMENT $option] \
              "tclpdf: viewerPreferences -$option must be one\
              of [join $allowed {, }] - not \"$value\""
        }
      } elseif {$option eq "numCopies"} {
        # Table 150: "supported values shall be the integers 2 through 5;
        # values outside this range shall be ignored". A 1 or a 100 is not
        # a wish a reader follows, so it is refused rather than written -
        # "positive integer" used to be the rule here, and the value went
        # into the file to be ignored at the recipient. Whole digits only:
        # 0x3 and 2.0 are integers to [string is integer] and not to a
        # reader.
        if {![regexp {^[2-5]$} $value]} {
          return -code error -errorcode [list TCLPDF VIEWERPREFERENCES ARGUMENT numCopies] \
              "tclpdf: viewerPreferences -numCopies takes an\
              integer from 2 to 5 (ISO 32000-1, Table 150), not \"$value\""
        }
      }
      my RequireVersion [expr {[dict exists $since $option] ?
          [dict get $since $option] : 1.2}] "viewerPreferences -$option"
      # One VALUE has a version of its own: UseOC names optional content,
      # which is PDF 1.5 (ISO 32000-1 Table 150) - the key it sits in is 1.2.
      if {$option eq "nonFullScreenPageMode" && $value eq "UseOC"} {
        my RequireVersion 1.5 "viewerPreferences -nonFullScreenPageMode UseOC"
      }
      dict set current $option $value
    }
    # Subscribed once per document, and remembered as such - like fontHooked
    # in font.tcl. It used to be decided by "no preference set yet", and
    # that is not the same thing: ua 0 empties the dictionary again
    # (UaWithdraw takes DisplayDocTitle back out), and the next call then
    # subscribed a second ViewerPreferencesCatalog - measured, one catalog
    # subscriber more after ua 1; ua 0; viewerPreferences -hideToolbar 1.
    if {[my state viewerPreferencesHooked] eq {}} {
      my state viewerPreferencesHooked 1
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

  # $doc initialView ?-pageMode name? ?-pageLayout name?
  #                  ?-page n? ?-to {x y}? ?-zoom z?
  #     -> the settings after the call
  #
  # How a reader opens the document: which panel it shows beside the page
  # (/PageMode), how it arranges the pages (/PageLayout), and where it puts
  # the reader first (/OpenAction). Table 28 of ISO 32000-2; the reasoning
  # for a command of its own is at the head of this file.
  #
  # Calls accumulate, as [viewerPreferences] does, and without arguments it
  # answers what has been set so far.
  #
  # -page, -to and -zoom are the same three words [destination] and [link]
  # use for the same three choices, and they are read by [Destination] in
  # document.tcl - so an open action and a bookmark pointing at the same
  # place are written from one piece of code. -page counts from 0, as
  # [page current] counts, and may name a page not added yet: the target is
  # then filled in when the document is written, exactly as a forward link's
  # is. Without -to the destination is /Fit, the whole page, rather than a
  # position nobody gave.
  #
  # AN ACTION IS NOT OFFERED. Table 28 lets /OpenAction be a destination or
  # an action dictionary, and the second is left to [catalogEntry OpenAction]
  # for two reasons. An archived document is the case this package is built
  # for, and ISO 19005-2/-3, 6.6.1 forbids most action types outright
  # (Launch, Sound, Movie, ResetForm, ImportData, Hide, SetOCGState,
  # Rendition, Trans, GoTo3DView, JavaScript) while admitting only four
  # named ones - so an -action option would be a promise that half its
  # values break the moment [pdfa] is declared, the way a reset button
  # does (fieldButton.tcl). And the one action that IS admitted everywhere,
  # /GoTo, does nothing a destination does not do here. What is measured is
  # in the tests: a destination in /OpenAction passes veraPDF under PDF/A-3B.
  method initialView {args} {
    variable ::tclpdf::viewerPreferences::initialValues
    variable ::tclpdf::viewerPreferences::initialSince
    set current [my state initialView]
    if {![llength $args]} {
      return $current
    }
    set options [::tclpdf::option parse \
        {pageMode {} pageLayout {} page {} to {} zoom {}} $args "initialView"]
    # EVERYTHING IS CHECKED BEFORE ANYTHING IS WRITTEN - the same order every
    # method of this package keeps. A call that names a good -pageMode and a
    # misspelt -pageLayout must leave the catalogue as it was, or the
    # document carries half of what was asked for and the caller saw an
    # error.
    foreach option {pageMode pageLayout} {
      set value [dict get $options $option]
      if {$value eq {}} {
        continue
      }
      set allowed [dict get $initialValues $option]
      if {$value ni $allowed} {
        return -code error \
            -errorcode [list TCLPDF INITIALVIEW [string toupper $option] \
                $value] \
            "tclpdf: initialView -$option must be one of\
            [join $allowed {, }] - not \"$value\""
      }
    }
    set page [dict get $options page]
    if {$page eq {}} {
      # -to and -zoom describe a place ON a page, and there is no page to
      # describe a place on. Refused rather than read as page 0: a caller
      # who wrote them meant a page and forgot to say which.
      foreach option {to zoom} {
        if {[dict get $options $option] ne {}} {
          return -code error \
              -errorcode [list TCLPDF INITIALVIEW PAGE {}] \
              "tclpdf: initialView -$option describes how a page is shown\
              when the document opens and no page was given - add -page n,\
              counting from 0"
        }
      }
    } else {
      if {![string is integer -strict $page] || $page < 0} {
        return -code error -errorcode [list TCLPDF INITIALVIEW PAGE $page] \
            "tclpdf: initialView -page counts pages from 0, as \"page\
            current\" counts - not \"$page\""
      }
      if {[dict get $options to] ne {}} {
        ::tclpdf::option point [dict get $options to] -to "initialView"
      }
      # 12.3.2.2: in an /XYZ destination "a zoom value of 0 has the same
      # meaning as a null value", so 0 is a number a reader acts on and not
      # a mistake; below it there is no magnification to mean.
      set zoom [dict get $options zoom]
      if {$zoom ne {} && (![string is double -strict $zoom] || $zoom < 0)} {
        return -code error -errorcode [list TCLPDF INITIALVIEW ZOOM $zoom] \
            "tclpdf: initialView -zoom is a magnification of 0 or more, 1\
            being actual size and 0 the magnification the reader is already\
            at - not \"$zoom\""
      }
    }
    # From here on nothing can be refused except by the version floor, which
    # is raised BEFORE the entry it belongs to is written - the same rule
    # [viewerPreferences] keeps above.
    foreach option {pageMode pageLayout} {
      set value [dict get $options $option]
      if {$value eq {}} {
        continue
      }
      set since [dict get $initialSince $option]
      if {[dict exists $since $value]} {
        my RequireVersion [dict get $since $value] \
            "initialView -$option $value"
      }
      # Written straight into the catalogue rather than at write time, so
      # that [bookmark] finds it: the outline sets /PageMode /UseOutlines
      # only where nothing else has (outline.tcl), and a caller who asked
      # for thumbnails beside their bookmarks gets thumbnails.
      my catalogEntry [string toupper [string index $option 0]][string \
          range $option 1 end] [::tclpdf::pdfObj name $value]
      dict set current $option $value
    }
    if {$page ne {}} {
      my RequireVersion 1.1 "initialView -page"
      my catalogEntry OpenAction [my Destination $page \
          [dict get $options to] [dict get $options zoom] \
          "initialView -page $page"]
      dict set current page $page
      foreach option {to zoom} {
        if {[dict get $options $option] ne {}} {
          dict set current $option [dict get $options $option]
        }
      }
    }
    my state initialView $current
    return $current
  }
}

package provide tclpdf::viewerPreferences 1.4
