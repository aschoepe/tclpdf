#!/usr/bin/env tclsh
#
# tclpdf example 2.2 - the same page with and without an embedded face
#
#   tclsh examples/02.02-languages.tcl ?output.pdf?
#
# This example writes THREE files from one set of texts:
#
#   ...-standard.pdf   set in Helvetica, one of the fourteen standard fonts
#   ...-embedded.pdf   set in DejaVu Sans, embedded and subsetted
#   ...-small.pdf      set in Roboto - a fifth the FONT FILE, same twelve lines
#
# Put them side by side. The first pair shows that the standard fonts can only
# address 256 characters through WinAnsiEncoding, so every language needing
# more comes out wrong or not at all. The third answers the conclusion that
# invites - "then take the biggest face" - which is wrong: what decides is
# whether the characters a document uses are in the file, not how many the
# file has.
#
# tclpdf refuses rather than substituting. A missing character raises an
# error, and this example catches it and prints what could not be set. That
# refusal is the single place in the whole chain that notices: neither veraPDF
# nor Mustangproject nor any reader will tell you that a euro sign is gone.
#
# The strings are written as \u escapes, not as literal characters. Measured:
# Tcl 8.6 reads a source file through the system encoding and Tcl 9 as UTF-8,
# so a literal would not mean the same thing in both interpreters.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.02-languages.pdf"}]
set stem [file rootname $target]
set assets [file join $here assets]

# Language and sample. Seven of these stay inside WinAnsiEncoding and five do
# not - that is the whole demonstration.
#
# Danish and Swedish are in the list because they LOOK like they would fail
# and do not: ae-ligature, o-slash, a-ring, a-umlaut and o-umlaut all have
# WinAnsi codes, so they set in Helvetica without complaint. "Needs an
# embedded face" is not a property of a language but of the characters it
# happens to use, and a list where every non-English line fails would teach
# the wrong lesson.
#
# Bulgarian fails for the same reason Russian would - Cyrillic has no WinAnsi
# codes at all.
set samples [list \
    [list English "The quick brown fox jumps over the lazy dog"] \
    [list German "Gr\u00F6\u00DFere Bl\u00E4tter, wei\u00DFe \u00C4pfel - 12,50 \u20AC"] \
    [list French "Les \u0153ufs fra\u00EEches co\u00FBtent 3,20 \u20AC \u00E0 No\u00EBl"] \
    [list Spanish "El ni\u00F1o pregunt\u00F3: \u00BFcu\u00E1nto cuesta?"] \
    [list Portuguese "A informa\u00E7\u00E3o est\u00E1 na se\u00E7\u00E3o tr\u00EAs"] \
    [list Polish "Z\u0142ota jesie\u0144 w \u0141odzi i Gda\u0144sku"] \
    [list Czech "P\u0159\u00EDli\u0161 \u017Elu\u0165ou\u010Dk\u00FD k\u016F\u0148"] \
    [list Turkish "\u0130stanbul\u2019da bir \u015Fehir gezisi"] \
    [list Greek "\u0391\u03B8\u03AE\u03BD\u03B1 - \u03BA\u03B1\u03BB\u03B7\u03BC\u03AD\u03C1\u03B1"] \
    [list Danish "R\u00F8dgr\u00F8d med fl\u00F8de p\u00E5 \u00C6beltoft"] \
    [list Swedish "R\u00E4ksm\u00F6rg\u00E5s p\u00E5 \u00D6land i p\u00E5sk"] \
    [list Bulgarian "\u0421\u043E\u0444\u0438\u044F - \u0434\u043E\u0431\u044A\u0440 \u0434\u0435\u043D \u0438 \u0431\u043B\u0430\u0433\u043E\u0434\u0430\u0440\u044F"]]

# Draw the same page with whichever font family is given.
proc page {doc family boldFamily heading} {
    $doc page add
    $doc font -family $boldFamily -size 15
    $doc text $heading -at {20 22}
    $doc font -family $family -style {} -size 9
    $doc text "The same twelve lines. A line that cannot be set is replaced by the\
        reason it could not." -at {20 30} -width 170

    set y 44
    set failed 0
    foreach entry $::samples {
        lassign $entry language sample
        $doc font -family $boldFamily -size 8
        $doc text $language -at [list 20 $y]
        $doc font -family $family -size 10
        if {[catch {$doc text $sample -at [list 48 $y]} message]} {
            incr failed
            $doc font -family helvetica -style {} -size 8
            # Wrapped rather than cut at a fixed character count: the reason
            # names a code point and a face, and truncating it to 62
            # characters ran the line off the right edge of the page while
            # losing the half that says which encoding was meant.
            $doc text "cannot be set - [string range $message 8 end]" \
                -at [list 48 $y] -width 142 -color {0.75 0 0}
        }
        incr y 11
    }

    $doc font -family $family -style {} -size 9
    $doc text "Lines that could not be set: $failed of [llength $::samples]" \
        -at [list 20 [expr {$y + 6}]]
    # The y below the summary, so the caller can put its closing paragraph
    # there instead of guessing. Guessing is what this example did: the
    # paragraph sat at a fixed 178 mm while the summary had walked down to 182,
    # and the two printed on top of each other.
    return [list $failed [expr {$y + 12}]]
}


