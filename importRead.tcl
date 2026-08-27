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
#   r {num gen}         indirect reference - BOTH numbers are the identity
#                       of what it points at (7.3.10), and both are carried
#                       through the whole reader: the cross-reference entry
#                       records the generation, [Object] holds a reference
#                       against it, and a reference naming a generation the
#                       file does not have at that number is the NULL object,
#                       not the object that stands there
#   nm bytes            name, #xx escapes DECODED (7.3.5.2)
#   s bytes             literal string, DECODED bytes
#   h hextext           hex string, digits as written
#   b true|false        boolean
#   z {}                null
# Keeping numbers as written means a copied object round-trips
# byte-comparably - which is why the number token is checked against the
# whole grammar of 7.3.3 where it is read: what is kept as written and
# written back unchanged has to be valid before it is kept. That check
# reaches objects only; content streams are copied byte for byte, so an
# exponential number inside a stream passes through untouched.
# Names and strings are decoded: strings because their
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
                            # "The number ddd may consist of one, two, or
                            # three octal digits ... High-order overflow
                            # shall be ignored" (7.3.4.2): \777 is a byte,
                            # not code point 511. Left unmasked the value
                            # travelled on as a character above 0xFF, which
                            # Tcl 8.6 silently truncated in [binary format]
                            # and Tcl 9 refused with a raw TCL VALUE BYTES
                            # far away from the file that caused it.
                            append out [format %c \
                                [expr {[scan $octal %o] & 0xFF}]]
                        } else {
                            append out $e
                        }
                    }
                }
            }
            \r {
                # AN END-OF-LINE MARKER INSIDE A LITERAL STRING IS ONE BYTE,
                # AND THAT BYTE IS LF. 7.3.4.2: an end-of-line marker
                # appearing within a literal string without a preceding
                # backslash "shall be treated as a byte value of (0Ah),
                # irrespective of whether the end-of-line marker was a
                # CARRIAGE RETURN (0Dh), a LINE FEED (0Ah), or both". A CR
                # left as it was made the /Title of an imported file one byte
                # longer than the file means, and a CRLF two.
                if {[string index $bytes $pos] eq "\n"} {incr pos}
                append out \n
            }
            default {append out $c}
        }
    }
}

