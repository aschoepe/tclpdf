#
# tclpdf - PDF generation for Tcl
#
# import - a page of an existing PDF, taken over as a form XObject (Etappe 7)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Usage:
#
#   $doc pdf import letterhead briefbogen.pdf
#   $doc pdf import annex report.pdf -page 3
#   $doc form place letterhead -at {0 0}
#   $doc form place annex -at {20 40} -scale 0.4
#
# The named page becomes a form under the same contract as [form create]:
# placed with [form place], as often as wanted, scaled and rotated, stored
# once in the file. Taking over a letterhead is [pdf import] once and
# [form place] on every page.
#
# WHAT IS READ. Both cross-reference flavours of ISO 32000: the classic
# table (7.5.4) and, since PDF 1.5, cross-reference streams (7.5.8) with
# object streams (7.5.7) - measured on a stock of real invoices, 29 of 32
# use the stream flavour, so a reader without it would refuse most files
# that arrive in practice. Hybrid files (7.5.8.4) are read through their
# XRefStm entry. Incremental updates are followed over /Prev, newest
# section first, as the standard prescribes.
#
# WHAT IS REFUSED, by name: encrypted files (no decryption in this
# package - see the encryption stage of the roadmap), content streams in a
# filter this package cannot decode (the resources are exempt, see below),
# and files whose cross-reference is broken. Refusing beats guessing: an
# imported letterhead that is silently wrong reaches the recipient.
#
# HOW THE TAKEOVER WORKS. Everything reachable from the page's /Resources
# is copied object by object, renumbered through this document's writer.
# The copy is done on PARSED objects - a real tokenizer, not a text
# substitution - so a literal string that happens to contain "5 0 R" stays
# untouched. Streams among the copied objects (fonts, images, ICC
# profiles) keep their bytes and their /Filter exactly as they were: the
# import never decodes what it does not have to, which is also why exotic
# image filters are no obstacle. Only the CONTENT streams are decoded -
# they have to become one stream to live in a form XObject, and their
# operators end up behind this document's own compression.
#
# The page's boxes travel along: the form's BBox is the CropBox where one
# exists - intersected with the MediaBox, which bounds it (14.11.2.2) -
# the MediaBox otherwise, and a /Rotate of 90, 180 or 270 becomes
# the form's /Matrix, so the placed page looks the way a viewer shows it.
# A /Properties resource (optional content, "layers") gets its catalog
# counterpart via /OCProperties, or a validator reports an OCG without a
# configuration.
#
# The parser below is deliberately independent of the document object -
# plain procs over a byte string - so the tests can feed it handcrafted
# files without a document around it.

