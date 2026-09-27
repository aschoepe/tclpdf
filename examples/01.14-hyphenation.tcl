#!/usr/bin/env tclsh
#
# tclpdf example 1.14 - automatic hyphenation
#
#   tclsh examples/01.14-hyphenation.tcl ?output.pdf?
#
# The same paragraph twice in the same narrow column: once as the breaker sets
# it today, once with -hyphenate on. Justified, because that is where the
# difference is not a matter of taste - an unhyphenated justified column pays
# for every long word with a line of gaping word spaces. Each column says how
# many lines it took and how wide its worst word space grew, and BOTH numbers
# are read back out of the document rather than claimed: the line count from
# [textLines], the word space from the "Tw" operators the justification wrote.
# At this width the line count does not even change - the raggedness does, and
# that is the honest measure of what hyphenation buys.
#
# ONE LANGUAGE PER PAGE: German on the first, English on the second, and a
# third page for the break of last resort, -emergencyHyphen, which cuts a
# word no pattern set can break rather than letting it stand out of the
# column. Both
# pairs on a single page did not fit and had not been noticed, because a page
# that overflows still writes a PDF: measured, six of the ten specimen rows
# were drawn below the lower edge of the A4 sheet - the last at 324 mm on a
# 297 mm page, where no reader shows it - and the footer printed in the middle
# of the list. A page each also puts the comparison that carries the example,
# with against without, side by side and undisturbed by the other language.
#
# THE PATTERNS ARE NOT PART OF TCLPDF. Every published pattern set carries
# terms of its own - the German ones LGPL over LPPL, the American English ones
# BSD-style over the plain TeX table - and this package is MIT, so it ships
# none of them and the caller loads what that machine has. This script looks
# under examples/assets/languages, which is not in the repository either: on a
# machine without the files it sets both columns unhyphenated, says so on both
# pages and on the console, and does not fail. See the README in that
# directory for where to get them.
#
# WHAT IS BEING SHOWN, beyond "it breaks words": the guards. A hyphenator
# without them sets "A-bend", breaks a part number in half and hyphenates a
# URL. Each page closes with a handful of words of its own language run through
# [::tclpdf::hyphenate word], the refused ones included with the reason beside
# them - that command exists for exactly this, checking and showing. The guards
# themselves know no language; what the two pattern files decide is how much of
# a word has to stay on each side, and that is read back rather than written
# here.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
set auto_path [linsert $auto_path 0 [file dirname $here]]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "01.14-hyphenation.pdf"}]
set assets [file join $here assets languages]

# Whether this build can hyphenate a DRAWN paragraph, decided once and before
# the first line is set - a paragraph that refuses halfway leaves half a page
# behind, and the page has to say which of the two settings it is showing.
#
# Answers two values for [lassign]:
#
#   tags   the language tags that were loaded and are usable, {} if none
#   why    why not, in one sentence, {} when there are tags
#
# It prints nothing: what a missing pattern file means is this script's
# sentence to write, on its page and on the console.
#
# Two things can be missing, and they are told apart because the remedies
# differ: the pattern files, which are downloaded (see the README next to
# them), and -hyphenate on [$doc text], which is a property of the build.
proc hyphenationSetup {files} {
    if {[catch {package require tclpdf::hyphenate}]} {
        return [list {} "this build has no tclpdf::hyphenate module"]
    }
    set doc [tclpdf new]
    $doc page add
    set takesOption [expr {![catch {
        $doc text "Wort" -at {10 10} -width 50 -hyphenate 0
    }]}]
    $doc destroy
    if {!$takesOption} {
        return [list {} "this build's \[text\] does not take -hyphenate"]
    }
    set tags {}
    dict for {tag arguments} $files {
        set path [lindex $arguments 0]
        if {![file exists $path]} {
            continue
        }
        if {[catch {::tclpdf::hyphenate load $tag {*}$arguments} message]} {
            return [list {} [lindex [split $message \n] 0]]
        }
        lappend tags $tag
    }
    if {![llength $tags]} {
        return [list {} "no pattern files under [file tail [file dirname\
            [file dirname $::assets]]]/assets/languages - see the README there"]
    }
    return [list $tags {}]
}

