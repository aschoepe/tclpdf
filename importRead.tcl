#
# tclpdf - PDF generation for Tcl
#
# importRead - reading an existing PDF file: tokenizer, cross-reference
#              chain, objects, streams, page geometry
#
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
##
# INFRASTRUCTURE, NOT A TOPIC. Three topics stand on this reader and none of
# them on each other: import.tcl takes a page over as a form, importInfo.tcl
# answers what a file says about itself, and update.tcl appends to a finished
# file. Before 2026-08-21 all of this lived in import.tcl, so update.tcl and
# sign.tcl had to "package require tclpdf::import" to reach the reader - a
# topic requiring a topic, and one that dragged the page takeover along with
# it for callers that never wanted it.
#
# What belongs here is everything that answers "what does this file say", and
# nothing that answers "what shall this document become".
#
package require Tcl 8.6.11-
package require tclpdf::filter 1.0-
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::importRead {}

# ---------------------------------------------------------------- tokenizer
#
# A parsed object is a two-element list {type payload}:
#   d {key value ...}   dictionary, keys as plain text without the slash
#   a {value ...}       array
#   n text              number, kept as written
#   r {num gen}         indirect reference
#   nm bytes            name, #xx escapes DECODED (7.3.5.2)
#   s bytes             literal string, DECODED bytes
#   h hextext           hex string, digits as written
#   b true|false        boolean
#   z {}                null
# Keeping numbers as written means a copied object round-trips
# byte-comparably. Names and strings are decoded: strings because their
# escapes must be understood to find the closing parenthesis at all, names
# because every Get compares plain text - /Ro#74ate IS /Rotate (7.3.5.2).
# Serialize re-escapes both on the way out.

# White space is the six bytes of Table 1 (7.2.2) - and ONLY those. Tcl's
# [string is space] is Unicode-wide: a raw 0xA0 or 0x85 byte would count as
# space and split a legal name in the middle.
proc ::tclpdf::importRead::SkipWs {bytes posVar} {
    upvar 1 $posVar pos
    set length [string length $bytes]
    while {$pos < $length} {
        set c [string index $bytes $pos]
        if {$c eq " " || $c eq "\n" || $c eq "\r" || $c eq "\t"
                || $c eq "\f" || $c eq "\x00"} {
            incr pos
        } elseif {$c eq "%"} {
            # A comment runs to the end of the line (7.2.4). Spelled with
            # two compares: CR, space and LF as a "list" of characters is
            # the EMPTY list - they are nothing but separators.
            while {$pos < $length} {
                set d [string index $bytes $pos]
                if {$d eq "\r" || $d eq "\n"} {
                    break
                }
                incr pos
            }
        } else {
            return
        }
    }
}

# The characters that end a name, a number or a keyword (7.2.3): the six
# white-space bytes of Table 1 and the delimiters - see SkipWs for why not
# [string is space].
proc ::tclpdf::importRead::Delimiter {c} {
    return [expr {$c eq {} || $c eq " " || $c eq "\n" || $c eq "\r"
        || $c eq "\t" || $c eq "\f" || $c eq "\x00"
        || $c in {( ) < > \[ \] \{ \} / %}}]
}

proc ::tclpdf::importRead::ParseString {bytes posVar} {
    upvar 1 $posVar pos
    incr pos
    set out {}
    set depth 1
    while 1 {
        set c [string index $bytes $pos]
        if {$c eq {}} {
            return -code error -errorcode {TCLPDF IMPORT SYNTAX} \
                "tclpdf: unterminated string in imported PDF"
        }
        incr pos
        switch -- $c {
            ( {incr depth; append out (}
            ) {
                incr depth -1
                if {$depth == 0} {
                    return $out
                }
                append out )
            }
            \\ {
                set e [string index $bytes $pos]
                incr pos
                switch -- $e {
                    n {append out \n}
                    r {append out \r}
                    t {append out \t}
                    b {append out \b}
                    f {append out \f}
                    ( {append out (}
                    ) {append out )}
                    \\ {append out \\}
                    \n {}
                    \r {
                        if {[string index $bytes $pos] eq "\n"} {incr pos}
                    }
                    default {
                        if {[string match {[0-7]} $e]} {
                            set octal $e
                            foreach - {1 2} {
                                set d [string index $bytes $pos]
                                if {[string match {[0-7]} $d]} {
                                    append octal $d
                                    incr pos
                                }
                            }
                            append out [format %c [scan $octal %o]]
                        } else {
                            append out $e
                        }
                    }
                }
            }
            default {append out $c}
        }
    }
}

proc ::tclpdf::importRead::ParseToken {bytes posVar} {
    upvar 1 $posVar pos
    set start $pos
    while {![Delimiter [string index $bytes $pos]]} {
        incr pos
    }
    return [string range $bytes $start [expr {$pos - 1}]]
}