package require Tcl 8.6.11-
package require tclpdf::filter 1.0-
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::import {}

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
proc ::tclpdf::import::SkipWs {bytes posVar} {
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
proc ::tclpdf::import::Delimiter {c} {
    return [expr {$c eq {} || $c eq " " || $c eq "\n" || $c eq "\r"
        || $c eq "\t" || $c eq "\f" || $c eq "\x00"
        || $c in {( ) < > \[ \] \{ \} / %}}]
}

proc ::tclpdf::import::ParseString {bytes posVar} {
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

proc ::tclpdf::import::ParseToken {bytes posVar} {
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
proc ::tclpdf::import::Parse {bytes posVar} {
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
proc ::tclpdf::import::EscapeName {name} {
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
proc ::tclpdf::import::Serialize {value map} {
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
proc ::tclpdf::import::Refs {value} {
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

proc ::tclpdf::import::Get {value key} {
    lassign $value type payload
    if {$type ne "d" || ![dict exists $payload $key]} {
        return {}
    }
    return [dict get $payload $key]
}

proc ::tclpdf::import::Put {valueVar key item} {
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
#   xref      num -> {o offset} | {c objstmNum indexInStream}
#   trailer   the merged trailer/xref-stream dictionary (parsed)
#   objects   cache num -> {value hasStream data}
#   buffers   cache of decoded object stream payloads

proc ::tclpdf::import::Open {path} {
    set channel [open $path rb]
    set bytes [read $channel]
    close $channel
    set reader [dict create bytes $bytes path $path xref {} \
        trailer {d {}} objects {} buffers {}]
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
        set offset [Section reader $offset]
    }
    if {[Get [dict get $reader trailer] Encrypt] ne {}} {
        return -code error "tclpdf: $path is encrypted - encrypted files\
            are not imported"
    }
    return $reader
}

# One cross-reference section, classic or stream; returns the /Prev offset
# or the empty string. Entries never overwrite existing ones - the chain
# runs newest first, and the newest section wins (7.5.6).
proc ::tclpdf::import::Section {readerVar offset} {
    upvar 1 $readerVar reader
    set bytes [dict get $reader bytes]
    set pos $offset
    SkipWs $bytes pos
    if {[string range $bytes $pos [expr {$pos + 3}]] eq "xref"} {
        return [ClassicSection reader [expr {$pos + 4}]]
    }
    return [StreamSection reader $pos]
}

proc ::tclpdf::import::ClassicSection {readerVar pos} {
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

proc ::tclpdf::import::StreamSection {readerVar pos} {
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

proc ::tclpdf::import::Enter {readerVar number entry} {
    upvar 1 $readerVar reader
    if {![dict exists $reader xref $number]} {
        dict set reader xref $number $entry
    }
}

# Trailer keys merge the same way the entries do: the first (= newest)
# occurrence wins.
proc ::tclpdf::import::Merge {readerVar trailer} {
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
proc ::tclpdf::import::ObjectAt {readerVar offset} {
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
proc ::tclpdf::import::Object {readerVar number} {
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
proc ::tclpdf::import::Resolve {readerVar value} {
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

proc ::tclpdf::import::DecodeStream {readerVar value data what} {
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
                set data [::tclpdf::filter::decodeFlate $data]
            }
            ASCII85Decode - A85 {
                set data [::tclpdf::filter::decodeAscii85 $data]
            }
            ASCIIHexDecode - AHx {
                set data [::tclpdf::filter::decodeAsciiHex $data]
            }
            default {
                return -code error "tclpdf: [dict get $reader path]: $what\
                    uses filter /$name, which this import cannot decode"
            }
        }
        set p [Resolve reader [lindex $parmsList $i]]
        if {$p ne {} && [lindex $p 0] eq "d"} {
            set predictor [lindex [Resolve reader [Get $p Predictor]] 1]
            if {$predictor ne {} && $predictor > 1} {
                set columns [lindex [Resolve reader [Get $p Columns]] 1]
                if {$columns eq {}} {set columns 1}
                set data [Predictor $data $columns $predictor]
            }
        }
        incr i
    }
    return $data
}

# The PNG row predictors (RFC 2083 via ISO 32000, 7.4.4.4) - what
# cross-reference streams are compressed with in practice. Colors is 1 and
# bits per component 8 for every xref stream this reads, so a pixel is one
# byte. Predictor 2 (TIFF) reduces to Sub with that geometry.
proc ::tclpdf::import::Predictor {data columns predictor} {
    if {$predictor == 2} {
        set out {}
        set prev [lrepeat $columns 0]
        binary scan $data cu* all
        set row {}
        foreach byte $all {
            lappend row $byte
            if {[llength $row] == $columns} {
                set line {}
                set left 0
                foreach b $row {
                    set left [expr {($b + $left) & 0xff}]
                    lappend line $left
                }
                append out [binary format c* $line]
                set row {}
            }
        }
        return $out
    }
    set out {}
    set stride [expr {$columns + 1}]
    set prior [lrepeat $columns 0]
    binary scan $data cu* all
    for {set at 0} {$at + $stride <= [llength $all]} {incr at $stride} {
        set tag [lindex $all $at]
        set row [lrange $all [expr {$at + 1}] [expr {$at + $columns}]]
        set line {}
        set left 0
        set i 0
        foreach b $row {
            set up [lindex $prior $i]
            set upLeft [expr {$i ? [lindex $prior [expr {$i - 1}]] : 0}]
            switch -- $tag {
                0 {set value $b}
                1 {set value [expr {$b + $left}]}
                2 {set value [expr {$b + $up}]}
                3 {set value [expr {$b + (($left + $up) / 2)}]}
                4 {
                    set p [expr {$left + $up - $upLeft}]
                    set pa [expr {abs($p - $left)}]
                    set pb [expr {abs($p - $up)}]
                    set pc [expr {abs($p - $upLeft)}]
                    if {$pa <= $pb && $pa <= $pc} {
                        set value [expr {$b + $left}]
                    } elseif {$pb <= $pc} {
                        set value [expr {$b + $up}]
                    } else {
                        set value [expr {$b + $upLeft}]
                    }
                }
                default {
                    return -code error "tclpdf: unknown PNG predictor row\
                        tag $tag in cross-reference stream"
                }
            }
            set value [expr {$value & 0xff}]
            set left $value
            lappend line $value
            incr i
        }
        append out [binary format c* $line]
        set prior $line
    }
    return $out
}

# ------------------------------------------------------------- page lookup

# Walks the page tree to page NUMBER (1-based) and returns its dictionary
# with the inheritable attributes (7.7.3.4) filled in from the ancestors
# where the page itself is silent.
proc ::tclpdf::import::Page {readerVar number} {
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
proc ::tclpdf::import::Box {readerVar pageDict key} {
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

# ------------------------------------------------------------ the takeover

oo::define ::tclpdf::document::document {

  # $doc pdf import <alias> <path> ?-page n?
  method pdf {subcommand args} {
    switch -- $subcommand {
      import {return [my PdfImport {*}$args]}
      default {
        return -code error "tclpdf: unknown pdf subcommand \"$subcommand\" -\
            known is: import"
      }
    }
  }

  method PdfImport {alias path args} {
    set options [::tclpdf::option parse {page 1} $args "pdf import"]
    set page [dict get $options page]
    if {![string is entier -strict $page] || $page < 1} {
      return -code error "tclpdf: -page of pdf import is a page number\
          counted from 1, not \"$page\""
    }
    set forms [my state forms]
    if {[dict exists $forms $alias]} {
      return -code error "tclpdf: a form named \"$alias\" already exists"
    }
    if {![file exists $path]} {
      return -code error "tclpdf: pdf import: no file \"$path\""
    }

    set reader [::tclpdf::import::Open $path]
    set pageDict [::tclpdf::import::Page reader $page]

    # The box that becomes the form: the CropBox where one exists - that
    # is what a viewer shows - taken as its INTERSECTION with the MediaBox,
    # which bounds it (14.11.2.2); the MediaBox alone otherwise (7.7.3.3).
    # The two boxes are resolved independently because they can be
    # inherited from DIFFERENT nodes of the page tree.
    set media [::tclpdf::import::Box reader $pageDict MediaBox]
    if {$media eq {}} {
      return -code error "tclpdf: $path: page $page has no MediaBox"
    }
    set crop [::tclpdf::import::Box reader $pageDict CropBox]
    if {$crop eq {}} {
      set edges $media
    } else {
      lassign $media mx0 my0 mx1 my1
      lassign $crop cx0 cy0 cx1 cy1
      set edges [list [expr {max($mx0, $cx0)}] [expr {max($my0, $cy0)}] \
          [expr {min($mx1, $cx1)}] [expr {min($my1, $cy1)}]]
      lassign $edges x0 y0 x1 y1
      if {$x0 >= $x1 || $y0 >= $y1} {
        return -code error "tclpdf: $path: the CropBox of page $page does\
            not intersect its MediaBox - nothing of the page is visible"
      }
    }
    lassign $edges x0 y0 x1 y1
    set width [expr {$x1 - $x0}]
    set height [expr {$y1 - $y0}]

    set rotate 0
    set rotateValue [::tclpdf::import::Resolve reader \
        [::tclpdf::import::Get $pageDict Rotate]]
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
          return -code error "tclpdf: $path: page $page carries /Rotate\
              \"$raw\", which is not usable as a multiple of 90"
        }
      }
      if {$raw % 90 != 0} {
        return -code error "tclpdf: $path: page $page carries /Rotate $raw,\
            which is not a multiple of 90"
      }
      set rotate [expr {($raw % 360 + 360) % 360}]
    }

    # Everything the page's resources reach is copied and renumbered; the
    # content streams are NOT part of that closure - they are decoded and
    # merged into the form below rather than copied.
    set resources [::tclpdf::import::Get $pageDict Resources]
    set writer [my writer]
    set queue [::tclpdf::import::Refs $resources]
    set map {}
    set order {}
    while {[llength $queue]} {
      set queue [lassign $queue number]
      if {[dict exists $map $number]} continue
      dict set map $number [$writer reserve]
      lappend order $number
      lassign [::tclpdf::import::Object reader $number] value - -
      lappend queue {*}[::tclpdf::import::Refs $value]
    }
    foreach number $order {
      lassign [::tclpdf::import::Object reader $number] value hasStream data
      if {$hasStream} {
        # The raw bytes and their /Filter travel unchanged, and the object
        # goes out through [stream] rather than being assembled here: that
        # is the one place /Length is computed (writer.tcl) and the one
        # place a stream's filters are checked against the document's PDF
        # version. Building the body here meant a copied stream was the
        # single stream in the document that passed neither - a second
        # producer of /Length beside the writer's, and a FlateDecode
        # resource that could land in a file whose header disowns the
        # filter.
        #
        # /Length is dropped rather than restated: the writer sets it, and
        # an indirect length object therefore need not come along.
        # The parsed value is a dictionary whenever hasStream is true: a
        # stream is only recognised as one when its /Length could be read
        # out of a dictionary, so there is nothing else it could be here.
        set pairs {}
        foreach {key item} [lindex $value 1] {
          if {$key eq "Length"} continue
          lappend pairs $key [::tclpdf::import::Serialize $item $map]
        }
        $writer stream [dict get $map $number] $pairs $data
      } else {
        $writer put [dict get $map $number] \
            [::tclpdf::import::Serialize $value $map]
      }
    }

    # The resources dictionary itself: referenced and already part of the
    # closure, or direct on the page and written as an object of its own.
    if {[lindex $resources 0] eq "r"} {
      set resourcesRef [$writer ref \
          [dict get $map [lindex [lindex $resources 1] 0]]]
    } elseif {[lindex $resources 0] eq "d"} {
      set resourcesRef [$writer ref [$writer add \
          [::tclpdf::import::Serialize $resources $map]]]
    } else {
      # A page without resources is legal; the form then carries an empty
      # dictionary, which PDF/A asks for anyway (6.2.2).
      set resourcesRef [$writer ref [$writer add "<< >>"]]
    }

    # An optional-content resource needs its catalog counterpart, or the
    # file carries layers no viewer can configure. Table 98 allows an OCMD
    # as a /Properties value; the catalog's /OCGs array takes the GROUPS
    # behind it - its /OCGs, a reference or an array of them - never the
    # OCMD itself (8.11.4.2 asks for every group in the document there).
    set resolved [::tclpdf::import::Resolve reader $resources]
    set properties [::tclpdf::import::Resolve reader \
        [::tclpdf::import::Get $resolved Properties]]
    set numbers {}
    # A second import MERGES with what an earlier one put into the catalog
    # rather than overwriting it; the entry is this module's own
    # serialization, read back with its own parser. First come the groups
    # already there, then the new ones, duplicates dropped by number.
    set existing [my catalogEntry OCProperties]
    if {$existing ne {}} {
      set pos 0
      set have [::tclpdf::import::Parse $existing pos]
      foreach item [lindex [::tclpdf::import::Get $have OCGs] 1] {
        if {[lindex $item 0] eq "r"} {
          lappend numbers [lindex [lindex $item 1] 0]
        }
      }
    }
    if {[lindex $properties 0] eq "d"} {
      foreach {- item} [lindex $properties 1] {
        if {[lindex $item 0] ne "r"} continue
        set entry [::tclpdf::import::Resolve reader $item]
        if {[lindex [::tclpdf::import::Get $entry Type] 1] eq "OCMD"} {
          set members [::tclpdf::import::Get $entry OCGs]
          if {[lindex $members 0] eq "r"} {
            set members [list $members]
          } elseif {[lindex $members 0] eq "a"} {
            set members [lindex $members 1]
          } else {
            set members {}
          }
          foreach member $members {
            if {[lindex $member 0] eq "r"} {
              lappend numbers \
                  [dict get $map [lindex [lindex $member 1] 0]]
            }
          }
        } else {
          lappend numbers [dict get $map [lindex [lindex $item 1] 0]]
        }
      }
    }
    if {[llength $numbers]} {
      set groups {}
      set seen {}
      foreach number $numbers {
        if {[dict exists $seen $number]} continue
        dict set seen $number 1
        lappend groups "$number 0 R"
      }
      my catalogEntry OCProperties "<< /OCGs \[[join $groups { }]\]\
          /D << /ON \[[join $groups { }]\] >> >>"
    }

    # The content: one stream or an array of streams whose CONCATENATION
    # is the page description (7.8.2) - decoded, joined, and stored behind
    # this document's own compression.
    set contents [::tclpdf::import::Resolve reader \
        [::tclpdf::import::Get $pageDict Contents]]
    set pieces {}
    if {[lindex $contents 0] eq "a"} {
      set list [lindex $contents 1]
    } elseif {$contents eq {}} {
      set list {}
    } else {
      set list [list [::tclpdf::import::Get $pageDict Contents]]
    }
    foreach item $list {
      set number [lindex [lindex $item 1] 0]
      lassign [::tclpdf::import::Object reader $number] value hasStream data
      if {!$hasStream} {
        return -code error "tclpdf: $path: content object $number is not a\
            stream"
      }
      lappend pieces [::tclpdf::import::DecodeStream reader $value $data \
          "the content stream"]
    }
    set content [join $pieces \n]

    # The form: BBox in its own normalized space, the page's corner and a
    # /Rotate folded into /Matrix, so [form place] puts down what a viewer
    # shows - upright, at the placement point.
    switch -- $rotate {
      90 {
        set matrix [list 0 -1 1 0 [expr {-$y0}] $x1]
        lassign [list $height $width] width height
      }
      180 {
        set matrix [list -1 0 0 -1 $x1 $y1]
      }
      270 {
        set matrix [list 0 1 -1 0 $y1 [expr {-$x0}]]
        lassign [list $height $width] width height
      }
      default {
        set matrix [list 1 0 0 1 [expr {-$x0}] [expr {-$y0}]]
      }
    }
    # The BBox clips in FORM space, before the matrix is applied (ISO
    # 32000-2, 8.10.2) - so it is the page's own box, unrotated; only the
    # width and height handed to [form place] are the post-matrix extents.
    set pairs [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [list \
            [::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] \
            [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1]]] \
        Matrix [::tclpdf::pdfObj arr \
            [lmap number $matrix {::tclpdf::pdfObj num $number}]] \
        Resources $resourcesRef]
    # The same transparency group [form create] writes - isolated, and
    # deliberately without /CS; xObject.tcl carries the full reasoning (a
    # named colour space is a PDF/A claim, ISO 19005-2, 6.2.4.3-2).
    # Without the group, [form place -opacity] composites each imported
    # object separately instead of fading the page as a whole. Groups
    # exist since PDF 1.4 - an older document gets none.
    if {[package vcompare [$writer version] 1.4] >= 0} {
      lappend pairs Group [::tclpdf::pdfObj dictionary {S /Transparency I true}]
    }
    set number [my streamObject $pairs $content]

    set resourceName PI[expr {[dict size $forms] + 1}]
    my resource XObject $resourceName [$writer ref $number]
    dict set forms $alias [dict create resource $resourceName \
        width $width height $height]
    my state forms $forms
    return $alias
  }
}

package provide tclpdf::import 1.0