# hyph_de_DE.dic states no LEFTHYPHENMIN and no RIGHTHYPHENMIN although German
# wants 2 and 2; hyph_en_US.dic states 2 and 3 itself and needs nothing said
# about it. That asymmetry is real and is why the minima are options rather
# than a table inside the package.
lassign [hyphenationSetup [dict create \
    de-DE [list [file join $assets hyph_de_DE.dic] -left 2 -right 2] \
    en-US [list [file join $assets hyph_en_US.dic]]]] tags why

# The option list handed to the RIGHT column of each pair. Empty where there
# is nothing to hyphenate with, which is what makes this script run on a
# machine that has no pattern files: both columns are then set the same way
# and the page says so.
proc hyphenateWith {tag} {
    if {$tag in $::tags} {
        return [list -hyphenate $tag]
    }
    return {}
}

set german "Dies ist ein längerer deutscher Blindtext, der gezielt eingesetzt wird,\
    um das optische Erscheinungsbild von Schriftzeichen, Zeilenabständen und\
    Absätzen in einem finalen Layout zu prüfen. Da der eigentliche Inhalt zu\
    diesem Zeitpunkt noch nicht feststeht oder für die Gestaltung irrelevant\
    ist, füllen diese Worte den Raum, ohne das Auge des Betrachters durch\
    eine konkrete Botschaft abzulenken. Die Verteilung der Buchstaben\
    entspricht der typischen deutschen Sprache, sodass häufige Buchstaben\
    wie das e oder n in natürlicher Frequenz auftauchen und sich kurze sowie\
    lange Wörter harmonisch abwechseln. Ein gutes Design zeichnet sich\
    dadurch aus, dass der Textfluss natürlich wirkt. Wenn Sie diesen\
    Platzhalter lesen, merken Sie schnell, dass die Aneinanderreihung von\
    Wörtern keinen tieferen Sinn ergibt. Sobald die echten Redaktionsdaten\
    vorliegen, wird dieser gesamte Abschnitt mit nur wenigen Klicks\
    ausgetauscht, und das Projekt kann in die finale Phase gehen."
set english "This is a longer English dummy text designed to simulate the flow of\
    natural language within a paragraph layout. Designers and developers use\
    placeholders like this to evaluate typography, line height, and overall\
    visual balance before the final editorial content is written. It helps\
    focus on the aesthetic presentation rather than the actual message. The\
    word lengths closely mimic standard English vocabulary, meaning common\
    characters like vowels and frequent consonants appear naturally to\
    provide an accurate representation of paragraph density. A\
    well-structured interface relies heavily on how text blocks integrate with\
    graphical elements. As you scan through these sentences, you will notice\
    the lack of a cohesive narrative, which is intentional. Once the genuine\
    copy is approved, this placeholder will be completely replaced, allowing\
    the design to fulfill its ultimate purpose."

set doc [tclpdf new -unit mm]
$doc info Title "Automatic hyphenation"
$doc language de-DE

# Open a page: the heading, the paragraph under it, and - on a machine without
# pattern files - the line that says the two columns below it are the same.
# Both pages are opened through here rather than each laying itself out, so
# that the notice cannot end up on one page and be forgotten on the other.
# Answers the y the page's first pair starts from.
proc openPage {doc heading intro} {
    $doc page add
    $doc font -family helvetica -style bold -size 14 -color {0.20 0.30 0.45}
    $doc text $heading -at {20 25}
    $doc font -family helvetica -style {} -size 9 -color {0.35 0.35 0.35}
    set y [$doc text $intro -at {20 33} -width 170]
    if {![llength $::tags]} {
        $doc font -family helvetica -style bold -size 9 -color {0.65 0.20 0.20}
        set y [$doc text "No hyphenation here: $::why. Both columns below are\
            therefore the same, and the pair on this page shows the LEFT\
            setting twice." -at [list 20 [expr {$y + 2}]] -width 170]
    }
    return $y
}

# -- the pair ----------------------------------------------------------------