# THE BYTES A NAME MEANS (7.3.5.2): #xx decodes to its byte; a # NOT
# followed by two hex digits stays literal - broken files exist, and reading
# them as written loses less than refusing.
#
# One decoder, because two consumers compare names: [Parse] for every
# dictionary key of the file, and [UnmarkToken] for the tag and the property
# name of a marked-content bracket. The second used to compare the RAW text
# against names the first had already decoded, so a page whose property list
# is called /Pr#31 was compared as "/Pr#31" against "/Pr1".
proc ::tclpdf::importRead::DecodeName {raw} {
    if {[string first # $raw] < 0} {
        return $raw
    }
    set name {}
    set i 0
    set length [string length $raw]
    while {$i < $length} {
        set c [string index $raw $i]
        set hex [string range $raw [expr {$i + 1}] [expr {$i + 2}]]
        if {$c eq "#" && [string length $hex] == 2
                && [string is xdigit -strict $hex]} {
            append name [format %c [scan $hex %x]]
            incr i 3
        } else {
            append name $c
            incr i
        }
    }
    return $name
}

proc ::tclpdf::importRead::ParseToken {bytes posVar} {
    upvar 1 $posVar pos
    set start $pos
    while {![Delimiter [string index $bytes $pos]]} {
        incr pos
    }
    return [string range $bytes $start [expr {$pos - 1}]]
}

# A TOKEN OF DECIMAL DIGITS AS THE NUMBER IT MEANS. "An integer shall be
# written as one or more decimal digits optionally preceded by a sign"
# (7.3.3), so 0007 is seven and a file that writes "0007 0 R" or "0007 0 obj"
# is not damaged - qpdf reads it as object 7. Tcl does not, twice over: [expr]
# reads a leading zero as octal under 8.6, where 0010 is eight and 008 is no
# number at all and compares silently as zero, and as decimal under 9, so the
# same file was read two ways; and a plain string comparison against the
# cross-reference number makes "0007" and "7" two different objects.
#
# ONE HELPER FOR EVERY PLACE A WRITTEN NUMBER BECOMES A NUMBER THE READER
# WORKS WITH - and that is a rule of the reader, not a list of three: the
# "num gen R" lookahead, the "num gen obj" header, the header of an object
# stream, startxref, /Prev, the counts of a classic subsection, /Index and
# /Size of a cross-reference stream, /Length, and /N and /First of an object
# stream. Eleven, counted with [grep] on 2026-08-27; every one of them used
# to hand its token to [expr] or to [string range] unfiltered, and read the
# same valid file differently under the two interpreters.
#
# Trimming rather than [scan %lld], which is exact at any length. The token
# has to be an integer of 7.3.3 - decimal digits with an optional sign, and
# nothing else: the empty string comes back for anything that is not, so a
# caller tests one thing instead of two ([string is entier] is no help here,
# it takes 0x10 and 0b1). What is NOT normalised is a plain number OBJECT -
# that one is kept as written, so a copied object still round-trips byte for
# byte.
proc ::tclpdf::importRead::Decimal {token} {
    if {![regexp {^([-+]?)(\d+)$} $token -> sign digits]} {
        return {}
    }
    set value [string trimleft $digits 0]
    if {$value eq {}} {
        set value 0
    }
    if {$sign eq "-"} {
        return -$value
    }
    return $value
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
            return [list nm [DecodeName [ParseToken $bytes pos]]]
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
                    # ONE ENTRY PER KEY, ALWAYS. "A dictionary object is
                    # an associative table ... Multiple entries in the same
                    # dictionary shall not have the same key" (7.3.7), and
                    # what is read here is written back by [Serialize]: with
                    # [lappend] a foreign file's duplicate /BaseFont came out
                    # of this package duplicated again, so tclpdf answered a
                    # file that breaks 7.3.7 with a file of its own that
                    # breaks it (qpdf warns on the OUTPUT).
                    #
                    # WHICH ONE COUNTS: the LAST, which is what [Get] has
                    # always answered (it reads with [dict get]) and what
                    # qpdf and poppler do - qpdf says so in as many words,
                    # "dictionary has duplicated key /BaseFont; last
                    # occurrence overrides earlier ones". The standard leaves
                    # it undefined because it forbids the case; choosing the
                    # reading two other readers already have keeps this
                    # package from being the odd one out on a damaged file.
                    dict set pairs [lindex $key 1] \
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
            set start $pos
            set number [ParseToken $bytes pos]
            # THE WHOLE NUMBER GRAMMAR, not just its first byte (7.3.3). An
            # integer is "one or more decimal digits optionally preceded by a
            # sign", a real the same with one leading, trailing or embedded
            # PERIOD - and the standard says in as many words that a writer
            # "shall not use the PostScript language syntax for numbers with
            # non-decimal radices (such as 16#FFFE) or in exponential format
            # (such as 6.02E23)". Everything that starts like a number used to
            # become one here and Serialize wrote it back byte for byte, so a
            # foreign /ca 1e3 left this package again as /ca 1e3 and qpdf read
            # "unknown token while reading object; treating as string": tclpdf
            # answered an invalid file with an invalid file of its own. The
            # token is refused, NOT normalised - 1e3 turned into 1000 would
            # quietly decide what a damaged file meant.
            #
            # THE LIMIT OF THIS CHECK: it guards objects. Content streams are
            # copied byte for byte (only [Unmark] walks one, with a tokenizer
            # of its own), so an exponential number INSIDE a stream travels
            # through this package untouched.
            if {![regexp {^[+-]?(\d+\.?\d*|\.\d+)$} $number]} {
                return -code error -errorcode {TCLPDF IMPORT SYNTAX} \
                    "tclpdf: \"$number\" at offset $start of the imported PDF\
                    is not a number ISO 32000-2, 7.3.3 allows - digits with\
                    an optional sign and at most one period, and no\
                    exponential or radix form"
            }
            # "num gen R" is one object; the lookahead is undone when the
            # two following tokens are not "gen R". Both halves are plain
            # digits (7.3.10), which is stricter than [string is entier]: that
            # accepts 0x10 and 0b1, and a file saying "0x10 0 R" used to be
            # read as a reference to object sixteen.
            if {[regexp {^\d+$} $number]} {
                set mark $pos
                SkipWs $bytes pos
                if {[string match {[0-9]} [string index $bytes $pos]]} {
                    set gen [ParseToken $bytes pos]
                    SkipWs $bytes pos
                    if {[regexp {^\d+$} $gen]
                            && [string index $bytes $pos] eq "R"
                            && [Delimiter [string index $bytes \
                                [expr {$pos + 1}]]]} {
                        incr pos
                        return [list r \
                            [list [Decimal $number] [Decimal $gen]]]
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
# through the map. A reference to an object that was never copied names
# itself - it means the closure walk has a hole.
#
# THE MAP CARRIES THE GENERATION, because a reference is a NUMBER AND A
# GENERATION (7.3.10) and the two writers of this reader want opposite
# things of it:
#
#   {newNumber newGeneration}   the reference becomes exactly that. An
#                               IMPORT renumbers into a document of its own,
#                               where every copied object stands at
#                               generation 0 whatever generation it had in
#                               the file it came from - so import.tcl maps
#                               to {n 0}
#   newNumber                   the short form: the number is mapped, the
#                               reference KEEPS ITS OWN GENERATION. That is
#                               what an identity map means - an update
#                               (update.tcl) and a signature (sign.tcl)
#                               write into the file's OWN numbering, where
#                               "7 1 R" has to stay "7 1 R". Writing
#                               "7 0 R" there made the annotation of an
#                               object at generation 1 resolve to null, and
#                               the link was gone from the signed file
#                               without a word (measured 2026-08-27, qpdf
#                               --show-object on a signed q6-sign-gen.pdf)
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
        n {
            # ANNEX C.2 BOUNDS THE INTEGER, NOT THE REAL. A whole number
            # beyond +/-2147483647 written back as an integer token is one
            # no conforming reader has to be able to read - measured with
            # qpdf on a foreign /LW 3000000000, which a 32-bit reader turns
            # into null and drops the dictionary with. The value does not
            # change: the point makes the same digits a REAL (7.3.3), which
            # Annex C.2 bounds at about +/-3.403e38 instead, and [Parse]
            # has already refused anything past that. The digits are kept
            # as they stand rather than run through [pdfObj num], which
            # would take the detour through a double and turn twenty nines
            # into a one and twenty zeros.
            #
            # This is the rule [pdfObj num] applies to every number this
            # package writes itself (round 7), on the reading side.
            set whole [Decimal $payload]
            if {$whole ne {} && ($whole > 2147483647 || $whole < -2147483647)} {
                return $payload.
            }
            return $payload
        }
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
            lassign $payload number generation
            # Keyed on the pair first, on the bare number second: a map may
            # name one target per generation where the file uses more than
            # one, and the short form covers the common case where it does
            # not.
            if {[dict exists $map [list $number $generation]]} {
                set entry [dict get $map [list $number $generation]]
            } elseif {[dict exists $map $number]} {
                set entry [dict get $map $number]
            } else {
                return -code error \
                    -errorcode {TCLPDF IMPORT SERIALIZE} "tclpdf: reference\
                    to object $number, which the import never reached"
            }
            if {[llength $entry] == 2} {
                return "[lindex $entry 0] [lindex $entry 1] R"
            }
            return "$entry $generation R"
        }
        default {
            return -code error -errorcode {TCLPDF IMPORT SERIALIZE} \
                "tclpdf: cannot serialize \"$type\""
        }
    }
}

# All object numbers a parsed value refers to. NUMBERS, not pairs: the two
# callers outside this file (update.tcl, sign.tcl) build an IDENTITY map from
# them, where the reference keeps its own generation anyway - see [Serialize].
# The takeover, which renumbers into a document of its own and therefore has
# to tell one generation from another, walks with [RefPairs] below.
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

# One entry of a dictionary, or the empty string where the dictionary has
# none.
#
# AND THE NULL OBJECT IS "NONE". "Specifying the null object as the value of
# a dictionary entry shall be equivalent to omitting the entry entirely"
# (7.3.9, and 7.3.7 says it again) - so it is answered here, at the ONE place
# every consumer of this reader reads a key, rather than at each of them.
# Left to the consumers, a /Rotate null came back as a value that is not a
# number and the page was refused as "carries /Rotate \"\"", a /CropBox null
# as "is not an array of four numbers", a /Contents null as "is not a
# stream" - three refusals of a file the standard defines as readable, and
# one of them for a file this very reader writes null into (7.5.8.3, an
# unknown cross-reference entry type).
# EVERY REFERENCE OF A PARSED VALUE AS THE {number generation} PAIR IT IS.
# What [Refs] answers is enough to write into a file's own numbering; a COPY
# needs both halves, because a reference names an object only together with
# its generation (7.3.10): a page that names "4 0 R" and "4 1 R" names the
# object once and the null object once, and a walk that saw two 4s would
# copy one of them twice.
proc ::tclpdf::importRead::RefPairs {value {depth 0}} {
    if {$depth > 500} {
        return -code error -errorcode {TCLPDF IMPORT DEPTH} "tclpdf: imported\
            object nests deeper than this reader walks for references"
    }
    lassign $value type payload
    switch -- $type {
        r {return [list $payload]}
        d {
            set found {}
            foreach {- item} $payload {
                lappend found {*}[RefPairs $item [expr {$depth + 1}]]
            }
            return $found
        }
        a {
            set found {}
            foreach item $payload {
                lappend found {*}[RefPairs $item [expr {$depth + 1}]]
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
    set item [dict get $payload $key]
    if {[lindex $item 0] eq "z"} {
        return {}
    }
    return $item
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
#   xref      num -> {o offset generation} | {c objstmNum indexInStream} | f
#             The GENERATION is part of the entry because it is part of the
#             object's identity (7.3.10): a reference naming another one at
#             the same number points at the null object, not at what stands
#             there. A compressed object is at generation 0 by definition
#             (7.5.7), and a free entry defines no object at all.
#   gens      num -> the generation of that entry, or the empty string where
#             the entry defines no object. The same fact as the third word
#             of an "o" entry, written out once by [Enter] because every
#             reference that is followed asks for it and the walk of a large
#             page tree asks millions of times: reading it out of the entry
#             instead cost 13 % on a two-thousand-page file (measured
#             2026-08-27)
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
    # THE FILE, LOOKED AT BEFORE IT IS OPENED - here, at the one entry every
    # reading command goes through (pdf info, pages, fonts, metadata, fields,
    # pdf import, update open), so that a path someone typed is refused the
    # way this package refuses everything, naming itself and the path, and
    # not as Tcl's bare "couldn't open". Three cases, told apart the way
    # ::tclpdf::io tells them apart (io.tcl), because what the caller has to
    # do about each differs: a DIRECTORY exists, and [open] on one succeeds -
    # the raw "illegal operation on a directory" used to arrive from [read]
    # afterwards under POSIX EISDIR; an unreadable file arrived as EACCES.
    if {![file exists $path]} {
        return -code error -errorcode {TCLPDF IMPORT FILE} \
            "tclpdf: no file \"$path\""
    }
    if {[file isdirectory $path]} {
        return -code error -errorcode {TCLPDF IMPORT FILE} \
            "tclpdf: \"$path\" is a directory, not a PDF file"
    }
    if {![file readable $path]} {
        return -code error -errorcode {TCLPDF IMPORT FILE} \
            "tclpdf: \"$path\" is not readable"
    }
    set channel [open $path rb]
    set bytes [read $channel]
    close $channel
    set reader [dict create bytes $bytes path $path xref {} gens {} \
        trailer {d {}} objects {} buffers {} sections {} flavour {} \
        inprogress {}]
    # THE LAST %%EOF, and what may stand behind it. 7.5.5 puts %%EOF on the
    # last line of the file, and files that keep to it are the rule - but a
    # mail gateway, a print spooler and more than one archive system append a
    # line of their own, and such a file is not "not a PDF": every reader
    # opens it, and the page it shows is the page that was written. So the
    # tail is searched rather than anchored, in the same 1024 bytes 7.5.5
    # gives a reader for finding the trailer, and what stands behind the
    # %%EOF is passed over. A file with no startxref in that window is
    # refused as before, and the message says which of the two it is.
    set matches [regexp -all -inline -- \
        {startxref[ \t\r\n\f\x00]+(\d+)[ \t\r\n\f\x00]+%%EOF} \
        [string range $bytes end-1023 end]]
    if {![llength $matches]} {
        return -code error -errorcode {TCLPDF IMPORT FILE} "tclpdf: $path\
            carries no startxref in its last 1024 bytes - not a PDF, or a\
            truncated one"
    }
    # The LAST of them: an incremental update appends its own startxref, and
    # the newest section is the one to start the chain at.
    # Through [Decimal] like every other written number: "startxref
    # 0000000123" is what 7.5.5 asks for in a twenty-byte world, and [expr]
    # read it as octal under 8.6 and as decimal under 9.
    set offset [Decimal [lindex $matches end]]
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
    set offset [Decimal [lindex $previous 1]]
    if {[lindex $previous 0] ne "n" || $offset eq {} || $offset < 0} {
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
        # Both through [Decimal]: a subsection header of "0 010" is ten
        # entries, and [expr] made it eight under 8.6 - the last two objects
        # of the file then had no entry at all and were "referenced but not
        # in the cross-reference".
        set first [Decimal [ParseToken $bytes pos]]
        SkipWs $bytes pos
        set count [Decimal [ParseToken $bytes pos]]
        if {$first eq {} || $first < 0 || $count eq {} || $count < 0} {
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
            # TWENTY BYTES EXACTLY, and the shape is fixed: ten digits, a
            # space, five digits, a space, n or f, and a two-byte end of line
            # (7.5.4, "each line ... shall be exactly 20 bytes long"). A file
            # whose lines are nineteen - one space instead of two, or nine
            # digits of offset - drifts by one byte per entry, and what used
            # to be reported was the FIRST line the drift made unreadable,
            # several entries later, as "unreadable cross-reference line at
            # ...". That names a symptom at a place where nothing is wrong.
            # Named here instead, at the entry that is short, with the count
            # of the ones before it that were right.
            if {![regexp {^\d{10} \d{5} [nf]} $entry]} {
                return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
                    [dict get $reader path]: the cross-reference entry for\
                    object [expr {$first + $i}] at $pos is not the twenty\
                    bytes ISO 32000-2, 7.5.4 prescribes - ten digits, a\
                    space, five digits, a space, n or f, and a two-byte end\
                    of line. Read there:\
                    \"[string map {\r \\r \n \\n} $entry]\". $i entr[expr\
                    {$i == 1 ? {y} : {ies}}] of this subsection read before\
                    it, so the lines of this table are short and every offset\
                    from here on is wrong"
            }
            set kind [string index $entry 17]
            if {$kind eq "n"} {
                # The five digits between offset and keyword are the
                # GENERATION (7.5.4, Table 16) and they are kept: they say
                # WHICH object stands at that offset, and a reference naming
                # another generation is the null object (7.3.10). Read with
                # [scan %d], so the leading zeros of the fixed-width field
                # are decimal digits and not an octal number.
                Enter reader [expr {$first + $i}] \
                    [list o [scan [string range $entry 0 9] %d] \
                        [scan [string range $entry 11 15] %d]]
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
    # WHOSE OFFSET THIS IS, said here rather than left to [ObjectAt]. That
    # proc answers "no object at offset 404", which is true and names neither
    # startxref nor the cross reference - and an offset that is one byte off
    # is exactly the defect a file arrives with (measured 2026-08-26 on a
    # startxref raised by one; lowered by one it still reads, because the
    # white space is skipped). The caller of this proc is always the chain
    # walk, so the offset is always one a startxref or a /Prev named.
    if {[catch {ObjectAt reader $pos} outcome]} {
        return -code error -errorcode {TCLPDF IMPORT XREF} "tclpdf:\
            [dict get $reader path]: the cross-reference offset $pos points\
            at no object - startxref or a /Prev names a byte that is not the\
            beginning of one (ISO 32000-2, 7.5.5). The reader's own words for\
            it: [string trim [string map {tclpdf: {}} $outcome]]"
    }
    lassign $outcome value hasStream data
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
        set width [Decimal [lindex $item 1]]
        if {[lindex $item 0] ne "n" || $width eq {} || $width < 0} {
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
            lappend index [Decimal [lindex $item 1]]
        }
    } else {
        set index [list 0 [Decimal [lindex [Get $value Size] 1]]]
    }
    foreach number $index {
        if {$number eq {} || $number < 0} {
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
                1 {
                    # Field 3 of a type 1 entry is the GENERATION (7.5.8.3,
                    # Table 18) and its default is 0, which a /W of [1 n 0]
                    # produces on its own - the field arithmetic above
                    # leaves an absent field at zero.
                    Enter reader [expr {$first + $i}] [list o $f2 $f3]
                }
                2 {
                    # A compressed object is at generation 0: "the
                    # generation number of an object stored in an object
                    # stream shall be zero" (7.5.7), and field 3 of a type 2
                    # entry is its index in the stream instead.
                    Enter reader [expr {$first + $i}] [list c $f2 $f3]
                }
                default {
                    # "In PDF 1.5 through PDF 2.0, only types 0, 1, and 2 are
                    # allowed. Any other value shall be interpreted as a
                    # reference to the null object, thus permitting new entry
                    # types to be defined in the future" (7.5.8.3). A type
                    # nobody skipped was left out of the table altogether, and
                    # the object it stands for was then "referenced but not in
                    # the cross-reference" - a file the standard defines as
                    # readable was refused. Recorded as free, which resolves
                    # to null in [Object] AND shadows a live entry an older
                    # section carries for the same number, the same way type 0
                    # does. qpdf 12.4.0 hands out the older object there; the
                    # standard says the newest section decides.
                    Enter reader [expr {$first + $i}] f
                }
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
        dict set reader gens $number [EntryGeneration $entry]
    }
}

# WHICH GENERATION AN ENTRY DEFINES, or the empty string where it defines no
# object at all - a free entry, and the unknown entry type 7.5.8.3 makes one.
# The one place that knows the shape of an entry; [Enter] above asks it once
# per entry and writes the answer into "gens", so that following a reference
# is a dictionary lookup and not a walk of the entry.
proc ::tclpdf::importRead::EntryGeneration {entry} {
    switch -- [lindex $entry 0] {
        o {return [lindex $entry 2]}
        c {return 0}
        default {return {}}
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
# The same question is asked of a COMPRESSED object in [Object] below,
# against the pair in its object stream's own header (7.5.7) - this proc
# never sees one, and until 2026-08-27 nothing else asked either.
#
# BOTH NUMBERS OF THE HEADER, because both are the object's name: "expectGen"
# names the generation the cross-reference recorded, and a header that says
# another one is the same corrupt table as a header that says another number.
# The generation used to be read and thrown away here, which is where the
# whole "a generation is not part of the identity" of this reader began.
proc ::tclpdf::importRead::ObjectAt {readerVar offset {expect {}} {expectGen {}}} {
    upvar 1 $readerVar reader
    set bytes [dict get $reader bytes]
    set pos $offset
    SkipWs $bytes pos
    set found [ParseToken $bytes pos]
    SkipWs $bytes pos
    set foundGen [ParseToken $bytes pos]
    SkipWs $bytes pos
    if {[ParseToken $bytes pos] ne "obj"} {
        return -code error -errorcode {TCLPDF IMPORT OBJECT} "tclpdf:\
            [dict get $reader path]: no object at offset $offset"
    }
    if {$expect ne {} && [Decimal $found] ne [Decimal $expect]} {
        return -code error -errorcode {TCLPDF IMPORT OBJECT} "tclpdf:\
            [dict get $reader path]: the cross-reference points object $expect\
            at offset $offset, where object $found is written"
    }
    if {$expectGen ne {} && [Decimal $foundGen] ne [Decimal $expectGen]} {
        return -code error -errorcode {TCLPDF IMPORT OBJECT} "tclpdf:\
            [dict get $reader path]: the cross-reference puts object $expect\
            at generation $expectGen at offset $offset, where\
            \"$found $foundGen obj\" is written - a generation is part of an\
            object's name (ISO 32000-2, 7.3.10), so these are two objects\
            and not two versions of one"
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
            {*}[lindex $length 1]] 0]
    }
    # Through [Decimal]: "/Length 0025" is twenty-five bytes, and [expr]
    # made it twenty-one under 8.6 - the stream then did not end at
    # endstream and the whole file was refused.
    set length [Decimal [lindex $length 1]]
    if {$length eq {} || $length < 0} {
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

# THE HEADER OF AN OBJECT STREAM, read once per container and bounded by the
# bytes that are actually there (7.5.7, Table 16). /N and /First arrive from
# the file, and until 2026-08-27 only their type was checked: the walk then
# read "2 * /N" tokens from wherever it got to, so a 400-byte file saying
# /N 20000000 spent 78 seconds and 3.4 GB building a list of empty strings -
# and was ACCEPTED at the end of it, because the one slot the caller wanted
# happened to be there. Work has to follow the file, not a number in it.
#
# Three bounds, in this order: /First lies inside the decoded stream; the
# header before /First cannot hold more than one pair per four bytes ("1 0 "
# is the shortest, and only the last pair may go without its separator); and
# every one of the 2N words is a non-negative integer whose offset stays
# inside the object part. The order of the offsets is NOT checked - the
# standard has them increasing, but files with them out of order are readable
# and qpdf reads them, so refusing would turn a working file away.
#
# The same bound is the reason the header is parsed here rather than at every
# lookup: it is the file's own header, one per object stream, and the callers
# below share it.
proc ::tclpdf::importRead::ObjstmHeader {readerVar container data first n} {
    upvar 1 $readerVar reader
    set length [string length $data]
    if {$first > $length} {
        return -code error -errorcode {TCLPDF IMPORT OBJSTM} "tclpdf:\
            [dict get $reader path]: object stream $container says its first\
            object begins at byte $first, past the $length bytes of its\
            decoded stream"
    }
    if {$n > ($first + 1) / 4} {
        return -code error -errorcode {TCLPDF IMPORT OBJSTM} "tclpdf:\
            [dict get $reader path]: object stream $container announces $n\
            objects, more than the $first bytes before its first object can\
            number"
    }
    set head [string range $data 0 [expr {$first - 1}]]
    set room [expr {$length - $first}]
    set pos 0
    set header {}
    for {set i 0} {$i < 2 * $n} {incr i} {
        SkipWs $head pos
        set word [ParseToken $head pos]
        set pair [expr {$i / 2 + 1}]
        set what [expr {$i % 2 ? "offset" : "object number"}]
        if {![regexp {^\d+$} $word]} {
            return -code error -errorcode {TCLPDF IMPORT OBJSTM} "tclpdf:\
                [dict get $reader path]: the header of object stream\
                $container reads \"$word\" where the $what of its pair $pair\
                belongs"
        }
        # Through [Decimal] like every other written number: "008" is a legal
        # header word, and expr reads it as octal.
        set value [Decimal $word]
        if {$i % 2 && $value >= $room} {
            return -code error -errorcode {TCLPDF IMPORT OBJSTM} "tclpdf:\
                [dict get $reader path]: the header of object stream\
                $container puts its object $pair at $value bytes behind\
                /First, past the $room bytes that follow it"
        }
        lappend header $value
    }
    return $header
}

# THE GENERATION THE FILE GIVES THAT OBJECT, or the empty string where the
# file defines no object of that number at all - no entry, or a free one. A
# reference to one of those is the null object whatever generation it names
# (7.3.10), which is why both answer the same thing here.
#
# One place, because the two flavours of cross-reference record it in two
# different fields and a compressed object has none at all (7.5.7).
proc ::tclpdf::importRead::Generation {readerVar number} {
    upvar 1 $readerVar reader
    if {![dict exists $reader gens $number]} {
        return {}
    }
    return [dict get $reader gens $number]
}

# The object by number, through the cross-reference - directly stored or
# inside an object stream (7.5.7; those never hold streams themselves).
#
# WITH A GENERATION, THE ANSWER IS 7.3.10's. Every caller that got the number
# out of a REFERENCE hands the generation over with it ([Resolve] does it for
# all of them), and then a number the file does not define at that generation
# - a generation of its own, a free entry, no entry at all - is the null
# object: "An indirect reference to an undefined object shall not be
# considered an error by a PDF processor; it shall be treated as a reference
# to the null object". Without a generation the caller is naming an object
# rather than following a reference ([update body], [update replace]), and
# there a number the file does not define stays the refusal it was: the
# caller typed it.
proc ::tclpdf::importRead::Object {readerVar number {generation {}}} {
    upvar 1 $readerVar reader
    set known [dict exists $reader xref $number]
    if {$generation ne {}} {
        if {$known} {
            set live [dict get $reader gens $number]
        } else {
            set live {}
        }
        # The cheap comparison first: a reference that came out of [Parse]
        # carries a generation that went through [Decimal] already, and the
        # overwhelming case is "0" against "0".
        if {$live ne $generation
                && ($live eq {} || [Decimal $generation] ne $live)} {
            # NOT put in the cache: the cache is keyed on the number, and
            # the same number may be named by a reference that resolves and
            # by one that does not.
            return [list {z {}} 0 {}]
        }
    }
    if {[dict exists $reader objects $number]} {
        return [dict get $reader objects $number]
    }
    if {!$known} {
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
                set object [ObjectAt reader [lindex $entry 1] $number \
                    [lindex $entry 2]]
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
                    # Through [Decimal], like every other written number:
                    # "/First 0014" is fourteen, and [expr] made it twelve
                    # under 8.6 - the header was then read from the middle
                    # of a word, the catalogue came out as a keyword, and
                    # [pdf pages] answered the EMPTY list without a word.
                    set n [Decimal \
                        [lindex [Resolve reader [Get $value N]] 1]]
                    set first [Decimal \
                        [lindex [Resolve reader [Get $value First]] 1]]
                    if {$n eq {} || $n < 0 || $first eq {} || $first < 0} {
                        return -code error -errorcode {TCLPDF IMPORT OBJSTM} \
                            "tclpdf: [dict get $reader path]: object stream\
                            $container has no usable /N and /First"
                    }
                    dict set reader buffers $container \
                        [list $data $first $n \
                            [ObjstmHeader reader $container $data $first $n]]
                }
                lassign [dict get $reader buffers $container] \
                    data first n header
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
                # THE HEADER SAYS WHICH OBJECT STANDS AT THAT INDEX, AND
                # IT IS HELD AGAINST THE NUMBER THAT WAS ASKED FOR. "The
                # first integer in each pair shall represent the object
                # number of a compressed object" (7.5.7) - so the pair is
                # the object's name, exactly as the "num gen obj" header is
                # for an uncompressed one, and [ObjectAt] refuses a
                # mismatch there for the same reason. Until 2026-08-27 the
                # even word of the pair was never read: a cross-reference
                # that pointed object 4 at index 0 of a stream whose header
                # says the index-0 object is 9 handed out object 9 under
                # the name 4, and a page came out with the WRONG FONT and
                # no complaint from any tool (qpdf refuses the same file).
                set said [lindex $header [expr {2 * $index}]]
                if {$said ne $number} {
                    return -code error -errorcode {TCLPDF IMPORT OBJSTM} \
                        "tclpdf: [dict get $reader path]: the\
                        cross-reference puts object $number at index $index\
                        of object stream $container, whose own header names\
                        object $said there"
                }
                set pos [expr {$first + [lindex $header \
                    [expr {2 * $index + 1}]]}]
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
#
# THE GENERATION GOES WITH THE NUMBER. A reference names both (7.3.10), and
# [Object] holds the pair against the cross-reference - so a reference to a
# generation the file does not have at that number resolves to the null
# object, which this proc answers as "nothing" for the same reason [Get]
# does (7.3.9). A direct null answers the same way, so that a consumer never
# has to know the difference between a key that is absent, a key that is
# null, and a key naming an object that is not there.
proc ::tclpdf::importRead::Resolve {readerVar value} {
    upvar 1 $readerVar reader
    switch -- [lindex $value 0] {
        r {
            set item [lindex [Object reader {*}[lindex $value 1]] 0]
            if {[lindex $item 0] eq "z"} {
                return {}
            }
            return $item
        }
        z {return {}}
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
        # THE ONE HEADER NUMBER THAT BINDS NOTHING GETS A BOUND HERE. What a
        # deflate stream unpacks to is in the data, not in the dictionary,
        # and a reader of foreign files has to say how far it will follow -
        # the ceiling and the measurement behind it stand in filter.tcl. Only
        # the READER passes it: the picture side of this package unpacks its
        # own PNG and TIFF data, where the size is known from the pixels.
        if {$decoder eq "decodeFlate"} {
            set extra [list $::tclpdf::filter::flateLimit]
        }
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
        if {[catch {::tclpdf::filter::$decoder $data {*}$extra} decoded \
                options]} {
            # A stream that is too big is not a stream that cannot be
            # decoded, and the caller has to do something else about it -
            # so the class travels, with the file's name put in front of
            # the decoder's sentence.
            if {[lrange [dict get $options -errorcode] 0 2]
                    eq {TCLPDF FILTER ROOM}} {
                return -code error -errorcode {TCLPDF IMPORT ROOM} "tclpdf:\
                    [dict get $reader path]: $what is a /$name stream this\
                    package will not unpack: [string trim [string map \
                        {tclpdf: {}} $decoded]]"
            }
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
                # /Columns is the number of SAMPLES per row (Table 8) -
                # not a byte count, which is what this comment used to say
                # while [filter::decodePredictor] next door computed
                # (columns * colors * depth + 7) / 8 from it and was right.
                # It has to be a positive integer: zero or a non-number
                # would drive the predictor's own row arithmetic onto a raw
                # error with no file named.
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

# ------------------------------------------- a foreign content stream
#
# THE MARKED CONTENT OF A FOREIGN PAGE, TAKEN OUT.
#
# A tagged page carries its structure in brackets - "/P << /MCID 0 >> BDC
# ... EMC" (14.7.4.2) - whose numbers index the parent tree of the file they
# stand in. Taking the page over as a form XObject leaves those numbers
# behind: the tree does not travel, and a marked-content sequence inside an
# XObject is a content item only through the XObject's own /StructParents,
# which the import writes none of. What is left is a mark pointing at
# nothing, inside the artifact or Figure bracket [form place] puts around
# the placement - and a reader that takes marks seriously (Acrobat does,
# when it reads a page aloud) then finds paragraphs belonging to no tree.
#
# So they come out. Nothing else does: the operators between the brackets
# are the page description and are copied byte for byte.
#
# WHAT GOES IS WHAT SPEAKS ABOUT THE FOREIGN FILE'S STRUCTURE TREE, and that
# is two things:
#
#   an /MCID in the property list
#                       the index into the parent tree (14.7.4.2), and the
#                       one thing in a bracket that points out of the stream
#   /Artifact           the bracket that says "this content is NOT in the
#                       tree" (14.8.2.2). That sentence is the foreign
#                       file's, about the foreign file's tree, and it does
#                       not survive the journey: the page arrives here as a
#                       PICTURE, and what [form place] puts around it says
#                       what it is in THIS document - an artifact under
#                       -artifact 1, a Figure under -alt. Left standing, an
#                       /Artifact bracket inside a Figure is tagged content
#                       inside content marked as artifact, which ISO
#                       14289-1, 7.1 forbids and veraPDF names as 7.1-1 and
#                       7.1-2 (measured 2026-08-27 on an imported
#                       05.07-accessible placed with -alt). Under -artifact 1
#                       the placement is an artifact anyway, so nothing is
#                       lost there either
#
# Everything else a bracket can say stands on its own two feet and stays:
#
#   /OC /oc1 BDC        optional content (8.11.3.2). The bracket is what
#                       SWITCHES the content inside it - dropping it would
#                       make a hidden layer of a letterhead permanently
#                       visible, the very mistake import.tcl avoids when it
#                       carries the groups' states over
#   /Span << /Lang ... >> BDC
#                       a property that says something about the content
#                       rather than about a tree
#
# A BMC has no property list at all (8.10.2.2 gives it a tag and nothing
# else), so a BMC never carries an /MCID - but it does carry a tag, and
# "/Artifact BMC" is the commonest artifact bracket of all.
#
# The property list is an inline dictionary or the NAME of an entry in the
# page's /Properties, and both are looked at: the caller hands over the
# names whose dictionaries hold an /MCID, since resolving them is the
# reader's business and not this walk's.
#
# HOW MUCH OF THE STREAM IS UNDERSTOOD: enough to tell an operator from an
# operand, which means literal and hexadecimal strings (an operator name
# inside one is text, not an operator), names, comments, dictionaries,
# arrays and inline images, whose binary data may hold anything at all. A
# stream this walk does not get to the end of comes back UNCHANGED - a mark
# left standing is a blemish, a content stream cut in half is a lost page.
# A stream carrying no mark at all is answered without being walked - BMC as
# well as BDC since the artifact bracket goes, and a page whose only marks
# are "/Artifact BMC" used to be handed back untouched by this very line.
proc ::tclpdf::importRead::Unmark {content {marked {}}} {
    if {![string match *BDC* $content] && ![string match *BMC* $content]} {
        return $content
    }
    set length [string length $content]
    set out {}
    set pos 0
    set run -1
    set operands {}
    set stack {}
    while {1} {
        SkipWs $content pos
        if {$pos >= $length} {
            break
        }
        set from $pos
        set token [UnmarkToken $content $length pos]
        if {$token eq {}} {
            # Something this walk does not understand - an unterminated
            # string, a stream that ends inside a token.
            return $content
        }
        if {$run < 0} {
            set run $from
        }
        lassign $token kind text
        if {$kind ne "op"} {
            lappend operands $text
            continue
        }
        switch -- $text {
            BDC {
                # The operand run holds the tag and the property list and
                # nothing else - a BDC takes no string operand - so the raw
                # text answers the /MCID question.
                set keep [expr {![UnmarkForeign [lindex $operands 0] \
                    [lindex $operands 1] \
                    [string range $content $run [expr {$pos - 1}]] $marked]}]
                lappend stack $keep
                if {$keep} {
                    append out [string range $content $run [expr {$pos - 1}]] \n
                }
            }
            BMC {
                # No property list, so no /MCID - but the tag is there, and
                # "/Artifact BMC" is one.
                set keep [expr {![UnmarkForeign [lindex $operands 0] {} {} \
                    $marked]}]
                lappend stack $keep
                if {$keep} {
                    append out [string range $content $run [expr {$pos - 1}]] \n
                }
            }
            EMC {
                if {![llength $stack]} {
                    # More EMC than brackets: the stream was already
                    # unbalanced, and taking one out would not mend it.
                    append out [string range $content $run [expr {$pos - 1}]] \n
                } else {
                    set keep [lindex $stack end]
                    set stack [lrange $stack 0 end-1]
                    if {$keep} {
                        append out \
                            [string range $content $run [expr {$pos - 1}]] \n
                    } elseif {$run < $from} {
                        # Operands standing before an EMC that goes are not
                        # the bracket's and stay.
                        append out \
                            [string range $content $run [expr {$from - 1}]] \n
                    }
                }
            }
            BI {
                # An inline image: from BI to EI the bytes are the image's,
                # and EI is found the way every reader finds it - as a token
                # of its own after the data (8.9.7).
                if {![UnmarkInlineImage $content $length pos]} {
                    return $content
                }
                append out [string range $content $run [expr {$pos - 1}]] \n
            }
            default {
                append out [string range $content $run [expr {$pos - 1}]] \n
            }
        }
        set run -1
        set operands {}
    }
    if {$run >= 0} {
        append out [string range $content $run [expr {$length - 1}]] \n
    }
    if {[llength $stack]} {
        # Brackets left open. The stream was unbalanced before this walk
        # touched it, and a half-stripped one is worse than the original.
        return $content
    }
    return [string trimright $out \n]
}

# WHETHER A BRACKET OF THE FOREIGN STREAM SPEAKS ABOUT THE FOREIGN FILE'S
# STRUCTURE TREE - the whole rule of [Unmark], in one predicate rather than
# once per bracket kind, so that BMC and BDC cannot drift apart.
#
#   tag        the bracket's tag, as a name with its slash ("/Artifact")
#   property   the property list operand where it is a NAME, empty otherwise
#   text       the bracket's own bytes, where an inline property list may
#              hold the /MCID; empty for a BMC, which has no property list
#   marked     the names of the page's /Properties entries whose dictionary
#              carries an /MCID - resolving them is the reader's business
#              and not this walk's, so the caller hands them over
proc ::tclpdf::importRead::UnmarkForeign {tag property text marked} {
    if {$tag eq "/Artifact"} {
        return 1
    }
    if {$text ne {} && [regexp {/MCID\M} $text]} {
        return 1
    }
    return [expr {$property ne {} && $property in $marked}]
}

# One token, from its first byte; posVar ends up behind it. Answers
# {kind text} - kind "op" for an operator, anything else for an operand - or
# the empty string where the stream ends inside the token. The operand text
# is only ever looked at for a name, so the string branches answer empty.
proc ::tclpdf::importRead::UnmarkToken {content length posVar} {
    upvar 1 $posVar pos
    set c [string index $content $pos]
    switch -- $c {
        ( {
            # A literal string (7.3.4.2): parentheses nest, a backslash
            # escapes the byte after it whatever that byte is. Not
            # [ParseString], which DECODES - here the bytes stay as written
            # and only their end is wanted.
            set depth 0
            while {$pos < $length} {
                set c [string index $content $pos]
                if {$c eq "\\"} {
                    incr pos 2
                    continue
                }
                incr pos
                if {$c eq "("} {
                    incr depth
                } elseif {$c eq ")"} {
                    incr depth -1
                    if {$depth == 0} {
                        return [list str {}]
                    }
                }
            }
            return {}
        }
        < {
            if {[string index $content [expr {$pos + 1}]] eq "<"} {
                incr pos 2
                return [list punct <<]
            }
            set end [string first > $content $pos]
            if {$end < 0} {
                return {}
            }
            set pos [expr {$end + 1}]
            return [list hex {}]
        }
        > {
            incr pos [expr {[string index $content [expr {$pos + 1}]] eq ">"
                ? 2 : 1}]
            return [list punct >>]
        }
        \[ - \] - \{ - \} - ) {
            incr pos
            return [list punct $c]
        }
        / {
            # A name (7.3.5), through the same decoder every other name of
            # this reader goes through - what is compared here (the tag of a
            # bracket, the name of a property list) is compared against
            # names that came out of [Parse].
            incr pos
            return [list name /[DecodeName [ParseToken $content pos]]]
        }
    }
    # A number, a keyword or an operator: everything to the next delimiter.
    set text [ParseToken $content pos]
    if {$text eq {}} {
        # A delimiter [Delimiter] knows and this walk does not - the stream
        # is not one it may rewrite.
        return {}
    }
    if {[string is double -strict $text] || $text in {true false null}} {
        return [list value $text]
    }
    return [list op $text]
}

# From just past BI to just past EI. Answers 0 where the image has no end,
# which is a stream this walk gives back untouched.
proc ::tclpdf::importRead::UnmarkInlineImage {content length posVar} {
    upvar 1 $posVar pos
    # The dictionary entries first, up to the ID that introduces the data.
    while {$pos < $length} {
        SkipWs $content pos
        if {$pos >= $length} {
            return 0
        }
        set token [UnmarkToken $content $length pos]
        if {$token eq {}} {
            return 0
        }
        if {[lindex $token 0] eq "op" && [lindex $token 1] eq "ID"} {
            break
        }
    }
    if {$pos >= $length} {
        return 0
    }
    # Exactly one byte of white space after ID, then the data (8.9.7).
    incr pos
    while {$pos < $length} {
        set at [string first EI $content $pos]
        if {$at < 0} {
            return 0
        }
        if {[Delimiter [string index $content [expr {$at - 1}]]]
                && [Delimiter [string index $content [expr {$at + 2}]]]} {
            set pos [expr {$at + 2}]
            return 1
        }
        set pos [expr {$at + 2}]
    }
    return 0
}

# ------------------------------------------------------------- the version
#
# WHAT VERSION A FILE CLAIMS FOR ITSELF. The header names it (7.5.2), and
# from PDF 1.4 on the catalogue's /Version overrides it - upwards only
# (7.5.5: the entry is a name object, and it counts "if it is later than the
# version specified in the file's header"). The higher of the two is what
# the file says it needs.
#
# Two consumers, which is why it lives here: [pdf info] reports both numbers
# separately (importInfo.tcl), and [pdf import] enters the source's version
# as a floor of the document it copies the page into (import.tcl).

# The header alone, looked for in the first kilobyte rather than at byte 0: a
# file with junk in front of its header is what Annex H tells a reader to
# cope with, and the cross-reference offsets of such a file are the ones this
# reader has just followed.
proc ::tclpdf::importRead::HeaderVersion {bytes} {
    if {[regexp {%PDF-(\d+\.\d+)} [string range $bytes 0 1023] -> version]} {
        return $version
    }
    return {}
}

# The higher of the header and the catalogue's /Version, or the empty string
# where the file names neither in a shape this package knows. A version this
# package does not write (a 1.8 of somebody's invention) is answered as it
# stands - the caller decides what to do with it.
proc ::tclpdf::importRead::Version {readerVar} {
    upvar 1 $readerVar reader
    set version [HeaderVersion [dict get $reader bytes]]
    set catalogue [Resolve reader [Get [dict get $reader trailer] Root]]
    set claimed [Resolve reader [Get $catalogue Version]]
    if {[lindex $claimed 0] eq "nm"
            && [regexp {^\d+\.\d+$} [lindex $claimed 1]]
            && ($version eq {}
                || [package vcompare [lindex $claimed 1] $version] > 0)} {
        set version [lindex $claimed 1]
    }
    return $version
}

# ------------------------------------------------------------ the takeover

package provide tclpdf::importRead 1.6
