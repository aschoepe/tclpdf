#!/usr/bin/env tclsh
#
# tclpdf example 5.3 - links and bookmarks
#
#   tclsh examples/05.03-navigation.tcl ?output.pdf?
#
# A short manual with an outline and cross references. Neither is drawn on the
# page: both are structure a reader shows beside it or acts on when clicked,
# so the visible text has to be drawn separately - marking it up is a second
# call, on purpose, because the text may be a heading, a table cell or
# nothing at all.
#
# Two details matter for PDF/A and neither is obvious:
#
#   A link annotation must have its Print flag set. An archived document has
#   to look the same printed as on screen, and a validator rejects one that
#   could differ.
#
#   It gets a zero-width border, because the default is a visible frame that
#   no caller asked for.
#
# The third thing a reader is told about a document is how to PRESENT it, and
# that is neither a link nor an outline entry: [viewerPreferences] writes the
# /ViewerPreferences dictionary of the catalogue - centre the window, hide the
# toolbar, print duplex on the long edge, ask for two copies - and the last
# section of this file sets a dozen of them and reads them back.
#
# The outline is built while the document is written and turned into objects
# at the end: every entry needs the object numbers of its siblings, and the
# format is a doubly linked list at each level rather than a nested structure.
#
# Page labels are the third piece of navigation here. A page has two numbers -
# the index the file counts it by and the number printed on it - and a reader
# shows the first unless the file says otherwise. The chapters print "Page 1"
# to "Page 3" and the contents page prints no number, so the labels say the
# same: 1 to 3, then a name. Matterhorn 15-001 counts a printed number that
# differs from its label as an accessibility failure, and it is one no
# validator can find, because the printed number is drawn text.
#
# The two numbers are kept apart in the code as well, and that is the point
# to take from this example: -page on link and bookmark counts from 0, like
# everything else in the package and like [page current]; the printed number
# counts from 1. Handing the printed number to -page sent every bookmark one
# page too far - measured, and no validator sees it either, because a link
# to the wrong page is a perfectly valid link.
#
# Drawing cannot return to a page once the next one is added, so the
# contents page comes last and points BACK at chapters that exist - while
# the chapters, made first, point FORWARD at a contents page that does not
# exist yet. That is allowed: a link or a bookmark may name a page that is
# added later, and the write says so if it never comes. The index of the
# contents page is known before the first chapter is drawn - it is the
# number of chapters - which is all a forward link needs.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.03-navigation.pdf"}]

set doc [tclpdf new -unit mm]
$doc language en
$doc info Title "Kiln operation - short manual"
$doc info Author "Workshop documentation"

set chapters {
    {"Safety" {
        {"Before firing" "Check that the flue is clear and the shelves are\
            dry. A shelf soaked from washing will spall and take the ware\
            with it."}
        {"During firing" "Never open the door above 200 degrees. The thermal\
            shock cracks both the elements and whatever is inside."}
    }}
    {"Loading" {
        {"Shelf spacing" "Leave two centimetres above the tallest piece.\
            Radiant heat from the element needs somewhere to go."}
        {"Props" "Use three props per shelf, never four. Three always sit\
            flat; four will rock on an uneven floor."}
    }}
    {"Firing schedules" {
        {"Bisque" "Slow to 600 degrees, then 150 degrees per hour to 1000.\
            The slow start drives off water that would otherwise turn to\
            steam inside the clay."}
        {"Glaze" "Full power to 1220 degrees, then hold twenty minutes. The\
            hold is what lets the glaze level out."}
    }}
}

# First pass: one page per chapter, collecting where each section landed so
# the contents page can point at it. Two counters on purpose: the index is
# what -page and the targets take, the printed number is what the reader
# sees on the sheet - and the label below has to agree with the latter.
set targets {}
set printed 0
foreach chapter $chapters {
    lassign $chapter title sections
    $doc page add
    set index [$doc page current]
    incr printed
    set chapterId [$doc bookmark $title -page $index]
    dict set targets $title [list $index 22]

    $doc font -family helvetica -style bold -size 16
    $doc text $title -at {20 24} -tag H1
    $doc line -from {20 28} -to {190 28} -stroke {0.5 0.5 0.55} -width 0.4

    set y 40
    foreach section $sections {
        lassign $section heading body
        $doc bookmark $heading -page $index -at [list 20 $y] -parent $chapterId
        dict set targets $heading [list $index $y]

        $doc font -style bold -size 11
        $doc text $heading -at [list 20 $y] -tag H2
        $doc font -style {} -size 10
        set y [$doc text $body -at [list 20 [expr {$y + 6}]] -width 170 \
            -align justify -anchor top]
        set y [expr {$y + 10}]
    }

    # The way back points at a page that does not exist yet - the contents
    # page is added after the last chapter, so its index is the number of
    # chapters. A forward link is allowed; see the head of the file.
    $doc font -size 8 -color {0.45 0.45 0.5}
    $doc text "Back to contents" -at {20 280}
    $doc link -at {20 276} -size {30 5} -page [llength $chapters] -tooltip "Contents"
    # The printed number - what the page label below has to agree with.
    $doc text "Page $printed" -at {190 280} -align right
    $doc font -color black
}

