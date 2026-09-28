#!/usr/bin/env tclsh
#
# check.tcl - run every reference snippet of the tclpdf-tcl skill for real
#
#   tclsh8.6 check.tcl assets.tcl ?reference/03-text.md ...?
#
# The reference files are the code a reader copies, so they have to keep
# running against the package as it is. Each reference/*.md is one script:
# every ```tcl block is extracted, in order, and the whole is run in a FRESH
# tclsh (so an oo::define or a leftover state in one file cannot carry another
# one). Then qpdf --check runs over every PDF that came out, and veraPDF over
# every PDF that claims a PDF/A part or a PDF/UA part - with the flavour the
# file itself claims. A missing tool is a SKIP, never a pass.
#
# A script that ends without an error is not enough, and that is the second
# half of the file check: many snippets demonstrate a REFUSAL, and a snippet
# demonstrating one catches its own error - so a call that STOPPED being
# refused would leave the exit status at 0 and nothing would say anything.
# Two things close that hole, and they close it from both ends:
#
#   at run time  every catch/try that demonstrates a refusal carries a SUCCESS
#                branch printing one of the two wordings [unrefused] looks
#                for, "NOT REFUSED" or "went through, which it should not
#                have". Such a line is a failure of the file that printed it.
#
#   at read time [branches] counts, in the extracted code, the catch and try
#                commands against those success branches and requires ONE
#                EACH. A demonstration written without its else would pass the
#                run silently for ever; here it fails at once, before the
#                script is even started. A [catch {package require ...}] is a
#                capability probe rather than a demonstration and is not
#                counted - it is the one form whose two branches are both
#                ordinary outcomes.
#
# Until 2026-08-27 only the first half existed, and only for the files that
# happened to write the branch: around 28 demonstrations across the reference
# had none, and a mutation that made one of them stop refusing (measured:
# "overprint" to "overprint -fill 1" in 04-graphics.md) passed the check.
#
# assets.tcl sets the variables the snippets refer to (see SKILL.md, "The one
# setup every snippet assumes") - ttf, png, iccRgb, invoiceXml, out ... - and
# it is the ONLY place a project has to edit.
#
# Exit status: 0 when every script ran and every check passed, 1 otherwise.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

if {[llength $argv] < 1} {
    puts stderr "usage: [file tail [info script]] assets.tcl ?reference.md ...?"
    exit 2
}
set here [file dirname [file normalize [info script]]]
set assetsFile [file normalize [lindex $argv 0]]
set files [lrange $argv 1 end]
if {![llength $files]} {
    set files [lsort [glob -directory [file join $here reference] *.md]]
}

# The assets file is sourced here only to learn $out and to fail early when a
# path in it does not exist; each script sources it again for itself.
source $assetsFile
if {![info exists out]} { puts stderr "assets file sets no \$out"; exit 2 }
# The extracted scripts sit beside the output directory rather than inside it,
# the way the examples sit beside theirs: check-*.tcl next to out/*.pdf, both
# under whatever assets.tcl points $out at - examples/tmp/reference in this
# tree. Keeps "the code" and "what it produced" apart at a glance.
set scripts [file dirname [file normalize $out]]
file mkdir $out $scripts
# $hyphenPatterns is deliberately NOT in this list: the package ships no
# hyphenation patterns (licence), so the file may well not be there, and
# 03-text.md checks for it and says so instead of failing.
foreach name {ttf ttfBold otf type1 variable jpTtf jpeg png tiff svgFile iccRgb iccCmyk invoiceXml orderXml} {
    if {[info exists $name] && ![file exists [set $name]]} {
        puts stderr "asset \$$name does not exist: [set $name]"
        exit 2
    }
}

proc have {tool} { expr {[auto_execok $tool] ne ""} }

set failed 0
set skipped 0
proc pass {text} { puts "PASS $text" }
proc fail {text} { global failed; incr failed; puts "FAIL $text" }
proc skip {text} { global skipped; incr skipped; puts "SKIP $text" }

# -- 1. every reference file as one script ----------------------------------

proc snippets {path} {
    set channel [open $path r]
    fconfigure $channel -encoding utf-8
    set lines [split [read $channel] \n]
    close $channel
    set code {}
    set inside 0
    set n 0
    foreach line $lines {
        incr n
        if {!$inside && [regexp {^```tcl\s*$} $line]} {
            set inside 1
            append code "# --- [file tail $path] line $n ---\n"
            continue
        }
        if {$inside && [regexp {^```\s*$} $line]} { set inside 0; continue }
        if {$inside} { append code $line \n }
    }
    return $code
}

# The lines a snippet prints when a call it expected to be refused went
# through. Both wordings are the reference files' own: "NOT REFUSED" is what
# the table of field refusals prints in the column where the error code
# belongs, and "went through, which it should not have" is what a try/trap
# block prints in the branch that should be unreachable. Neither raises an
# error - the snippet caught its own - so without this the file passes.
proc unrefused {output} {
    set lines {}
    foreach line [split $output \n] {
        if {[string match {*NOT REFUSED*} $line]
            || [string match {*should not have*} $line]} {
            lappend lines [string trim $line]
        }
    }
    return $lines
}

