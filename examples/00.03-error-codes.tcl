#!/usr/bin/env tclsh
#
# tclpdf example 0.3 - handling what the package refuses
#
#   tclsh examples/00.03-error-codes.tcl ?output.pdf?
#
# Every refusal this package makes is an ordinary Tcl error whose message
# begins with "tclpdf:" - and carries a machine-readable -errorcode beside it.
# The message is for a person and may be reworded in any release. The code is
# for a script and is a contract.
#
# WHY THAT MATTERS more than it sounds: a script that reacts to a refusal has
# to recognise it first, and the only other handle is the message text. A
# script written as
#
#     if {[string match "*is already embedded*" $message]} { ... }
#
# breaks the day somebody sharpens the wording - and nothing about that day
# looks like a breaking change. The same script written against the code
# survives every rewording:
#
#     trap {TCLPDF FONT ALIAS} {} { ... }
#
# HOW A CODE IS BUILT. It is a Tcl LIST, and try/trap matches it by PREFIX:
#
#     TCLPDF  FONT     ALIAS       Body
#     ^       ^        ^           ^
#     always  topic    class       the facts of the case
#
# The first two words are the contract. Where a topic has classes the third
# is one too, and it says WHAT THE CALLER HAS TO DO about it: ARGUMENT means
# a value in the call is wrong, STATE means the call came in the wrong order,
# NAME or ALIAS means something was named that does not exist, FOREIGN means
# the file was not written by this package, DAMAGED means it is broken. What
# follows are facts - which option, which alias, which page - and those may
# grow, which is why a trap matches a prefix and never the whole list.
#
# So a handler can be as wide or as narrow as it needs to be: trap {TCLPDF}
# catches everything this package refuses, trap {TCLPDF FONT} everything
# about fonts, trap {TCLPDF FONT ALIAS} only a name that is taken or unknown.
#
# This script provokes eight refusals, prints what each one answers, and puts
# the same table on a page.
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "00.03-error-codes.pdf"}]

set doc [tclpdf new -unit mm]
$doc info Title "Handling what the package refuses"
$doc page add

# Eight mistakes a script actually makes, each one from a different topic.
# The scripts are held as text and run through [catch] so that the code and
# the message can be shown side by side.
set cases {
    "a font alias that is already taken"
        {$doc font embed body [file join $here assets fonts DejaVuSans.ttf]
         $doc font embed body [file join $here assets fonts DejaVuSans.ttf]}
    "an option value that is not a number"
        {$doc rect -at {20 20} -size {10 10} -width nonsense}
    "a point written in braces, so nothing substituted"
        {set y 30; $doc text "x" -at {20 $y}}
    "a picture that was never embedded"
        {$doc image place nosuchpicture -at {20 20}}
    "a page index the document does not have"
        {$doc page size 99}
    "a colour nobody defined"
        {$doc rect -at {20 20} -size {10 10} -fill fuchsiate}
    "a file that is not there"
        {$doc image embed missing [file join $here assets images no-such-file.png]}
    "a subcommand that does not exist"
        {$doc layer nosuchsubcommand}
}

set rows {}
foreach {what script} $cases {
    if {[catch $script message options]} {
        set code [dict get $options -errorcode]
        # A code carries FACTS, and a fact can be an absolute path - which
        # would put this machine's directory layout into an example document
        # and make two runs on two machines produce different files. Shortened
        # for the page; a script reading the code gets the whole thing.
        set code [lmap word $code {
            expr {[string match {/*} $word] ? ".../[file tail $word]" : $word}
        }]
    } else {
        set code "NOT REFUSED - the check did not fire"
        set message {}
    }
    lappend rows [list $what $code $message]
}

# -- what a script does with it ---------------------------------------------
#
# The point of the whole file, in six lines: the SAME refusal handled three
# ways, from the widest handler to the narrowest. try/trap needs Tcl 8.6,
# which this package requires anyway.
proc classify {script} {
    try {
        uplevel 1 $script
        return "not refused"
    } trap {TCLPDF FONT ALIAS} {-> options} {
        return "handled as: a font alias problem"
    } trap {TCLPDF FONT} {} {
        return "handled as: something about fonts"
    } trap {TCLPDF} {} {
        return "handled as: some tclpdf refusal"
    }
}

set handled [classify {$doc font embed body [file join $here assets fonts DejaVuSans.ttf]}]

# -- the page ---------------------------------------------------------------

$doc font -family helvetica -style bold -size 15 -color black
$doc text "Handling what the package refuses" -at {20 22}
$doc font -style {} -size 9
set y [$doc text "Every refusal carries an -errorcode beside its message. The\
    message is for a person and may be reworded in any release; the code is a\
    contract. It is a Tcl list, and try/trap matches it by prefix - so a\
    handler is as wide or as narrow as it needs to be." \
    -at {20 30} -width 170]

$doc font -family courier -size 8
set y [expr {$y + 4}]
foreach line {
    "trap {TCLPDF} ...             everything this package refuses"
    "trap {TCLPDF FONT} ...        everything about fonts"
    "trap {TCLPDF FONT ALIAS} ...  only a name taken or unknown"
} {
    $doc text $line -at [list 24 $y]
    set y [expr {$y + 4.5}]
}
$doc font -family helvetica -size 8
set y [expr {$y + 2}]
set y [$doc text "The same mistake, put through the three handlers above:\
    \"$handled\" - the narrowest one that matches wins, which is what makes a\
    wide handler safe to keep as a fallback." -at [list 20 $y] -width 170]

$doc font -style bold -size 10
set y [expr {$y + 6}]
$doc text "Eight refusals, and what they answer" -at [list 20 $y]
set y [expr {$y + 6}]

# The table: what was tried, and the code that came back. The message is left
# off the page on purpose - it is the part that may change, and a page that
# printed it would invite exactly the habit this example argues against.
$doc font -style {} -size 8
set y [$doc table -at [list 20 $y] -width 170 -theme striped \
    -head {{"the mistake" "-errorcode"}} \
    -body [lmap row $rows {list [lindex $row 0] [lindex $row 1]}] \
    -columns {{width 80} {}}]

$doc font -size 7.5 -color {0.35 0.35 0.4}
$doc text "The message is deliberately not on this page. It is the half that\
    may be sharpened in any release, and a script that reads it is the habit\
    the codes exist to replace. The full list of topics and classes is in the\
    manual under \"Error codes\"." -at [list 20 [expr {$y + 6}]] -width 170

exampleFooter $doc

$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  the same refusal through three handlers: $handled"
puts ""
foreach row $rows {
    puts [format "  %-46s %s" [lindex $row 0] [lindex $row 1]]
}
$doc destroy
