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
proc exampleFooter {doc {family {}} {colour {0.45 0.45 0.5}}} {
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
    # The colour is a parameter for one reason: a document under a CMYK
    # output intent (05.09) may not paint DeviceRGB, footer included.
    $doc font -size 6 -color $colour
    # -tag Artifact: a footer is a fact about the sheet, not about the text,
    # and in a tagged document it has to say so or a reader announces it as
    # content. Harmless everywhere else - an untagged document ignores it.
    $doc text "$script - $fonts" \
        -at [list [expr {$width - 10}] [expr {$height - 7}]] -align right \
        -tag Artifact
}

# What an archivable example reports when it is done: the level it declared
# and the faces the file carries.
#
# Both are read back OUT of the document rather than repeated from the script
# above, so the line cannot claim a conformance the file does not have or a
# font it does not carry - the same reason the footer asks the document for
# its fonts.
proc exampleArchival {doc} {
    set state [$doc pdfa state]
    return "PDF/A-[dict get $state part][dict get $state conformance],\
        fonts: [join [$doc font names] {, }]"
}

# The closing lines of an ARCHIVABLE example: footer, write, and the two
# console lines that say what came out.
#
# Only for the PDF/A ones - the others end with a plain [write] and have
# nothing to report beyond the file name. Pulled out when the third example
# had the same seven lines; [exampleArchival] alone was not enough, because
# what repeated was the whole ending.
proc exampleDone {doc target {family {}} {colour {0.45 0.45 0.5}}} {
    exampleFooter $doc $family $colour
    $doc write $target
    puts "  written: $target"
    puts "  [exampleArchival $doc]"
    $doc destroy
}