# -- one file with the standard fonts, one with an embedded face -----------

set doc [tclpdf new -unit mm]
$doc info Title "Languages in the standard fonts"
lassign [page $doc helvetica helvetica \
    "Standard fonts - WinAnsi, 256 characters"] failedStandard bottom
$doc font -family helvetica -style {} -size 8
$doc text "Helvetica reaches Western Europe and stops there. The languages\
    that failed need characters WinAnsiEncoding has no code for, so tclpdf\
    refuses instead of dropping them silently - which is what makes the\
    failure visible at all." -at [list 20 $bottom] -width 170
exampleFooter $doc
$doc write ${stem}-standard.pdf
$doc destroy

set doc [tclpdf new -unit mm]
$doc info Title "Languages in an embedded face"
$doc font embed body [file join $assets fonts DejaVuSans.ttf]
$doc font embed bodyBold [file join $assets fonts DejaVuSans-Bold.ttf]
lassign [page $doc body bodyBold \
    "Embedded face - Identity-H, any code point"] failedEmbedded bottom
$doc font -family body -size 8
set info [$doc font info body]
set largeChars [dict get $info characters]
$doc text "DejaVu Sans is embedded and reduced to the glyphs actually used.\
    Identity-H addresses glyphs directly, so the encoding is no longer a\
    limit - and a ToUnicode CMap keeps the text copyable and searchable. The\
    face carries [dict get $info glyphs] glyphs and maps\
    [dict get $info characters] characters; only the ones on this page go\
    into the file." -at [list 20 $bottom] -width 170
exampleFooter $doc
$doc write ${stem}-embedded.pdf
$doc destroy

# -- and a third: a much smaller face that covers just as much --------------
#
# The obvious conclusion from the first two files is "take the big face". It
# is wrong, and the third file shows why: Roboto maps a fraction of the
# characters DejaVu Sans does and sets every one of these twelve lines,
# Cyrillic and Greek included, from a font file a fifth the size.
#
# The DOCUMENTS, though, come out within about a tenth of each other - measured
# here, not estimated. That is the real lesson and it cuts both ways: a subset
# carries the glyphs a page uses, so the file on disk barely matters to the
# result. What the smaller file does buy is the parse, and what the coverage
# buys is being able to set the page at all.
#
# Roboto has no bold here (one face per family in assets/), so the headings
# borrow DejaVu: two embedded families in one document, which is what a real
# report does anyway.
set doc [tclpdf new -unit mm]
$doc info Title "Languages in a smaller embedded face"
$doc font embed roboto [file join $assets fonts Roboto-Regular.ttf]
$doc font embed bodyBold [file join $assets fonts DejaVuSans-Bold.ttf]
lassign [page $doc roboto bodyBold \
    "A smaller face - fewer characters, same twelve lines"] failedSmall bottom
$doc font -family roboto -size 8
set small [$doc font info roboto]
$doc text "Roboto maps [dict get $small characters] characters where DejaVu\
    Sans maps $largeChars, and sets the same twelve lines from a font file of\
    [file size [file join $assets fonts Roboto-Regular.ttf]] bytes against\
    [file size [file join $assets fonts DejaVuSans.ttf]]. Compare the two\
    documents, though, and they are within a tenth of each other: a subset\
    carries the glyphs the page uses, so the size on disk hardly reaches the\
    result. Count of characters is not coverage of a document either - what\
    matters is whether the ones actually used are in the file."\
    -at [list 20 $bottom] -width 170
exampleFooter $doc
$doc write ${stem}-small.pdf
$doc destroy

foreach {name failed} [list ${stem}-standard.pdf $failedStandard \
        ${stem}-embedded.pdf $failedEmbedded ${stem}-small.pdf $failedSmall] {
    puts "  written: $name ([file size $name] bytes),\
        $failed of [llength $samples] lines could not be set"
}
