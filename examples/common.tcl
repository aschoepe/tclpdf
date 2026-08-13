#
# tclpdf examples - the one thing every example does the same way
#
#   source [file join $here common.tcl]
#   ...
#   exampleFooter $doc ?family?
#
# Every example puts the same footer on its last page, and for a while every
# example carried its own copy of it. Eighteen copies of ten lines is how a
# block starts drifting: one gets a fix, the others do not, and nobody notices
# because each file on its own still looks right. So it lives here once.
#
# The price is that an example is no longer a single file you can lift out of
# the tree and run. That is the trade, made knowingly - the assets next door
# are needed just as much, so an example was never self-contained anyway.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

# Draw the footer: which script drew the page, and which font is in the file.
#
# Both are read back OUT OF THE DOCUMENT rather than passed in, so the footer
# cannot claim a face the file does not carry. A page that turns up on a desk
# months later then answers the two questions it otherwise cannot: where does
# this come from, and is the type embedded or a standard face.
#
# The family is left alone by default, because a PDF/A document may not fall
# back to Helvetica and an example ending on an embedded face must keep it.
# Pass one where the page ends on a face that cannot set the footer - a symbol
# font, or one without the punctuation the line needs.
proc exampleFooter {doc {family {}}} {
    # [info script] inside a proc reports the file being sourced right now,
    # which by the time this runs is the example again - common.tcl is long
    # finished. Checked under both interpreters; without that it would name
    # this file in every footer.
    set script [file tail [info script]]

    set fonts {}
    foreach alias [$doc font names] {
        lappend fonts [dict get [$doc font info $alias] family]
    }
    # An "if", not an "expr": expr normalises what it returns, and a value that
    # only looks like a number comes back changed. That cost this package a
    # defect once already, in the line breaker.
    if {[llength $fonts]} {
        set fonts "embedded: [join [lsort -unique $fonts] {, }]"
    } else {
        set fonts "standard faces, nothing embedded"
    }

    lassign [$doc page size] width height
    if {$family ne {}} {
        $doc font -family $family -style {}
    }
    $doc font -size 6 -color {0.45 0.45 0.5}
    # -tag Artifact: a footer is a fact about the sheet, not about the text,
    # and in a tagged document it has to say so or a reader announces it as
    # content. Harmless everywhere else - an untagged document ignores it.
    $doc text "$script - $fonts" \
        -at [list [expr {$width - 10}] [expr {$height - 7}]] -align right \
        -tag Artifact
}