# The contents page is added last, on a page of its own, so that it can point
# at pages that already exist; the chapters pointed at it before it was made.
$doc page add
set contents [$doc page current]
$doc font -family helvetica -style bold -size 18
$doc text "Kiln operation" -at {20 30}
$doc font -style {} -size 10
$doc text "Short manual - contents" -at {20 38}
$doc line -from {20 42} -to {190 42} -stroke {0.5 0.5 0.55} -width 0.4

set y 54
foreach chapter $chapters {
    lassign $chapter title sections
    lassign [dict get $targets $title] page at
    $doc font -style bold -size 12 -color {0.15 0.25 0.55}
    $doc text $title -at [list 20 $y]
    $doc link -at [list 20 [expr {$y - 4}]] -size {80 6} -page $page \
        -to [list 20 $at] -tooltip "Go to $title"
    set y [expr {$y + 8}]
    foreach section $sections {
        lassign $section heading -
        lassign [dict get $targets $heading] page at
        $doc font -style {} -size 10 -color {0.2 0.35 0.65}
        $doc text $heading -at [list 28 $y]
        $doc link -at [list 28 [expr {$y - 4}]] -size {80 6} -page $page \
            -to [list 20 $at] -tooltip "Go to $heading"
        set y [expr {$y + 7}]
    }
    set y [expr {$y + 4}]
}

$doc font -style {} -size 8 -color black
$doc text "Every line above is a link. The blue colour is drawn text - the\
    link itself is a rectangle laid over it, and it is invisible in print." \
    -at [list 20 [expr {$y + 6}]] -width 170
$doc text "An external link: the workshop notes." -at [list 20 [expr {$y + 20}]]
$doc link -at [list 20 [expr {$y + 16}]] -size {60 6} \
    -url "https://www.example.org/workshop" -tooltip "Opens in a browser"

$doc bookmark "Contents" -page $contents

# What the reader's page field shows (ISO 32000 12.4.2). The chapters are
# labelled 1, 2, 3 - decimal from the first page, matching "Page 1" to
# "Page 3" printed on them - and the contents page, which prints no number,
# is called "Contents" instead of being page 4 (Matterhorn 15-001: the
# visible number and the label must not disagree). A document that prints
# its numbers with [pageNumbers -from 3] should say [pageLabels -from 0
# -start 3] for the same reason.
$doc pageLabels -from 0 -style D
$doc pageLabels -from $contents -style none -prefix "Contents"

# -- how a reader should present the document -------------------------------
#
# Viewer preferences (ISO 32000 12.2) are the fourth piece of navigation, and
# the one nothing on the page shows: every key is a wish the reader may follow
# or ignore. Calls accumulate - each sets the keys it names and leaves the rest
# alone - so the window wishes stand here and the printing wishes below.
#
# The window: keep the toolbar, the menu bar and the window controls (the
# three hide keys are what a kiosk or a slide show sets, not a manual), size
# the window to the first page and centre it, and show the title from [info]
# in the title bar instead of the file name - the one key PDF/UA makes
# mandatory, because "05.03-navigation.pdf" says nothing to someone listening.
$doc viewerPreferences -hideToolbar 0 -hideMenubar 0 -hideWindowUI 0 \
    -fitWindow 1 -centerWindow 1 -displayDocTitle 1

# What the reader shows beside the page after leaving full-screen mode, and
# which way the pages run. The values are checked at the call: a misspelled
# one would not be an error any validator finds - the reader silently falls
# back to its default. UseNone shows the page alone, UseThumbs the thumbnails,
# UseOC the optional-content panel; R2L is for scripts read right to left.
# Each on a call of its own so the replacement is visible: a later call
# overrides what an earlier one set for the same key, and [viewerPreferences]
# without arguments answers with the result.
$doc viewerPreferences -nonFullScreenPageMode UseNone
$doc viewerPreferences -nonFullScreenPageMode UseThumbs -direction R2L
$doc viewerPreferences -nonFullScreenPageMode UseOC
# ...and what a manual with an outline wants: the bookmarks, read left to right.
$doc viewerPreferences -nonFullScreenPageMode UseOutlines -direction L2R

# The printing wishes, in one place of their own. -printScaling None prints
# the page at its own size, AppDefault leaves the choice to the reader.
# -duplex asks for one-sided printing (Simplex) or two-sided, turned on the
# short edge or - the binding a manual gets - on the long edge.
# -pickTrayByPDFSize lets the page size choose the paper tray, and -numCopies
# is what the print dialogue proposes. -direction needs PDF 1.3,
# -displayDocTitle 1.4, -printScaling 1.6 and the three printing keys 1.7 -
# the default here; a document declared older refuses them at the call.
$doc viewerPreferences -printScaling None -duplex Simplex
$doc viewerPreferences -duplex DuplexFlipShortEdge
$doc viewerPreferences -printScaling AppDefault -duplex DuplexFlipLongEdge \
    -pickTrayByPDFSize 1 -numCopies 2

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes), [$doc page count] pages"
puts "  bookmarks: [llength [$doc bookmarks]]"
puts "  page labels: [dict keys [$doc pageLabels]] -> 1, 2, 3, Contents"
set prefs [$doc viewerPreferences]
puts "  viewer preferences: [dict size $prefs] keys, after full screen\
    [dict get $prefs nonFullScreenPageMode], prints [dict get $prefs duplex]"
$doc destroy