# The read-time half: how many refusals a file demonstrates, and how many
# success branches it carries. Comment lines are left out (a comment may name
# a call it is not making), and so is the capability probe form.
proc branches {code} {
    set demonstrations 0
    set answers 0
    foreach line [split $code \n] {
        if {[string match "#*" [string trimleft $line]]} { continue }
        if {[string match {*NOT REFUSED*} $line]
            || [string match {*should not have*} $line]} {
            incr answers
            continue
        }
        incr demonstrations [regexp -all {(?:^|[^A-Za-z0-9_])catch[^A-Za-z0-9_]} $line]
        incr demonstrations [regexp -all {(?:^|[^A-Za-z0-9_])try\s*\{} $line]
        incr demonstrations -[regexp -all {catch\s*\{\s*package\s+require} $line]
    }
    return [list $demonstrations $answers]
}

set tclsh [info nameofexecutable]
foreach path $files {
    set code [snippets $path]
    if {$code eq {}} { skip "[file tail $path]: no tcl block"; continue }
    lassign [branches $code] demonstrations answers
    if {$demonstrations != $answers} {
        fail "[file tail $path]: $demonstrations refusal demonstration(s)\
            (catch/try) but $answers success branch(es) - every catch or try\
            that shows a refusal needs the branch that prints NOT REFUSED\
            when the call goes through, or the demonstration is silent"
    }
    set script [file join $scripts "check-[file rootname [file tail $path]].tcl"]
    set channel [open $script w]
    fconfigure $channel -encoding utf-8
    # Every script starts from the same assets; the auto_path is the caller's,
    # taken over as it is rather than appended, so that no directory stands
    # in it twice - assets.tcl then puts the source tree in front.
    puts $channel "set auto_path [list $auto_path]"
    puts $channel "source [list $assetsFile]"
    puts $channel $code
    close $channel
    if {[catch {exec $tclsh $script 2>@1} output]} {
        fail "[file tail $path]\n[string trimright $output]"
    } elseif {[llength [set stood [unrefused $output]]]} {
        fail "[file tail $path]: [llength $stood] call(s) the snippet expected\
            to be refused went through\n[join $stood \n]"
    } else {
        pass "[file tail $path] ([llength [split [string trim $output] \n]] lines of output)"
    }
}

# -- 2. qpdf over everything that came out ------------------------------------

set pdfs [lsort [glob -nocomplain -directory $out ref-*.pdf]]
if {![llength $pdfs]} { fail "no ref-*.pdf in $out" }
if {[have qpdf]} {
    set bad {}
    foreach f $pdfs {
        # qpdf has ONE warning that is tolerated here: ISO 32000-2 Table 20 allows /Length
        # in the encryption dictionary "only if V is 2 or 3" and deprecates it
        # in 2.0, so a revision 6 document does not carry it - qpdf reads the
        # entry unconditionally anyway and warns. Every other complaint fails.
        if {[catch {exec qpdf --check $f} output]} {
            set left {}
            foreach line [split $output \n] {
                if {[string match "WARNING:*" $line]
                    && ![string match "*dictionary key /Length*" $line]} {
                    lappend left $line
                }
            }
            if {[llength $left]} { lappend bad [file tail $f] }
        }
    }
    if {[llength $bad]} { fail "qpdf: $bad" } else { pass "qpdf: no complaint on [llength $pdfs] documents" }
} else {
    skip "qpdf not installed"
}

# -- 3. veraPDF, each document against what it claims -------------------------

proc claims {f} {
    set channel [open $f rb]
    set bytes [read $channel]
    close $channel
    set result {}
    if {[regexp {pdfaid:part(?:="|>)(\d)} $bytes -> part]} {
        set conf b
        regexp {pdfaid:conformance(?:="|>)([A-Z])} $bytes -> conf
        lappend result [string tolower $part$conf]
    }
    if {[regexp {pdfuaid:part(?:="|>)(\d)} $bytes -> part]} {
        lappend result ua$part
    }
    return $result
}
if {[have verapdf]} {
    foreach f $pdfs {
        foreach flavour [claims $f] {
            catch {exec verapdf -f $flavour $f 2>/dev/null} output
            if {[regexp {failedChecks="(\d+)"} $output -> n] && $n == 0} {
                pass "veraPDF -f $flavour [file tail $f]"
            } else {
                fail "veraPDF -f $flavour [file tail $f]: [expr {[info exists n] ? "$n failed checks" : "no answer"}]"
            }
            unset -nocomplain n
        }
    }
} else {
    skip "verapdf not installed"
}

puts "---- failed $failed, skipped $skipped"
exit [expr {$failed ? 1 : 0}]
