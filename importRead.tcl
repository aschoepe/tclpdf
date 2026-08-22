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
            return -code error "tclpdf: unterminated string in imported PDF"
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
proc ::tclpdf::importRead::Parse {bytes posVar} {
    upvar 1 $posVar pos
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
                if {[string index $bytes $pos] eq "\]"} {
                    incr pos
                    return [list a $items]
                }
                lappend items [Parse $bytes pos]
            }
        }
        < {
            if {[string index $bytes [expr {$pos + 1}]] eq "<"} {
                incr pos 2
                set pairs {}
                while 1 {
                    SkipWs $bytes pos
                    if {[string range $bytes $pos [expr {$pos + 1}]] eq ">>"} {
                        incr pos 2
                        return [list d $pairs]
                    }
                    set key [Parse $bytes pos]
                    if {[lindex $key 0] ne "nm"} {
                        return -code error "tclpdf: dictionary key is not a\
                            name in imported PDF"
                    }
                    lappend pairs [lindex $key 1] [Parse $bytes pos]
                }
            }
            incr pos
            set start $pos
            while {[string index $bytes $pos] ne ">"} {
                incr pos
                if {$pos >= [string length $bytes]} {
                    return -code error "tclpdf: unterminated hex string in\
                        imported PDF"
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
proc ::tclpdf::importRead::Serialize {value map} {
    lassign $value type payload
    switch -- $type {
        d {
            set out "<<"
            foreach {key item} $payload {
                append out " /" [EscapeName $key] " " [Serialize $item $map]
            }
            append out " >>"
            return $out
        }
        a {
            set out "\["
            foreach item $payload {
                append out " " [Serialize $item $map]
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
                return -code error "tclpdf: reference to object $number,\
                    which the import never reached"
            }
            return "[dict get $map $number] 0 R"
        }
        default {
            return -code error "tclpdf: cannot serialize \"$type\""
        }
    }
}

# All object numbers a parsed value refers to.
proc ::tclpdf::importRead::Refs {value} {
    lassign $value type payload
    switch -- $type {
        r {return [list [lindex $payload 0]]}
        d {
            set found {}
            foreach {- item} $payload {
                lappend found {*}[Refs $item]
            }
            return $found
        }
        a {
            set found {}
            foreach item $payload {
                lappend found {*}[Refs $item]
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
        trailer {d {}} objects {} buffers {} sections {} flavour {}]
    if {![regexp {startxref\s+(\d+)\s+%%EOF\s*$} \
            [string range $bytes end-1023 end] -> offset]} {
        return -code error "tclpdf: $path carries no startxref - not a PDF,\
            or a truncated one"
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
            return -code error "tclpdf: $path: circular cross-reference\
                chain"
        }
        dict set seen $offset 1
        # Every section of the chain is kept, newest first: how many there
        # are is how often the file was written on (7.5.6), and that is a
        # fact about the file that only this walk knows.
        dict lappend reader sections $offset
        set offset [Section reader $offset]
    }
    if {!$tolerateEncrypted && [Get [dict get $reader trailer] Encrypt] ne {}} {
        return -code error "tclpdf: $path is encrypted - encrypted files\
            are not imported"
    }
    return $reader
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
            if {$previous eq {}} {
                return {}
            }
            return [lindex $previous 1]
        }
        set first [ParseToken $bytes pos]
        SkipWs $bytes pos
        set count [ParseToken $bytes pos]
        if {![string is entier -strict $first]
                || ![string is entier -strict $count]} {
            return -code error "tclpdf: [dict get $reader path]: unreadable\
                cross-reference line at $pos"
        }
        SkipWs $bytes pos
        for {set i 0} {$i < $count} {incr i} {
            set entry [string range $bytes $pos [expr {$pos + 19}]]
            if {[string index $entry 17] eq "n"} {
                Enter reader [expr {$first + $i}] \
                    [list o [scan [string range $entry 0 9] %d]]
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
        return -code error "tclpdf: [dict get $reader path]: no\
            cross-reference at offset $pos"
    }
    set data [DecodeStream reader $value $data "cross-reference stream"]
    set w {}
    foreach item [lindex [Get $value W] 1] {
        lappend w [lindex $item 1]
    }
    lassign $w w0 w1 w2
    set record [expr {$w0 + $w1 + $w2}]
    set index {}
    if {[Get $value Index] ne {}} {
        foreach item [lindex [Get $value Index] 1] {
            lappend index [lindex $item 1]
        }
    } else {
        set index [list 0 [lindex [Get $value Size] 1]]
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
                1 {Enter reader [expr {$first + $i}] [list o $f2]}
                2 {Enter reader [expr {$first + $i}] [list c $f2 $f3]}
            }
        }
    }
    Merge reader $value
    set previous [Get $value Prev]
    if {$previous eq {}} {
        return {}
    }
    return [lindex $previous 1]
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

# The object at a byte offset: value, stream flag, raw stream bytes.
proc ::tclpdf::importRead::ObjectAt {readerVar offset} {
    upvar 1 $readerVar reader
    set bytes [dict get $reader bytes]
    set pos $offset
    SkipWs $bytes pos
    ParseToken $bytes pos
    SkipWs $bytes pos
    ParseToken $bytes pos
    SkipWs $bytes pos
    if {[ParseToken $bytes pos] ne "obj"} {
        return -code error "tclpdf: [dict get $reader path]: no object at\
            offset $offset"
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
        return -code error "tclpdf: [dict get $reader path]: stream at\
            offset $offset has no usable /Length"
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
        return -code error "tclpdf: [dict get $reader path]: the stream at\
            offset $offset declares /Length $length but does not end at\
            endstream"
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
        return -code error "tclpdf: [dict get $reader path]: object $number\
            is referenced but not in the cross-reference"
    }
    set entry [dict get $reader xref $number]
    switch -- [lindex $entry 0] {
        o {
            set object [ObjectAt reader [lindex $entry 1]]
        }
        c {
            lassign $entry - container index
            if {![dict exists $reader buffers $container]} {
                lassign [Object reader $container] value hasStream data
                if {!$hasStream} {
                    return -code error "tclpdf: [dict get $reader path]:\
                        object stream $container has no stream"
                }
                set data [DecodeStream reader $value $data "object stream"]
                dict set reader buffers $container \
                    [list $data [lindex [Get $value First] 1] \
                        [lindex [Get $value N] 1]]
            }
            lassign [dict get $reader buffers $container] data first n
            set pos 0
            set header {}
            for {set i 0} {$i < 2 * $n} {incr i} {
                SkipWs $data pos
                lappend header [ParseToken $data pos]
            }
            set pos [expr {$first + [lindex $header \
                [expr {2 * $index + 1}]]}]
            set object [list [Parse $data pos] 0 {}]
        }
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
        foreach item [lindex $filter 1] {
            lappend filters [lindex $item 1]
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
            default {
                return -code error "tclpdf: [dict get $reader path]: $what\
                    uses filter /$name, which this import cannot decode"
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
        if {[catch {::tclpdf::filter::$decoder $data {*}$extra} decoded]} {
            return -code error "tclpdf: [dict get $reader path]: $what is a\
                /$name stream this package cannot decode: $decoded"
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
                # Shared with the image side rather than kept here: the local
                # copy read neither /Colors nor /BitsPerComponent and was
                # quietly wrong for anything but one 8-bit component.
                set data [::tclpdf::filter decodePredictor $data \
                    -predictor $predictor -columns $columns -colors $colors \
                    -bitspercomponent $depth]
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
    set node [Resolve reader [Get $root Pages]]
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
            } else {
                set count 1
            }
            if {$remaining <= $count} {
                set node $child
                set descended 1
                break
            }
            set remaining [expr {$remaining - $count}]
        }
        if {!$descended} {
            set total [lindex [Resolve reader [Get [Resolve reader \
                [Get $root Pages]] Count]] 1]
            return -code error "tclpdf: [dict get $reader path] has $total\
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
    set edges {}
    foreach item [lindex $box 1] {
        lappend edges [lindex [Resolve reader $item] 1]
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
        return -code error "tclpdf: $path: page $number has no MediaBox"
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
            return -code error "tclpdf: $path: the CropBox of page $number\
                does not intersect its MediaBox - nothing of the page is\
                visible"
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
                return -code error "tclpdf: $path: page $number carries\
                    /Rotate \"$raw\", which is not usable as a multiple of 90"
            }
        }
        if {$raw % 90 != 0} {
            return -code error "tclpdf: $path: page $number carries /Rotate\
                $raw, which is not a multiple of 90"
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

package provide tclpdf::importRead 1.1