# One object, starting at pos; pos ends up behind it. keywordVar receives a
# bare keyword (obj, endobj, stream, R ...) when one is met instead of an
# object - the callers that expect one look at it, everyone else treats it
# as an error.
#
# "depth" guards the recursion. Arrays and dictionaries nest, so a value
# built entirely of open brackets recurses once per bracket, and a hostile
# file can drive that past Tcl's own recursion limit - the raw "too many
# nested evaluations" is not a named refusal. The cap sits well below that
# limit (measured: Parse reaches ~900 levels before Tcl stops it) and far
# above any nesting a real document carries, and Serialize/Refs walk the
# same structure, so capping the depth here caps all three.
proc ::tclpdf::importRead::Parse {bytes posVar {depth 0}} {
    upvar 1 $posVar pos
    if {$depth > 500} {
        return -code error -errorcode {TCLPDF IMPORT DEPTH} "tclpdf: imported\
            PDF nests arrays or dictionaries deeper than this reader follows"
    }
    SkipWs $bytes pos
    set c [string index $bytes $pos]
    switch -glob -- $c {
        ( {return [list s [ParseString $bytes pos]]}
        / {
            incr pos
            set raw [ParseToken $bytes pos]
            # #xx decodes to its byte (7.3.5.2); a # NOT followed by two
            # hex digits stays literal - broken files exist, and reading
            # them as written loses less than refusing.
            if {[string first # $raw] >= 0} {
                set name {}
                set i 0
                set length [string length $raw]
                while {$i < $length} {
                    set c [string index $raw $i]
                    set hex [string range $raw [expr {$i + 1}] \
                        [expr {$i + 2}]]
                    if {$c eq "#" && [string length $hex] == 2
                            && [string is xdigit -strict $hex]} {
                        append name [format %c [scan $hex %x]]
                        incr i 3
                    } else {
                        append name $c
                        incr i
                    }
                }
                set raw $name
            }
            return [list nm $raw]
        }
        {\[} {
            incr pos
            set items {}
            while 1 {
                SkipWs $bytes pos
                set c [string index $bytes $pos]
                if {$c eq "\]"} {
                    incr pos
                    return [list a $items]
                }
                # A truncated or corrupt array never meets its "]": at the end
                # of the file, or before a delimiter that ParseToken cannot
                # consume, pos would stop moving and lappend would run without
                # bound. Refuse by name rather than loop.
                if {$c eq {}} {
                    return -code error -errorcode {TCLPDF IMPORT SYNTAX} \
                        "tclpdf: unterminated array in imported PDF"
                }
                set before $pos
                set item [Parse $bytes pos [expr {$depth + 1}]]
                if {$pos == $before} {
                    return -code error -errorcode {TCLPDF IMPORT SYNTAX} \
                        "tclpdf: array in imported PDF holds an unreadable\
                        token"
                }
                lappend items $item
            }
        }
        < {
            if {[string index $bytes [expr {$pos + 1}]] eq "<"} {
                incr pos 2
                set pairs {}
                while 1 {
                    SkipWs $bytes pos
                    if {[string index $bytes $pos] eq {}} {
                        return -code error -errorcode {TCLPDF IMPORT SYNTAX} \
                            "tclpdf: unterminated dictionary in imported PDF"
                    }
                    if {[string range $bytes $pos [expr {$pos + 1}]] eq ">>"} {
                        incr pos 2
                        return [list d $pairs]
                    }
                    set key [Parse $bytes pos [expr {$depth + 1}]]
                    if {[lindex $key 0] ne "nm"} {
                        return -code error -errorcode {TCLPDF IMPORT SYNTAX} \
                            "tclpdf: dictionary key is not a name in imported\
                            PDF"
                    }
                    lappend pairs [lindex $key 1] \
                        [Parse $bytes pos [expr {$depth + 1}]]
                }
            }
            incr pos
            set start $pos
            while {[string index $bytes $pos] ne ">"} {
                incr pos
                if {$pos >= [string length $bytes]} {
                    return -code error -errorcode {TCLPDF IMPORT SYNTAX} \
                        "tclpdf: unterminated hex string in imported PDF"
                }
            }
            set hex [string range $bytes $start [expr {$pos - 1}]]
            incr pos
            return [list h $hex]
        }
        {[-+.0-9]} {
            set number [ParseToken $bytes pos]
            # "num gen R" is one object; the lookahead is undone when the
            # two following tokens are not "gen R".
            if {[string is entier -strict $number]} {
                set mark $pos
                SkipWs $bytes pos
                if {[string match {[0-9]} [string index $bytes $pos]]} {
                    set gen [ParseToken $bytes pos]
                    SkipWs $bytes pos
                    if {[string is entier -strict $gen]
                            && [string index $bytes $pos] eq "R"
                            && [Delimiter [string index $bytes \
                                [expr {$pos + 1}]]]} {
                        incr pos
                        return [list r [list $number $gen]]
                    }
                }
                set pos $mark
            }
            return [list n $number]
        }
        default {
            set word [ParseToken $bytes pos]
            switch -- $word {
                true {return {b true}}
                false {return {b false}}
                null {return {z {}}}
                default {return [list k $word]}
            }
        }
    }
}

# ------------------------------------------------------------- serializing

# A name written back: every byte outside the regular range becomes a #xx
# escape (7.3.5.2) - the delimiters, #, and anything below 0x21 or above
# 0x7E, which covers the six white-space bytes.
proc ::tclpdf::importRead::EscapeName {name} {
    set out {}
    foreach c [split $name {}] {
        scan $c %c code
        if {$code < 0x21 || $code > 0x7E || $c eq "#"
                || $c in {( ) < > \[ \] \{ \} / %}} {
            append out [format #%02X $code]
        } else {
            append out $c
        }
    }
    return $out
}

# Writes a parsed object back as PDF syntax; every reference is renumbered
# through the map (old number -> new number). A reference to an object that
# was never copied names itself - it means the closure walk has a hole.
proc ::tclpdf::importRead::Serialize {value map {depth 0}} {
    if {$depth > 500} {
        return -code error -errorcode {TCLPDF IMPORT DEPTH} "tclpdf: imported\
            object nests deeper than this reader serializes"
    }
    lassign $value type payload
    switch -- $type {
        d {
            set out "<<"
            foreach {key item} $payload {
                append out " /" [EscapeName $key] " " \
                    [Serialize $item $map [expr {$depth + 1}]]
            }
            append out " >>"
            return $out
        }
        a {
            set out "\["
            foreach item $payload {
                append out " " [Serialize $item $map [expr {$depth + 1}]]
            }
            append out " \]"
            return $out
        }
        n {return $payload}
        nm {return "/[EscapeName $payload]"}
        h {return "<$payload>"}
        b {return $payload}
        z {return "null"}
        s {
            set out {}
            foreach c [split $payload {}] {
                scan $c %c code
                if {$c in {( ) \\}} {
                    append out \\ $c
                } elseif {$code < 32 || $code > 126} {
                    append out [format {\%03o} $code]
                } else {
                    append out $c
                }
            }
            return "($out)"
        }
        r {
            lassign $payload number -
            if {![dict exists $map $number]} {
                return -code error \
                    -errorcode {TCLPDF IMPORT SERIALIZE} "tclpdf: reference\
                    to object $number, which the import never reached"
            }
            return "[dict get $map $number] 0 R"
        }
        default {
            return -code error -errorcode {TCLPDF IMPORT SERIALIZE} \
                "tclpdf: cannot serialize \"$type\""
        }
    }
}

# All object numbers a parsed value refers to.
proc ::tclpdf::importRead::Refs {value {depth 0}} {
    if {$depth > 500} {
        return -code error -errorcode {TCLPDF IMPORT DEPTH} "tclpdf: imported\
            object nests deeper than this reader walks for references"
    }
    lassign $value type payload
    switch -- $type {
        r {return [list [lindex $payload 0]]}
        d {
            set found {}
            foreach {- item} $payload {
                lappend found {*}[Refs $item [expr {$depth + 1}]]
            }
            return $found
        }
        a {
            set found {}
            foreach item $payload {
                lappend found {*}[Refs $item [expr {$depth + 1}]]
            }
            return $found
        }
        default {return {}}
    }
}

proc ::tclpdf::importRead::Get {value key} {
    lassign $value type payload
    if {$type ne "d" || ![dict exists $payload $key]} {
        return {}
    }
    return [dict get $payload $key]
}

proc ::tclpdf::importRead::Put {valueVar key item} {
    upvar 1 $valueVar value
    lassign $value type payload
    dict set payload $key $item
    set value [list d $payload]
}

# ------------------------------------------------------------------ reader
#
# The reader handle is a dict in the caller's variable:
#   bytes     the whole file
#   path      for error messages
#   startxref the offset the chain started at - the newest section
#   sections  every offset of the /Prev chain, newest first
#   flavour   table|stream, how the NEWEST section is written
#   xref      num -> {o offset} | {c objstmNum indexInStream}
#   trailer   the merged trailer/xref-stream dictionary (parsed)
#   objects   cache num -> {value hasStream data}
#   buffers   cache of decoded object stream payloads

# "tolerateEncrypted" is for the one caller that has to REPORT encryption
# rather than refuse it - [::tclpdf::pdf info] at the end of this file, which
# answers what an encrypted file still says about itself out of its trailer
# and its cross-reference. Everything else keeps the refusal, and the default
# is the refusal: an import or an update that got a reader for an encrypted
# file would produce a document made of cipher text.
proc ::tclpdf::importRead::Open {path {tolerateEncrypted 0}} {
    set channel [open $path rb]
    set bytes [read $channel]
    close $channel
    set reader [dict create bytes $bytes path $path xref {} \
        trailer {d {}} objects {} buffers {} sections {} flavour {} \
        inprogress {}]
    if {![regexp {startxref\s+(\d+)\s+%%EOF\s*$} \
            [string range $bytes end-1023 end] -> offset]} {
        return -code error -errorcode {TCLPDF IMPORT FILE} "tclpdf: $path\
            carries no startxref - not a PDF, or a truncated one"
    }
    # Where the newest cross-reference section is. Kept in the reader
    # because a second consumer needs it and must not look for it a second
    # time: update.tcl writes an incremental update whose trailer carries a
    # /Prev naming the previous section (7.5.6), and that has to be the very
    # offset this reader started its chain at - two searches that could
    # disagree would put a /Prev where nothing was read.
    dict set reader startxref $offset
    set seen {}
    while {$offset ne {}} {
        if {[dict exists $seen $offset]} {
            return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf: $path:\
                circular cross-reference chain"
        }
        dict set seen $offset 1
        # Every section of the chain is kept, newest first: how many there
        # are is how often the file was written on (7.5.6), and that is a
        # fact about the file that only this walk knows.
        dict lappend reader sections $offset
        set offset [Section reader $offset]
    }
    if {!$tolerateEncrypted && [Get [dict get $reader trailer] Encrypt] ne {}} {
        return -code error -errorcode {TCLPDF IMPORT ENCRYPTED} "tclpdf: $path\
            is encrypted - encrypted files are not imported"
    }
    return $reader
}

# The /Prev of a trailer, validated as the byte offset it has to be: an
# integer of zero or more (Table 15). A string, name or real would otherwise
# travel on as an offset and blow up as a raw Tcl index or arithmetic error.
proc ::tclpdf::importRead::PrevOffset {readerVar previous} {
    upvar 1 $readerVar reader
    if {$previous eq {}} {
        return {}
    }
    set offset [lindex $previous 1]
    if {[lindex $previous 0] ne "n" || ![string is entier -strict $offset]
            || $offset < 0} {
        return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
            [dict get $reader path]: /Prev is not a byte offset"
    }
    return $offset
}

# One cross-reference section, classic or stream; returns the /Prev offset
# or the empty string. Entries never overwrite existing ones - the chain
# runs newest first, and the newest section wins (7.5.6).
proc ::tclpdf::importRead::Section {readerVar offset} {
    upvar 1 $readerVar reader
    set bytes [dict get $reader bytes]
    set pos $offset
    SkipWs $bytes pos
    set classic [expr {[string range $bytes $pos [expr {$pos + 3}]] eq "xref"}]
    # Which flavour the NEWEST section is written in - the first one this
    # walk meets, and the only one a reader has to understand to open the
    # file at all. The hybrid case (7.5.8.4) reaches StreamSection past this
    # proc, so a hybrid file keeps the "table" its newest section is.
    if {[dict get $reader flavour] eq {}} {
        dict set reader flavour [expr {$classic ? "table" : "stream"}]
    }
    if {$classic} {
        return [ClassicSection reader [expr {$pos + 4}]]
    }
    return [StreamSection reader $pos]
}

proc ::tclpdf::importRead::ClassicSection {readerVar pos} {
    upvar 1 $readerVar reader
    set bytes [dict get $reader bytes]
    while 1 {
        SkipWs $bytes pos
        if {[string range $bytes $pos [expr {$pos + 6}]] eq "trailer"} {
            incr pos 7
            set trailer [Parse $bytes pos]
            Merge reader $trailer
            set previous [Get $trailer Prev]
            # A hybrid file (7.5.8.4) hides the stream entries behind
            # /XRefStm; they complete this section and take precedence
            # over /Prev in reading order.
            set hybrid [Get $trailer XRefStm]
            if {$hybrid ne {}} {
                StreamSection reader [lindex $hybrid 1]
            }
            return [PrevOffset reader $previous]
        }
        set first [ParseToken $bytes pos]
        SkipWs $bytes pos
        set count [ParseToken $bytes pos]
        if {![string is entier -strict $first] || $first < 0
                || ![string is entier -strict $count] || $count < 0} {
            return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
                [dict get $reader path]: unreadable cross-reference line at\
                $pos"
        }
        # A subsection promises "count" entries of twenty bytes each; a count
        # that would run past the end of the file is corrupt (or hostile), and
        # walking it drives "string range" onto an out-of-range index with a
        # raw Tcl message. Reject it against the bytes that remain.
        if {$count > ([string length $bytes] - $pos) / 20} {
            return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
                [dict get $reader path]: cross-reference subsection at $pos\
                promises $count entries, more than the file can hold"
        }
        SkipWs $bytes pos
        for {set i 0} {$i < $count} {incr i} {
            set entry [string range $bytes $pos [expr {$pos + 19}]]
            set kind [string index $entry 17]
            if {$kind eq "n"} {
                Enter reader [expr {$first + $i}] \
                    [list o [scan [string range $entry 0 9] %d]]
            } elseif {$kind eq "f"} {
                # A free entry is recorded, not skipped: the newest section
                # wins (7.5.6), so an object freed by an incremental update
                # (7.5.4) must shadow the live entry an older section still
                # carries - otherwise the withdrawn object comes back to life.
                Enter reader [expr {$first + $i}] f
            }
            incr pos 20
        }
    }
}

proc ::tclpdf::importRead::StreamSection {readerVar pos} {
    upvar 1 $readerVar reader
    set bytes [dict get $reader bytes]
    lassign [ObjectAt reader $pos] value hasStream data
    if {!$hasStream || [lindex [Get $value Type] 1] ne "XRef"} {
        return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
            [dict get $reader path]: no cross-reference at offset $pos"
    }
    set data [DecodeStream reader $value $data "cross-reference stream"]
    # /W is required and lists exactly three non-negative field widths
    # (7.5.8.2, Table 17). Missing or short, the field arithmetic below runs
    # on empty operands with a raw Tcl error; all-zero, it encodes nothing
    # and would enter one bogus entry per object.
    set wval [Get $value W]
    if {[lindex $wval 0] ne "a" || [llength [lindex $wval 1]] != 3} {
        return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
            [dict get $reader path]: cross-reference stream at $pos has no\
            usable /W - three field widths are required"
    }
    set w {}
    foreach item [lindex $wval 1] {
        set width [lindex $item 1]
        if {[lindex $item 0] ne "n" || ![string is entier -strict $width]
                || $width < 0} {
            return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
                [dict get $reader path]: cross-reference stream at $pos has a\
                /W field width that is not a non-negative integer"
        }
        lappend w $width
    }
    lassign $w w0 w1 w2
    set record [expr {$w0 + $w1 + $w2}]
    if {$record == 0} {
        return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
            [dict get $reader path]: cross-reference stream at $pos has\
            /W \[0 0 0\], which encodes nothing"
    }
    # /Index is a list of {first count} pairs, and /Size stands in for it
    # where it is absent (7.5.8.2, Table 17). Every one of those numbers has
    # to be a non-negative integer: Tcl compares a non-numeric operand as a
    # STRING, so a count spelt /Foo makes "$i < $count" true for every $i and
    # the entry loop below never ends - measured, not feared.
    set indexValue [Get $value Index]
    set index {}
    if {$indexValue ne {}} {
        if {[lindex $indexValue 0] ne "a"
                || [llength [lindex $indexValue 1]] % 2} {
            return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
                [dict get $reader path]: cross-reference stream at $pos has\
                an /Index that is not pairs of numbers"
        }
        foreach item [lindex $indexValue 1] {
            lappend index [lindex $item 1]
        }
    } else {
        set index [list 0 [lindex [Get $value Size] 1]]
    }
    foreach number $index {
        if {![string is entier -strict $number] || $number < 0} {
            return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
                [dict get $reader path]: cross-reference stream at $pos names\
                a subsection start or count that is not a non-negative\
                integer"
        }
    }
    # The decoded stream must hold one "record" of bytes for every entry the
    # /Index announces. Too short, "binary scan" over an exhausted string
    # leaves "byte" at its previous value and the reader reports offsets that
    # are silently wrong - refuse instead of guessing.
    set entries 0
    foreach {- count} $index {
        incr entries $count
    }
    if {[string length $data] < $entries * $record} {
        return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
            [dict get $reader path]: cross-reference stream at $pos is shorter\
            than its /W and /Index require"
    }
    set at 0
    foreach {first count} $index {
        for {set i 0} {$i < $count} {incr i} {
            set fields {}
            foreach width [list $w0 $w1 $w2] {
                set field 0
                for {set k 0} {$k < $width} {incr k} {
                    binary scan [string index $data $at] cu byte
                    set field [expr {($field << 8) | $byte}]
                    incr at
                }
                lappend fields $field
            }
            lassign $fields type f2 f3
            if {$w0 == 0} {
                set type 1
            }
            switch -- $type {
                0 {
                    # Type 0 is a free entry (7.5.8.3); it is recorded, not
                    # skipped, so it shadows a live entry an older section
                    # carries for the same object - the free-object counterpart
                    # of the classic 'f' line above.
                    Enter reader [expr {$first + $i}] f
                }
                1 {Enter reader [expr {$first + $i}] [list o $f2]}
                2 {Enter reader [expr {$first + $i}] [list c $f2 $f3]}
            }
        }
    }
    Merge reader $value
    return [PrevOffset reader [Get $value Prev]]
}

proc ::tclpdf::importRead::Enter {readerVar number entry} {
    upvar 1 $readerVar reader
    if {![dict exists $reader xref $number]} {
        dict set reader xref $number $entry
    }
}

# Trailer keys merge the same way the entries do: the first (= newest)
# occurrence wins.
proc ::tclpdf::importRead::Merge {readerVar trailer} {
    upvar 1 $readerVar reader
    lassign [dict get $reader trailer] - have
    foreach {key item} [lindex $trailer 1] {
        if {![dict exists $have $key]} {
            dict set have $key $item
        }
    }
    dict set reader trailer [list d $have]
}

# The object at a byte offset: value, stream flag, raw stream bytes. When
# "expect" names the number the cross-reference promised at this offset, the
# "num gen obj" header is checked against it: an offset that lands on a
# different object is a corrupt (or forged) cross-reference, and reading the
# wrong object there is the silent-wrong-answer this reader refuses (7.5.4).
proc ::tclpdf::importRead::ObjectAt {readerVar offset {expect {}}} {
    upvar 1 $readerVar reader
    set bytes [dict get $reader bytes]
    set pos $offset
    SkipWs $bytes pos
    set found [ParseToken $bytes pos]
    SkipWs $bytes pos
    ParseToken $bytes pos
    SkipWs $bytes pos
    if {[ParseToken $bytes pos] ne "obj"} {
        return -code error -errorcode {TCLPDF IMPORT OBJECT} "tclpdf:\
            [dict get $reader path]: no object at offset $offset"
    }
    if {$expect ne {} && $found ne $expect} {
        return -code error -errorcode {TCLPDF IMPORT OBJECT} "tclpdf:\
            [dict get $reader path]: the cross-reference points object $expect\
            at offset $offset, where object $found is written"
    }
    set value [Parse $bytes pos]
    SkipWs $bytes pos
    if {[string range $bytes $pos [expr {$pos + 5}]] ne "stream"} {
        return [list $value 0 {}]
    }
    incr pos 6
    if {[string index $bytes $pos] eq "\r"} {incr pos}
    if {[string index $bytes $pos] eq "\n"} {incr pos}
    set length [Get $value Length]
    if {[lindex $length 0] eq "r"} {
        set length [lindex [Object reader \
            [lindex [lindex $length 1] 0]] 0]
    }
    set length [lindex $length 1]
    if {![string is entier -strict $length]} {
        return -code error -errorcode {TCLPDF IMPORT STREAM} "tclpdf:\
            [dict get $reader path]: stream at offset $offset has no usable\
            /Length"
    }
    set data [string range $bytes $pos [expr {$pos + $length - 1}]]
    # /Length must land exactly on the end of the data: behind it, after an
    # optional end-of-line, the keyword endstream follows (7.3.8.1). A wrong
    # length silently turns neighbouring bytes into stream data or stream
    # data into operators - refusing beats guessing.
    set tail [expr {$pos + $length}]
    if {[string index $bytes $tail] eq "\r"} {incr tail}
    if {[string index $bytes $tail] eq "\n"} {incr tail}
    if {[string range $bytes $tail [expr {$tail + 8}]] ne "endstream"} {
        return -code error -errorcode {TCLPDF IMPORT STREAM} "tclpdf:\
            [dict get $reader path]: the stream at offset $offset declares\
            /Length $length but does not end at endstream"
    }
    return [list $value 1 $data]
}

# The object by number, through the cross-reference - directly stored or
# inside an object stream (7.5.7; those never hold streams themselves).
proc ::tclpdf::importRead::Object {readerVar number} {
    upvar 1 $readerVar reader
    if {[dict exists $reader objects $number]} {
        return [dict get $reader objects $number]
    }
    if {![dict exists $reader xref $number]} {
        return -code error -errorcode {TCLPDF IMPORT OBJECT} "tclpdf:\
            [dict get $reader path]: object $number is referenced but not in\
            the cross-reference"
    }
    # An object being read must not, directly or through an object stream,
    # ask to be read again: a /Length that refers to its own stream object,
    # or an object stream that names itself as its own container, would
    # otherwise recurse until Tcl's stack gives out (7.3.8.2, 7.5.7). The
    # marker is set for the whole resolution and comes off again below; a
    # legitimate second reference hits the cache above and never re-enters
    # here.
    if {[dict exists $reader inprogress $number]} {
        return -code error -errorcode {TCLPDF IMPORT RECURSION} "tclpdf:\
            [dict get $reader path]: object $number refers to itself"
    }
    dict set reader inprogress $number 1
    set entry [dict get $reader xref $number]
    # The marker comes off whichever way this leaves, refusal included: a
    # caller that catches one refusal and asks for the same object again
    # would otherwise be told it refers to itself.
    try {
        switch -- [lindex $entry 0] {
            o {
                set object [ObjectAt reader [lindex $entry 1] $number]
            }
            f {
                # A freed object resolves to null (7.3.10): a reference to an
                # object the file does not define is the null object, never
                # the stale bytes an older cross-reference section pointed at.
                set object [list {z {}} 0 {}]
            }
            c {
                lassign $entry - container index
                if {![dict exists $reader buffers $container]} {
                    lassign [Object reader $container] value hasStream data
                    if {!$hasStream} {
                        return -code error -errorcode {TCLPDF IMPORT OBJSTM} \
                            "tclpdf: [dict get $reader path]: object stream\
                            $container has no stream"
                    }
                    set data [DecodeStream reader $value $data "object stream"]
                    # /N and /First are required integers (7.5.7, Table 16).
                    # Without them the header walk below runs "2 * $n" and
                    # "$first + ..." on names or on nothing and dies with a
                    # raw Tcl message naming an operand instead of the file.
                    set n [lindex [Resolve reader [Get $value N]] 1]
                    set first [lindex [Resolve reader [Get $value First]] 1]
                    if {![string is entier -strict $n] || $n < 0
                            || ![string is entier -strict $first]
                            || $first < 0} {
                        return -code error -errorcode {TCLPDF IMPORT OBJSTM} \
                            "tclpdf: [dict get $reader path]: object stream\
                            $container has no usable /N and /First"
                    }
                    dict set reader buffers $container [list $data $first $n]
                }
                lassign [dict get $reader buffers $container] data first n
                # The cross-reference says object "number" is the index-th of
                # the stream; a stream of n objects has none beyond n - 1, and
                # asking for one reads an empty offset out of the header.
                if {![string is entier -strict $index] || $index < 0
                        || $index >= $n} {
                    return -code error -errorcode {TCLPDF IMPORT OBJSTM} \
                        "tclpdf: [dict get $reader path]: object $number is\
                        said to be number $index of object stream $container,\
                        which holds $n"
                }
                set pos 0
                set header {}
                for {set i 0} {$i < 2 * $n} {incr i} {
                    SkipWs $data pos
                    lappend header [ParseToken $data pos]
                }
                set offset [lindex $header [expr {2 * $index + 1}]]
                if {![string is entier -strict $offset] || $offset < 0} {
                    return -code error -errorcode {TCLPDF IMPORT OBJSTM} \
                        "tclpdf: [dict get $reader path]: the header of\
                        object stream $container carries no offset for\
                        object $number"
                }
                set pos [expr {$first + $offset}]
                set object [list [Parse $data pos] 0 {}]
            }
        }
    } finally {
        dict unset reader inprogress $number
    }
    dict set reader objects $number $object
    return $object
}

# Follows a reference; hands a direct value through unchanged.
proc ::tclpdf::importRead::Resolve {readerVar value} {
    upvar 1 $readerVar reader
    if {[lindex $value 0] eq "r"} {
        return [lindex [Object reader [lindex [lindex $value 1] 0]] 0]
    }
    return $value
}

# --------------------------------------------------------------- decoding
#
# Only what the import itself must read is decoded: cross-reference
# streams, object streams, and the page's content streams. Everything
# else is copied byte for byte with its /Filter untouched.

proc ::tclpdf::importRead::DecodeStream {readerVar value data what} {
    upvar 1 $readerVar reader
    set filters {}
    set filter [Resolve reader [Get $value Filter]]
    if {[lindex $filter 0] eq "nm"} {
        set filters [list [lindex $filter 1]]
    } elseif {[lindex $filter 0] eq "a"} {
        # A filter in a chain may itself be an indirect reference (7.4); read
        # it through Resolve so a name arrives, not a raw {num gen} that no
        # switch arm below matches.
        foreach item [lindex $filter 1] {
            lappend filters [lindex [Resolve reader $item] 1]
        }
    }
    set parms [Resolve reader [Get $value DecodeParms]]
    if {[lindex $parms 0] eq "a"} {
        set parmsList [lindex $parms 1]
    } elseif {$parms eq {}} {
        set parmsList {}
    } else {
        set parmsList [list $parms]
    }
    set i 0
    foreach name $filters {
        switch -- $name {
            FlateDecode - Fl {
                set decoder decodeFlate
            }
            ASCII85Decode - A85 {
                set decoder decodeAscii85
            }
            ASCIIHexDecode - AHx {
                set decoder decodeAsciiHex
            }
            LZWDecode - LZW {
                # LZW was the general-purpose filter before PDF 1.2, and it
                # came back into reach with the TIFF work: the decoder that
                # reads an LZW-compressed scan reads an LZW content stream
                # too. /EarlyChange is read below, since it is the one
                # parameter that changes the bytes without changing the
                # length in any way a reader would notice.
                set decoder decodeLzw
            }
            CCITTFaxDecode - CCF {
                # A page content stream coded as fax is not what the filter
                # is for, and a scanned page carries its fax in an image
                # rather than in its content - but the refusal below is the
                # one place where a filter this package cannot read is
                # named, so the decoder that reads a scan's pixels answers
                # here too. Every parameter of Table 11 is handed over
                # below; /Columns and /K are the two that decide whether
                # anything comes out at all.
                set decoder decodeCcitt
            }
            default {
                return -code error -errorcode {TCLPDF IMPORT FILTER} "tclpdf:\
                    [dict get $reader path]: $what uses filter /$name, which\
                    this import cannot decode"
            }
        }
        # A stream whose bytes the decoder refuses names the FILE and what
        # was being read. Without this the answer is zlib's own "stream
        # error" - three words, no file, no place - and one of 106 foreign
        # files measured on 2026-08-21 arrives that way: an InDesign
        # hybrid-reference file whose /XRefStm ends before its deflate stream
        # does. Refused rather than salvaged, as everywhere in this reader.
        # The parameters are read BEFORE the decoder runs, because LZW needs
        # one of them: /EarlyChange decides when the code width grows, and the
        # wrong value does not fail - it returns fewer bytes, correct up to
        # the first width change and wrong after it.
        set p [Resolve reader [lindex $parmsList $i]]
        set extra {}
        if {$decoder eq "decodeLzw" && $p ne {} && [lindex $p 0] eq "d"} {
            set early [lindex [Resolve reader [Get $p EarlyChange]] 1]
            if {$early ne {}} {
                set extra [list $early]
            }
        }
        # CCITT needs its parameters for the same reason and more so: the
        # geometry is not in the data. A fax stream says nothing about how
        # wide its rows are, so a missing or wrong /Columns does not fail -
        # it decodes rows of the WRONG width and hands back a picture that
        # is sheared, which is why every one of Table 11 is passed on rather
        # than a chosen few.
        if {$decoder eq "decodeCcitt"} {
            if {$p ne {} && [lindex $p 0] eq "d"} {
                foreach {key option} {Columns -columns Rows -rows K -k
                        BlackIs1 -blackis1 EncodedByteAlign -encodedbytealign
                        EndOfLine -endofline EndOfBlock -endofblock
                        DamagedRowsBeforeError -damagedrowsbeforeerror} {
                    set item [Resolve reader [Get $p $key]]
                    if {$item eq {}} {
                        continue
                    }
                    lappend extra $option [lindex $item 1]
                }
            }
            # /Rows is optional (Table 11) and an image says the same thing
            # in /Height, which is not optional. Taken from there where the
            # parameters are silent, so that a stream ending early is caught
            # rather than quietly delivering fewer rows than the picture has.
            if {![dict exists $extra -rows]} {
                set height [lindex [Resolve reader [Get $value Height]] 1]
                if {$height ne {}} {
                    lappend extra -rows $height
                }
            }
        }
        if {[catch {::tclpdf::filter::$decoder $data {*}$extra} decoded]} {
            return -code error -errorcode {TCLPDF IMPORT FILTER} "tclpdf:\
                [dict get $reader path]: $what is a /$name stream this\
                package cannot decode: $decoded"
        }
        set data $decoded
        if {$p ne {} && [lindex $p 0] eq "d"} {
            set predictor [lindex [Resolve reader [Get $p Predictor]] 1]
            if {$predictor ne {} && $predictor > 1} {
                set columns [lindex [Resolve reader [Get $p Columns]] 1]
                if {$columns eq {}} {set columns 1}
                set colors [lindex [Resolve reader [Get $p Colors]] 1]
                if {$colors eq {}} {set colors 1}
                set depth [lindex [Resolve reader [Get $p BitsPerComponent]] 1]
                if {$depth eq {}} {set depth 8}
                # /Columns is a byte count per row and has to be a positive
                # integer: zero or a non-number would drive the predictor's
                # own row arithmetic onto a raw error with no file named.
                if {![string is entier -strict $columns] || $columns < 1} {
                    return -code error -errorcode {TCLPDF IMPORT PREDICTOR} \
                        "tclpdf: [dict get $reader path]: $what carries a\
                        predictor /Columns that is not a positive integer"
                }
                # Shared with the image side rather than kept here: the local
                # copy read neither /Colors nor /BitsPerComponent and was
                # quietly wrong for anything but one 8-bit component. Wrapped
                # in the same file-naming mantle as the decoder above, so a
                # predictor that refuses names the file and what was read.
                if {[catch {::tclpdf::filter decodePredictor $data \
                        -predictor $predictor -columns $columns \
                        -colors $colors -bitspercomponent $depth} unfiltered]} {
                    return -code error -errorcode {TCLPDF IMPORT PREDICTOR} \
                        "tclpdf: [dict get $reader path]: $what carries a\
                        predictor this package cannot apply: $unfiltered"
                }
                set data $unfiltered
            }
        }
        incr i
    }
    return $data
}


# ------------------------------------------------------------- page lookup

# Walks the page tree to page NUMBER (1-based) and returns its dictionary
# with the inheritable attributes (7.7.3.4) filled in from the ancestors
# where the page itself is silent.
proc ::tclpdf::importRead::Page {readerVar number} {
    upvar 1 $readerVar reader
    set root [Resolve reader [Get [dict get $reader trailer] Root]]
    # The catalog and its page tree have to be dictionaries (7.7.2, 7.7.3):
    # a missing /Root, or a /Root that resolves to a stream, otherwise walks
    # into an empty node and reports "has  pages" with a hole where the count
    # should be.
    if {[lindex $root 0] ne "d"} {
        return -code error -errorcode {TCLPDF IMPORT ROOT} "tclpdf:\
            [dict get $reader path] has no usable /Root catalogue"
    }
    set pagesRef [Get $root Pages]
    set node [Resolve reader $pagesRef]
    if {[lindex $node 0] ne "d"} {
        return -code error -errorcode {TCLPDF IMPORT PAGES} "tclpdf:\
            [dict get $reader path]: the catalogue has no /Pages tree"
    }
    # Which nodes the walk has already entered. A page tree is a tree
    # (7.7.3.1); a node that names itself, or an ancestor, among its /Kids is
    # a ring, and the descent below would follow it for ever. Only nodes
    # reached through a reference can repeat - a directly written value
    # cannot contain itself.
    set seen {}
    if {[lindex $pagesRef 0] eq "r"} {
        dict set seen [lindex [lindex $pagesRef 1] 0] 1
    }
    set inherited {}
    set remaining $number
    while 1 {
        # The NEAREST ancestor wins (7.7.3.4: an attribute the page lacks
        # is inherited from the closest node above it that has one). The
        # walk runs root -> leaf, so a value found deeper OVERWRITES the
        # one above it; the page's own entries, already in its payload,
        # win over all of them below.
        foreach key {Resources MediaBox CropBox Rotate} {
            if {[Get $node $key] ne {}} {
                dict set inherited $key [Get $node $key]
            }
        }
        if {[lindex [Get $node Type] 1] eq "Page"} {
            lassign $node - payload
            foreach {key item} $inherited {
                if {![dict exists $payload $key]} {
                    dict set payload $key $item
                }
            }
            return [list d $payload]
        }
        set descended 0
        foreach kid [lindex [Resolve reader [Get $node Kids]] 1] {
            set child [Resolve reader $kid]
            if {[lindex [Get $child Type] 1] eq "Pages"} {
                set count [lindex [Resolve reader [Get $child Count]] 1]
                # /Count is a non-negative integer (7.7.3.2, Table 30). A
                # name or a string compares as a STRING in the test below,
                # which would send the walk down a branch on a whim.
                if {![string is entier -strict $count] || $count < 0} {
                    return -code error -errorcode {TCLPDF IMPORT PAGES} \
                        "tclpdf: [dict get $reader path]: a node of the page\
                        tree carries a /Count that is not a non-negative\
                        integer"
                }
            } else {
                set count 1
            }
            if {$remaining <= $count} {
                if {[lindex $kid 0] eq "r"} {
                    set kidNumber [lindex [lindex $kid 1] 0]
                    if {[dict exists $seen $kidNumber]} {
                        return -code error -errorcode {TCLPDF IMPORT PAGES} \
                            "tclpdf: [dict get $reader path]: the page tree\
                            runs in a circle at object $kidNumber"
                    }
                    dict set seen $kidNumber 1
                }
                set node $child
                set descended 1
                break
            }
            set remaining [expr {$remaining - $count}]
        }
        if {!$descended} {
            set total [lindex [Resolve reader [Get [Resolve reader \
                $pagesRef] Count]] 1]
            # A tree that does not say how many pages it holds is named as
            # such: without this the message read "has  pages", with a hole
            # where the number belongs.
            if {![string is entier -strict $total]} {
                return -code error -errorcode {TCLPDF IMPORT PAGES} "tclpdf:\
                    [dict get $reader path] does not say how many pages it\
                    has - there is no page $number"
            }
            return -code error -errorcode {TCLPDF IMPORT PAGES} "tclpdf:\
                [dict get $reader path] has $total\
                page[expr {$total == 1 ? {} : {s}}] - there is no page\
                $number"
        }
    }
}

# A page box, resolved to four numbers and normalized so that the first
# corner is the lower left - the standard allows any two diagonally
# opposite corners (7.9.5). Empty when the page has no such box.
proc ::tclpdf::importRead::Box {readerVar pageDict key} {
    upvar 1 $readerVar reader
    set box [Resolve reader [Get $pageDict $key]]
    if {$box eq {}} {
        return {}
    }
    # A rectangle is an array of four numbers (7.9.5). Fewer, or an entry that
    # is a name, a string or a non-finite real, otherwise reaches expr as an
    # empty or non-numeric operand and dies with a raw Tcl message.
    if {[lindex $box 0] ne "a" || [llength [lindex $box 1]] < 4} {
        return -code error -errorcode {TCLPDF IMPORT BOX} "tclpdf:\
            [dict get $reader path]: /$key is not an array of four numbers"
    }
    set edges {}
    foreach item [lrange [lindex $box 1] 0 3] {
        set edge [Resolve reader $item]
        set v [lindex $edge 1]
        if {[lindex $edge 0] ne "n" || ![string is double -strict $v]
                || $v != $v || $v == Inf || $v == -Inf} {
            return -code error -errorcode {TCLPDF IMPORT BOX} "tclpdf:\
                [dict get $reader path]: /$key holds a coordinate that is not\
                a finite number"
        }
        lappend edges $v
    }
    lassign $edges a b c d
    return [list [expr {min($a, $c)}] [expr {min($b, $d)}] \
        [expr {max($a, $c)}] [expr {max($b, $d)}]]
}

# The geometry of a page as a VIEWER shows it: which box is visible, how the
# page is turned, and the extent the two produce together.
#
#   media   the MediaBox, four numbers
#   crop    the CropBox, or {} where the page has none
#   box     what is visible: the CropBox intersected with the MediaBox, which
#           bounds it (14.11.2.2), and the MediaBox alone otherwise (7.7.3.3)
#   rotate  /Rotate, normalized to 0, 90, 180 or 270
#   width   the extent of "box" with the rotation applied - a page turned by
#   height  90 is as wide as its box is high
#
# Two callers, and that is why it is a proc rather than part of the import:
# [pdf import] needs the visible box to make a form of it, and [pdf pages]
# reports the same numbers about every page of the file. Written twice they
# would answer differently the day one of them learns about a box the other
# does not.
proc ::tclpdf::importRead::Geometry {readerVar pageDict number} {
    upvar 1 $readerVar reader
    set path [dict get $reader path]
    # The two boxes are resolved independently because they can be inherited
    # from DIFFERENT nodes of the page tree.
    set media [Box reader $pageDict MediaBox]
    if {$media eq {}} {
        return -code error -errorcode {TCLPDF IMPORT BOX} "tclpdf: $path: page\
            $number has no MediaBox"
    }
    set crop [Box reader $pageDict CropBox]
    if {$crop eq {}} {
        set edges $media
    } else {
        lassign $media mx0 my0 mx1 my1
        lassign $crop cx0 cy0 cx1 cy1
        set edges [list [expr {max($mx0, $cx0)}] [expr {max($my0, $cy0)}] \
            [expr {min($mx1, $cx1)}] [expr {min($my1, $cy1)}]]
        lassign $edges x0 y0 x1 y1
        if {$x0 >= $x1 || $y0 >= $y1} {
            return -code error -errorcode {TCLPDF IMPORT BOX} "tclpdf:\
                $path: the CropBox of page $number does not intersect its\
                MediaBox - nothing of the page is visible"
        }
    }
    lassign $edges x0 y0 x1 y1
    set width [expr {$x1 - $x0}]
    set height [expr {$y1 - $y0}]

    set rotate 0
    set rotateValue [Resolve reader [Get $pageDict Rotate]]
    if {$rotateValue ne {}} {
        set raw [lindex $rotateValue 1]
        if {![string is entier -strict $raw]} {
            # The standard wants an integer (Table 31). An integer-valued real
            # like 90.0 is a defect worth tolerating; anything else is refused
            # rather than guessed at.
            if {[string is double -strict $raw]
                    && ![catch {expr {$raw == entier($raw)}} whole] && $whole} {
                set raw [expr {entier($raw)}]
            } else {
                return -code error \
                    -errorcode {TCLPDF IMPORT ROTATE} "tclpdf: $path: page\
                    $number carries /Rotate \"$raw\", which is not usable\
                    as a multiple of 90"
            }
        }
        if {$raw % 90 != 0} {
            return -code error -errorcode {TCLPDF IMPORT ROTATE} "tclpdf:\
                $path: page $number carries /Rotate $raw, which is not a\
                multiple of 90"
        }
        set rotate [expr {($raw % 360 + 360) % 360}]
    }
    if {$rotate == 90 || $rotate == 270} {
        lassign [list $height $width] width height
    }
    return [dict create media $media crop $crop box $edges rotate $rotate \
        width $width height $height]
}

# ------------------------------------------------------------ the takeover

package provide tclpdf::importRead 1.3
