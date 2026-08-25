#
# tclpdf - PDF generation for Tcl
#
# update - writing an incremental update onto an existing file (ISO 32000-2,
#          7.5.6)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# What an incremental update is, in the words of 7.5.6: "changes shall be
# appended to the end of the file, leaving its original contents intact". The
# cross-reference section of the update carries "entries only for objects that
# have been changed, replaced, or deleted"; the added trailer carries every
# entry of the previous one except Prev, plus a Prev of its own naming the
# previous cross-reference section; and every trailer ends in its own %%EOF.
#
# Why this module exists at all: a second signature cannot be written any
# other way. A signature covers the bytes of the file it sits in, so signing
# again means leaving those bytes exactly where they are and appending.
#
# The two halves it stands between are both built already: import.tcl reads a
# foreign file - its trailer, its cross-reference chain and the objects behind
# it - and writer.tcl counts every byte it writes, because a cross-reference
# offset is measured from the %PDF- header. An update needs both: the numbers
# the file already uses, and offsets that continue where the file ends.
#
# ---------------------------------------------------------------------------
# THE API, AND WHY IT IS THIS ONE
# ---------------------------------------------------------------------------
#
#   set upd [::tclpdf::update open invoice.pdf]
#   set annot [$upd add "<< /Type /Annot /Subtype /Widget ... >>"]
#   $upd replace 4 "<< /Type /Page ... /Annots \[[$upd ref $annot]\] >>"
#   $upd write
#   $upd destroy
#
# A PACKAGE COMMAND, NOT A DOCUMENT METHOD. A document object holds a page
# tree, resources, fonts and an event bus, and every one of them describes a
# file this package is about to write from nothing. An update has none of
# that: what it works on is a finished file on disk, made by anyone, whose
# object graph is not in memory and cannot be put there - the objects are
# reachable, but what they mean, which of them a change would invalidate and
# what else points at them is exactly the knowledge a reader does not have.
# So the entry sits next to [::tclpdf::sign digest] and [::tclpdf::sign
# embed], which stand on the same ground for the same reason: a finished file,
# addressed by its path.
#
# THE HANDLE SPEAKS THE WRITER'S VOCABULARY. [reserve], [put], [add],
# [addStream], [stream], [ref], [body] and [count] mean here exactly what they
# mean on ::tclpdf::writer::pdf. That is deliberate and it is the point of the
# shape: a builder written against the writer - the signature dictionary, the
# widget, the AcroForm entry - can be pointed at an update session without
# being rewritten. Anything else would mean a second signature needing a
# second implementation of the objects a first signature already builds.
#
# WHAT MAY BE REPLACED, WHAT MAY ONLY BE ADDED:
#
#   [add] hands out numbers that the file does not use yet, counting up from
#   its /Size - which Table 15 defines as one greater than the highest object
#   number in the file. A free number of the original is NEVER recycled:
#   reusing one means raising its generation number and re-threading the free
#   list, and the file cannot say what still points at it.
#
#   [replace] takes a number the file already defines, at generation 0, and
#   writes a second copy of that object behind the original one. Both copies
#   stay in the file - that is what 7.5.6 prescribes and what makes the update
#   safe for a signature that covers the first copy - and the added
#   cross-reference entry decides which one a reader sees.
#
#   Two kinds of object are refused for replacement by name: an object stream
#   (/Type /ObjStm), because the objects compressed inside it would keep
#   pointing at the copy that is no longer read, and a cross-reference stream
#   (/Type /XRef), because it is the file's own bookkeeping and not content.
#
#   DELETION IS NOT BUILT. 7.5.6 provides for it - a free entry with the
#   generation raised by one, threaded into the free list that starts at
#   object 0 - and it is refused here rather than half-built, because a
#   deletion is the one change whose consequences are not visible from the
#   file: nothing in an update tells us which other objects point at the
#   object being dropped, and a dangling reference produces a file that opens
#   and renders with pieces missing. What this module writes therefore never
#   frees anything, and entry 0 is written as the unchanged head of an empty
#   free list.
#
# THE ADDED TRAILER is the previous one, minus the keys that belong to the
# section rather than to the file, plus /Size, /Prev and a changing /ID. The
# previous one is taken as import.tcl merged it over the whole /Prev chain,
# newest first, which is the same set of keys a conforming file repeats in
# every trailer and one key MORE than a file that forgot to repeat /Info.
# Dropped: /Prev and /XRefStm, which name the previous section; /Size, which
# is recomputed; and /Type, /Length, /Filter, /DecodeParms, /W, /Index and
# /DL - the entries a cross-reference STREAM carries in the same dictionary as
# its trailer keys (7.5.8.2). Measured on a qpdf-made file: without that last
# group the added classic trailer inherits "/Type /XRef /Length 34 /Filter
# /FlateDecode /W [1 2 1]" and describes a stream that is not there.
#
# /ID travels the way 14.4 prescribes: the first string is permanent and is
# copied through unchanged, the second is "a changing identifier based on the
# PDF file's contents at the time it was last updated" and is recomputed - as
# the first 16 bytes of a SHA-256 over the length of the original file and the
# bytes this update appends before its cross-reference section. Content-based
# and therefore repeatable: writing the same update twice produces the same
# file, which is the property document.tcl already keeps for a second [write].
# A caller who needs another value sets it with [id].
#
# /Info AND /Metadata ARE NOT TOUCHED. Both are objects of the file, and this
# module writes a second copy of an object only where [replace] was called for
# it: /Info travels as the reference it is, and the XMP packet is not even
# looked at. That is deliberate and it is measured, not squeamishness - other
# writers rewrite both on every update, and on a PDF/A file a freshly built
# XMP packet that omits pdfaid:part turns an archivable invoice into an
# ordinary PDF while every structural check still passes. An update made here
# changes the metadata when, and only when, the caller replaces those objects
# itself, and then it is the caller who carries the claim forward. What 7.5.6
# NOTE 4 and H.7.5 recommend - keeping the embedded XML up to date, "preserving
# all tags not directly updated" - is therefore the caller's to do, with the
# old packet in hand from [body].
#
# ---------------------------------------------------------------------------
# A CLASSIC TABLE ONTO A FILE THAT USES CROSS-REFERENCE STREAMS
# ---------------------------------------------------------------------------
#
# The update written here is always a classic cross-reference table (7.5.4),
# whatever the file it is appended to uses - and 29 of 32 foreign files in the
# reference stock use a cross-reference stream. What that rests on, in the
# order the argument actually runs:
#
#   THE STANDARD DOES NOT FORBID IT - which is less than saying it allows it,
#   and it is the honest wording. The one sentence that comes close reads:
#   "For PDF files that use cross-reference streams entirely (that is, PDF
#   files that are not hybrid-reference files) the keywords xref and trailer
#   shall no longer be used" (7.5.8.1). Reading that as permission because the
#   appended table makes the file no longer one that uses streams "entirely"
#   is circular, and it is not the reason given here. The reason is that no
#   clause states what the flavour of a section must be given the flavour of
#   the previous one, and Table 15 describes /Prev as "the byte offset ... to
#   the beginning of the previous cross-reference stream" - a wording that
#   takes a classic trailer pointing at a stream for granted.
#
#   FOUR READERS TAKE IT. Measured on 2026-08-21: a tclpdf document was turned
#   into a cross-reference-stream file with "qpdf --object-streams=generate",
#   so that every object of it lives inside an object stream; an update was
#   appended that adds an annotation and REPLACES the page object, which in
#   the original is a compressed object inside that object stream. qpdf
#   --check found no syntax or stream encoding errors, pdfinfo read the file
#   and reported the replaced page's new /Rotate, and "qpdf --show-object"
#   answered with the NEW page dictionary - the classic entry overrides a
#   compressed one. Measured independently the same day on doubly signed
#   files: pdftotext and pyHanko read the same construction. veraPDF reported
#   exactly the two rules the added annotation breaks by itself (6.3.2-1 and
#   6.3.3-1: no /AP, no flags) and no rule that the update mechanism brings,
#   on a PDF/A-3B document that passed before the update.
#
#   AND IT TAKES NOTHING AWAY. The reader a classic section would shut out is
#   one that reads no cross-reference streams at all, i.e. a PDF 1.4 reader -
#   and such a reader cannot open the ORIGINAL either. Appending a stream, on
#   a file that has none, would shut out a reader that can open the original
#   today.
#
# What is NOT written, and is a different thing entirely: a hybrid-reference
# file (7.5.8.4). /XRefStm names a stream that COMPLETES the same section for
# readers that understand it, so that objects hidden from an old reader can be
# seen by a new one. That is a way to publish two views of one section, and an
# update needs exactly one. A /XRefStm found in the file being updated is read
# by import.tcl and dropped from the added trailer, where it would name a
# section that is no longer the previous one.
#
# WHAT ELSE IS NOT BUILT, each refused by name rather than written wrong:
#
#   An encrypted original. import.tcl refuses it already, and it is the right
#   answer here too: every string and stream this update appends would have to
#   be encrypted with the file's own key, which means decrypting the file
#   first.
#
#   An update in a cross-reference stream. It would save nothing worth having
#   (measured over the corpus, cross-reference streams save 1.5 % to 3.1 % on
#   a whole file, and an update is a handful of objects) and it would cost the
#   readers that a classic table costs nothing.
#
#   Raising the file's version. The header is inside the bytes that stay
#   untouched, so an update can only raise the version the way 7.5.6 NOTE 4
#   describes it - a /Version entry in a replaced catalog - and that is the
#   caller's replacement to write, not this module's to guess.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::io 1.0-
package require tclpdf::importRead 1.0-
package require tclpdf::writer 1.0-
package require tclpdf::crypto 1.0-