# The widest word space a stretch of the content stream carries, in points.
# Justification writes "N Tw" per line (ISO 32000-1, 9.3.3), so the largest N
# of a column is the worst gap a reader sees in it. Taken over a stretch rather
# than the whole page, which is what makes it a number about ONE column.
proc widestSpace {doc from} {
    set most 0
    foreach {- value} [regexp -all -inline {([-0-9.]+) Tw} \
        [string range [$doc page content] $from end]] {
        if {$value > $most} {
            set most $value
        }
    }
    return [format %.1f $most]
}

# One pair: the heading, and two columns of the same width and the same text.
# The columns are drawn BEFORE their labels because the labels quote what the
# columns measured - where the text sits on the page does not depend on the
# order the operators were written in.
proc pair {doc y title text tag} {
    set with [hyphenateWith $tag]
    $doc font -family helvetica -style {} -size 9.5
    set plain [llength [$doc textLines $text -width 78]]
    set broken [llength [$doc textLines $text -width 78 {*}$with]]
    set top [expr {$y + 12}]
    $doc font -family helvetica -style {} -size 9.5 -color black
    set mark [string length [$doc page content]]
    set left [$doc text $text -at [list 20 $top] -width 78 -align justify]
    set leftGap [widestSpace $doc $mark]
    set mark [string length [$doc page content]]
    set right [$doc text $text -at [list 112 $top] -width 78 -align justify \
        {*}$with]
    set rightGap [widestSpace $doc $mark]
    $doc font -family helvetica -style bold -size 10 -color {0.20 0.30 0.45}
    $doc text $title -at [list 20 $y]
    $doc font -family helvetica -style {} -size 8 -color {0.45 0.45 0.45}
    $doc text "without - $plain lines, worst word space $leftGap pt" \
        -at [list 20 [expr {$y + 6}]]
    $doc text "with -hyphenate $tag - $broken lines, worst word space\
        $rightGap pt" -at [list 112 [expr {$y + 6}]]
    return [expr {max($left, $right)}]
}

# -- the specimens -----------------------------------------------------------

# The words, the language they are read in, and what makes each one worth
# printing. Kept as data so that the page and the console say the same thing,
# and split by language so that each page carries its own.
set germanWords {
    de-DE Silbentrennung        "the ordinary case"
    de-DE Donaudampfschiff      "a compound, taken apart at its joints"
    de-DE Schifffahrt           "three f, and the break between the second and the third"
    de-DE Abend                 "refused: the left minimum, or it would read A-bend"
    de-DE A4-Blatt              "refused: a digit in the word"
}
set englishWords {
    en-US hyphenation           "the ordinary case"
    en-US representation        "five pieces out of patterns of three letters"
    en-US into                  "refused: shorter than -min"
    en-US WWW                   "refused: capitals throughout"
    en-US hyphenation.txt       "refused: a dot left inside the word"
}
set specimens [concat $germanWords $englishWords]

# One block of specimens under its own heading. Both pages go through here, so
# the two cannot drift apart in layout while saying the same kind of thing.
proc specimenBlock {doc y heading intro rows} {
    $doc font -family helvetica -style bold -size 10 -color {0.20 0.30 0.45}
    $doc text $heading -at [list 20 $y]
    $doc font -family helvetica -style {} -size 9 -color {0.35 0.35 0.35}
    set y [$doc text $intro -at [list 20 [expr {$y + 5}]] -width 170]
    set y [expr {$y + 3}]
    foreach {tag word note} $rows {
        set shown $word
        if {$tag in $::tags} {
            set shown [join [::tclpdf::hyphenate word $tag $word] "-"]
        }
        $doc font -family courier -style {} -size 9 -color black
        $doc text $tag -at [list 20 $y]
        $doc text $shown -at [list 38 $y]
        $doc font -family helvetica -style {} -size 8.5 -color {0.45 0.45 0.45}
        $doc text $note -at [list 110 $y]
        set y [expr {$y + 5}]
    }
    return $y
}

# -- page one: German --------------------------------------------------------

set y [openPage $doc "Automatic hyphenation" "The pair below is the same\
    paragraph in the same 78 mm column, justified. On the left the breaker as\
    it has always worked; on the right with -hyphenate. tclpdf ships no\
    patterns - the caller loads them, because every published set carries its\
    own licence and this package is MIT. English follows on the second page."]