namespace eval ::tclpdf::update {
  namespace export {[a-z]*}
  namespace ensemble create

  # The keys of the previous trailer that must not travel into the added one.
  # See the head of this file for what each group is and what it costs when
  # one of them does travel.
  variable dropped {Prev XRefStm Size Type Length Filter DecodeParms W Index DL}
}

# Open an existing file for continuation. Answers a handle whose methods are
# below; [destroy] releases it, and the file is not touched until [write].
proc ::tclpdf::update::open {path} {
  return [::tclpdf::update::Session new $path]
}

oo::class create ::tclpdf::update::Session {
  variable tclpdfReader tclpdfPath tclpdfBase tclpdfPrev tclpdfHigh \
      tclpdfBodies tclpdfOrder tclpdfOverrides tclpdfId

  constructor {path} {
    # The reader does the reading AND the refusing: a file without a
    # startxref, a circular /Prev chain and an encrypted file are all its
    # errors, and they are the same three an update has to make.
    set tclpdfReader [::tclpdf::importRead::Open $path]
    set tclpdfPath $path
    set tclpdfBase [string length [dict get $tclpdfReader bytes]]
    set tclpdfPrev [dict get $tclpdfReader startxref]
    set tclpdfBodies {}
    set tclpdfOrder {}
    set tclpdfOverrides {}
    set tclpdfId {}

    set trailer [dict get $tclpdfReader trailer]
    if {[::tclpdf::importRead::Get $trailer Root] eq {}} {
      return -code error "tclpdf: $path has no /Root in its trailer - an\
          update carries the previous trailer forward, and there is no\
          document to carry"
    }

    # Where the new numbers start. /Size is "1 greater than the highest object
    # number defined in the PDF file" (Table 15), and the highest number the
    # cross-reference chain actually mentions is taken alongside it: a file
    # whose /Size is too small would otherwise have this update hand out a
    # number it already uses, and the two objects would be one.
    set tclpdfHigh 0
    set size [::tclpdf::importRead::Get $trailer Size]
    if {[lindex $size 0] eq "n" && [string is entier -strict [lindex $size 1]]} {
      set tclpdfHigh [expr {[lindex $size 1] - 1}]
    }
    foreach number [dict keys [dict get $tclpdfReader xref]] {
      if {$number > $tclpdfHigh} {
        set tclpdfHigh $number
      }
    }
  }

  # -- what the file already is -------------------------------------------

  # The path this session was opened on - where [write] writes by default.
  method path {} {
    return $tclpdfPath
  }

  # The length of the original file in bytes: everything below this offset is
  # untouched by the update, and that is the promise the whole module makes.
  method base {} {
    return $tclpdfBase
  }

  # The offset of the cross-reference section the added /Prev will name.
  method prev {} {
    return $tclpdfPrev
  }

  # The highest object number that will be defined once this update is
  # written - /Size minus one, and the same meaning [count] has on the writer.
  method count {} {
    return $tclpdfHigh
  }

  # Whether the file defines that object, or this update does.
  method defines {number} {
    return [expr {[dict exists $tclpdfBodies $number]
        || [dict exists $tclpdfReader xref $number]}]
  }

  # -- adding and replacing -----------------------------------------------

  # Reserve a number the file does not use, without having the content yet -
  # the forward reference, exactly as on the writer.
  method reserve {} {
    incr tclpdfHigh
    dict set tclpdfBodies $tclpdfHigh {}
    lappend tclpdfOrder $tclpdfHigh
    return $tclpdfHigh
  }

  # Give a reserved number back, the way the writer does - same two
  # refusals, same answer: the number is filled with the null object rather
  # than handed out again, because whoever already points at it is the
  # caller's business and 7.3.9 makes a reference to a missing object and a
  # reference to null the same thing.
  #
  # An update session appends to a finished file and has nothing to take
  # back from it - but it hands out numbers of its own for what it adds, and
  # a refusal between [reserve] and [put] leaves the same hole here as it
  # did in the writer: the increment stands, the body never comes, and the
  # cross-reference section of the update names an object that is not there.
  method release {number} {
    if {![dict exists $tclpdfBodies $number]} {
      return -code error "tclpdf: object $number was never reserved by this\
          update"
    }
    if {[dict get $tclpdfBodies $number] eq "null"} {
      return -code error "tclpdf: object $number was already released"
    }
    if {[dict get $tclpdfBodies $number] ne {}} {
      return -code error "tclpdf: object $number is already written and\
          cannot be released"
    }
    dict set tclpdfBodies $number null
    return $number
  }

  # Fill a number this update reserved.
  method put {number body} {
    if {![dict exists $tclpdfBodies $number]} {
      return -code error "tclpdf: object $number was never reserved by this\
          update - a number the file already defines is written with\
          \"replace\""
    }
    dict set tclpdfBodies $number $body
    return $number
  }

  # Reserve and fill in one step - the common case, and word for word the
  # writer's own [add]. The repetition is the point of this class rather than
  # an oversight: a builder that says [$w add $body] has to mean the same
  # thing when $w is an update session. What is NOT repeated is the store
  # behind it - the writer numbers a file it writes whole, this one continues
  # the numbering of a file it has read.
  method add {body} {
    return [my put [my reserve] $body]
  }

  # A second copy of an object the file already carries. The first copy stays
  # where it is; the cross-reference entry of this update decides which of
  # them a reader takes (7.5.6).
  method replace {number body} {
    my CheckReplaceable $number
    if {![dict exists $tclpdfBodies $number]} {
      lappend tclpdfOrder $number
    }
    dict set tclpdfBodies $number $body
    return $number
  }

  # A stream object, added or replacing one. /Length is computed from the
  # bytes as they are written and nowhere else - the same rule, through the
  # same infrastructure, that writer.tcl states at length.
  method addStream {pairs data} {
    ::tclpdf::pdfObj checkBytes $data
    return [my add [::tclpdf::pdfObj stream $pairs $data]]
  }

  method stream {number pairs data} {
    ::tclpdf::pdfObj checkBytes $data
    return [my put $number [::tclpdf::pdfObj stream $pairs $data]]
  }

  method replaceStream {number pairs data} {
    ::tclpdf::pdfObj checkBytes $data
    return [my replace $number [::tclpdf::pdfObj stream $pairs $data]]
  }

  # An indirect reference, checked: a reference to a number that neither the
  # file nor this update defines produces a file readers open and render with
  # pieces missing.
  method ref {number} {
    if {![my defines $number]} {
      return -code error "tclpdf: no such object: $number - neither\
          \"[file tail $tclpdfPath]\" nor this update defines it"
    }
    return [::tclpdf::pdfObj ref $number]
  }

  # The body of an object as PDF syntax: the one this update holds, or - for
  # an object the update has not touched - the one the file holds, written
  # back from the parsed object with its references intact.
  #
  # This is what makes [replace] usable at all. Adding /AcroForm to a catalog
  # or /Annots to a page means writing a body that is the old one plus an
  # entry, and the old one is in the file rather than in the caller's hands.
  # A stream object comes back with its data unchanged and still in its own
  # filter - the import decodes only what it must, and a body that is handed
  # straight back to [replace] must not be re-encoded on the way.
  method body {number} {
    if {[dict exists $tclpdfBodies $number]} {
      set body [dict get $tclpdfBodies $number]
      if {$body ne {}} {
        return $body
      }
    }
    if {![dict exists $tclpdfReader xref $number]} {
      return -code error "tclpdf: no such object: $number"
    }
    lassign [::tclpdf::importRead::Object tclpdfReader $number] value hasStream data
    set body [my Text $value]
    if {$hasStream} {
      append body "\nstream\n$data\nendstream"
    }
    return $body
  }

  # -- the added trailer ---------------------------------------------------

  # Read the entries the added trailer will carry, or set one of them. A key
  # set here wins over the one the file states; the empty value removes an
  # entry the file states. Values are PDF syntax, as everywhere in this
  # package - [$upd ref 12] rather than 12.
  method trailer {args} {
    switch -- [llength $args] {
      0 {return [my TrailerPairs]}
      1 {
        set key [lindex $args 0]
        set pairs [my TrailerPairs]
        if {![dict exists $pairs $key]} {
          return {}
        }
        return [dict get $pairs $key]
      }
      2 {
        lassign $args key value
        if {$key in {Size Prev}} {
          return -code error "tclpdf: the added trailer's /$key is the\
              update's own - /Size counts the objects and /Prev names the\
              previous cross-reference section"
        }
        dict set tclpdfOverrides $key $value
        return $value
      }
      default {
        return -code error "tclpdf: wrong # args: should be \"trailer ?key?\
            ?value?\""
      }
    }
  }

  # The changing half of /ID (14.4). Without a value of its own it is derived
  # from what this update appends; a caller who has to pin the file byte for
  # byte sets it.
  method id {{value {}}} {
    if {$value ne {}} {
      set tclpdfId $value
    }
    return $tclpdfId
  }

  # -- writing -------------------------------------------------------------

  # The bytes this update appends - everything from the first new object to
  # the closing %%EOF. The file itself is not read again and not touched:
  # what [write] does is put the original bytes and these behind each other.
  method appendix {} {
    my CheckComplete
    if {![llength $tclpdfOrder] && ![dict size $tclpdfOverrides]} {
      return -code error "tclpdf: this update changes nothing - an update\
          appends objects or trailer entries, and a file that gains neither\
          is better left as it is"
    }

    # A file whose last byte is not a line ending would otherwise have its
    # %%EOF and the first new object run into one another. The separator is
    # part of the appendix, so every offset below counts it.
    set out {}
    set last [string index [dict get $tclpdfReader bytes] end]
    if {$last ne "\n" && $last ne "\r"} {
      append out "\n"
    }

    set offsets {}
    foreach number $tclpdfOrder {
      dict set offsets $number [expr {$tclpdfBase + [string length $out]}]
      append out "$number 0 obj\n[dict get $tclpdfBodies $number]\nendobj\n"
    }

    set startxref [expr {$tclpdfBase + [string length $out]}]
    append out [my Table $offsets]
    append out "trailer\n[::tclpdf::pdfObj dictionary \
        [my TrailerPairs [my Identifier $out]]]\n"
    append out "startxref\n$startxref\n%%EOF\n"
    return $out
  }

  # Write the continued file: the original bytes unchanged, the appendix
  # behind them. Without a path the file this session was opened on is
  # continued in place - which is what "updating a PDF file" means - and the
  # original bytes are the ones read at [open], so writing twice appends
  # once.
  method write {{path {}}} {
    if {$path eq {}} {
      set path $tclpdfPath
    }
    ::tclpdf::io write $path "[dict get $tclpdfReader bytes][my appendix]"
    return $path
  }

  # -- the parts ------------------------------------------------------------

  # The cross-reference section of the update: entries only for the objects
  # this update writes (7.5.6), in ascending subsections of consecutive
  # numbers - the shape of H.7, where the changed page object and the four
  # new annotations come out as "4 1" and "7 5".
  #
  # Entry zero heads the chain of free objects and is repeated in every
  # section of the standard's own example. It is written as the empty chain
  # because this update never frees an object; a free list the original built
  # is thereby cut, which costs a later writer the chance to recycle those
  # numbers and costs a reader nothing - object 0 is never referenced.
  method Table {offsets} {
    set out "xref\n0 1\n0000000000 65535 f \n"
    set run {}
    foreach number [lsort -integer [dict keys $offsets]] {
      if {[llength $run] && $number != [lindex $run end] + 1} {
        append out [my Subsection $run $offsets]
        set run {}
      }
      lappend run $number
    }
    if {[llength $run]} {
      append out [my Subsection $run $offsets]
    }
    return $out
  }

  # One subsection: its header and one 20-byte entry per object. Every entry
  # is exactly 20 bytes including the two-byte line ending - readers do seek
  # into this table by index.
  method Subsection {run offsets} {
    set out "[lindex $run 0] [llength $run]\n"
    foreach number $run {
      append out [format "%010d 00000 n \n" [dict get $offsets $number]]
    }
    return $out
  }

  # The entries of the added trailer: the previous ones that may travel, then
  # whatever the caller set, then /Size and /Prev. "identifier" is the
  # changing half of /ID, or the empty string where the caller only wants to
  # look at the entries rather than write them.
  method TrailerPairs {{identifier {}}} {
    set dropped $::tclpdf::update::dropped
    set pairs {}
    foreach {key value} [lindex [dict get $tclpdfReader trailer] 1] {
      if {$key in $dropped} {
        continue
      }
      if {[dict exists $tclpdfOverrides $key]} {
        continue
      }
      if {$key eq "ID" && $identifier ne {}} {
        set value [my Changed $value $identifier]
      }
      lappend pairs $key [my Text $value]
    }
    dict for {key value} $tclpdfOverrides {
      if {$value eq {}} {
        continue
      }
      lappend pairs $key $value
    }
    lappend pairs Size [expr {$tclpdfHigh + 1}] Prev $tclpdfPrev
    return $pairs
  }

  # /ID with its second string replaced (14.4): the first is permanent and is
  # left exactly as the file writes it. An array that is not the pair the
  # standard describes is carried through untouched rather than repaired -
  # what it means is the previous writer's business.
  method Changed {value identifier} {
    if {[lindex $value 0] ne "a" || [llength [lindex $value 1]] != 2} {
      return $value
    }
    return [list a [list [lindex [lindex $value 1] 0] \
        [list h [binary encode hex $identifier]]]]
  }

  # The changing identifier, where the caller named none: a digest over what
  # this update appends, and over the length of the file it is appended to.
  # Content-based as 14.4 asks, and repeatable, which a clock would not be.
  method Identifier {appended} {
    if {$tclpdfId ne {}} {
      return $tclpdfId
    }
    return [string range [::tclpdf::crypto sha256 "$tclpdfBase$appended"] 0 15]
  }

  # A parsed object written back as PDF syntax. The map that renumbers a
  # reference on an IMPORT is the identity here: an update writes into the
  # file's own numbering, so every number stays the one it was.
  method Text {value} {
    set map {}
    foreach number [::tclpdf::importRead::Refs $value] {
      dict set map $number $number
    }
    return [::tclpdf::importRead::Serialize $value $map]
  }

  # Whether that object may be given a second copy - the questions the head
  # of this file answers.
  method CheckReplaceable {number} {
    if {![string is entier -strict $number] || $number < 1} {
      return -code error "tclpdf: an object number is a positive integer, not\
          \"$number\""
    }
    if {![dict exists $tclpdfReader xref $number]} {
      return -code error "tclpdf: \"[file tail $tclpdfPath]\" defines no\
          object $number - an object the file does not have is written with\
          \"add\", which hands out a number of its own"
    }
    set generation [my Generation $number]
    if {$generation != 0} {
      return -code error "tclpdf: object $number of\
          \"[file tail $tclpdfPath]\" is at generation $generation, and this\
          update writes generation 0 - the two are different objects, not two\
          versions of one"
    }
    set type [lindex [::tclpdf::importRead::Get \
        [lindex [::tclpdf::importRead::Object tclpdfReader $number] 0] Type] 1]
    if {$type eq "ObjStm"} {
      return -code error "tclpdf: object $number of\
          \"[file tail $tclpdfPath]\" is an object stream - replacing it\
          would hide the objects compressed inside it, which the file's\
          cross-reference still points into"
    }
    if {$type eq "XRef"} {
      return -code error "tclpdf: object $number of\
          \"[file tail $tclpdfPath]\" is a cross-reference stream - it is the\
          file's own bookkeeping, and an update writes its own"
    }
    return
  }

  # The generation number the file gives that object. An object inside an
  # object stream is at generation 0 by definition - 7.5.7 forbids any other
  # there - and one stored on its own says so in its header, which is read
  # rather than assumed: the cross-reference does record the generation, and
  # a replacement written as "N 0 obj" over an object that is "N 2 obj" would
  # be a different object with the same number.
  method Generation {number} {
    set entry [dict get $tclpdfReader xref $number]
    if {[lindex $entry 0] ne "o"} {
      return 0
    }
    set offset [lindex $entry 1]
    set head [string range [dict get $tclpdfReader bytes] $offset \
        [expr {$offset + 63}]]
    if {![regexp {^\s*(\d+)\s+(\d+)\s+obj\M} $head -> found generation]} {
      return -code error "tclpdf: \"[file tail $tclpdfPath]\": no object\
          header at offset $offset, where the cross-reference puts object\
          $number"
    }
    if {$found != $number} {
      return -code error "tclpdf: \"[file tail $tclpdfPath]\": the\
          cross-reference puts object $number at offset $offset, and the\
          object there is $found"
    }
    return $generation
  }

  # A number reserved and never filled - the writer's check, because it is
  # the writer's question: the two object stores of this package differ in
  # where their numbers come from and in nothing else.
  method CheckComplete {} {
    return [::tclpdf::writer::checkComplete $tclpdfBodies]
  }
}

package provide tclpdf::update 1.0