set y [pair $doc [expr {$y + 8}] "German" $german de-DE]

set y [specimenBlock $doc [expr {$y + 10}] \
    "Where the breaks are, and where they are refused" \
    "\[::tclpdf::hyphenate word\] answers the pieces a word falls into, shown\
    here with hyphens between them. A word that comes back whole was refused by\
    one of the guards, and the reason stands beside it - without those, a\
    hyphenator sets \"A-bend\" and breaks a part number in half." $germanWords]

# The footer is drawn per PAGE, not per document - it writes on whichever page
# is current when it is called, so a page that is finished gets its footer
# before the next one is added.
exampleFooter $doc

# -- page two: English, and what the patterns say about single words ---------
#
# The word block ends this page rather than opening it: it reads as the answer
# to the two columns above it, and the columns are what the reader came for.

set y [openPage $doc "Automatic hyphenation - English" "The same comparison\
    for English, in the same 78 mm column, so that the two languages can be\
    held against each other. What the patterns do to single words, and where\
    they refuse to, stands below it."]
set y [pair $doc [expr {$y + 8}] "English" $english en-US]

# The guards are the same code for both languages; what differs is the two
# minima, and they are DATA - they come out of the pattern file itself, which
# is why they are read back rather than written here.
set y [specimenBlock $doc [expr {$y + 10}] \
    "The same guards, on English words" \
    "The guards do not know a language: the same rules that keep \"Abend\"\
    whole keep \"into\" whole. What the file decides is how much of a word has\
    to stay on each side, and the console line above says what each of the two\
    brought with it." $englishWords]

# WHAT HAPPENS WHERE THERE ARE NO PATTERNS AND NO SOFT HYPHENS, which is the
# other half of this subject: a word longer than the column is broken by
# character rather than let run past the edge. -emergencyHyphen puts a hyphen
# on that break, and it is OFF by default - the words that reach this fallback
# are as often a part number, a file path or a URL as a long word, and a
# hyphen inside one of those is a character the reader copies and a wrong
# value.

$doc page add
$doc font -family helvetica -style bold -size 14 -color {0.20 0.30 0.45}
$doc text "The break of last resort" -at {20 25}
$doc font -style {} -size 9 -color {0.35 0.35 0.35}
$doc text "No language, no patterns, no soft hyphens - just a word wider than\
    its column. The left column is what the breaker has always done; the right\
    one is the same break with -emergencyHyphen 1. The marked lines carry one\
    character FEWER: the hyphen is measured with the piece rather than hung on\
    after it, so the line stays inside the column." -at {20 32} -width 170

set specimen "Donaudampfschifffahrtsgesellschaftskapitaen"
$doc font -size 8 -color {0.45 0.45 0.45}
$doc text "plain" -at {20 50}
$doc text "-emergencyHyphen 1" -at {80 50}
$doc font -family helvetica -size 11 -color {0.1 0.1 0.1}
$doc text $specimen -at {20 55} -width 32
$doc text $specimen -at {80 55} -width 32 -emergencyHyphen 1

# And a part number, which is why the option is off by default: the hyphen
# would become part of a value somebody copies out of the page.
$doc font -size 8 -color {0.45 0.45 0.45}
$doc text "a part number - the reason the option is off by default:" \
    -at {20 85} -width 170
$doc font -size 11 -color {0.1 0.1 0.1}
$doc text "DIN-EN-ISO-9001-2015-A1-2024-REV-C" -at {20 92} -width 32

exampleFooter $doc
$doc write $target
$doc destroy

puts "  written: $target ([file size $target] bytes)"
if {[llength $tags]} {
    foreach tag $tags {
        set facts [::tclpdf::hyphenate languages $tag]
        puts "  $tag: [dict get $facts patterns] patterns, left\
            [dict get $facts left], right [dict get $facts right]"
    }
    foreach {tag word -} $specimens {
        puts "    [format %-6s $tag] [join [::tclpdf::hyphenate word $tag $word] -]"
    }
} else {
    puts "  set WITHOUT hyphenation: $why"
    puts "  the page says so; see examples/assets/languages/README"
}
