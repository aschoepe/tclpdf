#
# tclpdf - PDF generation for Tcl
#
# sign - digital signatures (ISO 32000-2, 12.8)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# One call prepares a document for signing, and signs it as it is written
# when a signer is named:
#
#   $doc sign -signer [list mySigner] -reason "Approved" -name "E. Mustermann"
#
# The cut this module is built on: TCLPDF PREPARES, THE SIGNATURE COMES FROM
# OUTSIDE. Nothing here computes a digest, holds a private key or speaks
# CMS. What is built here is the part only a PDF writer can build - the
# signature dictionary, the field, the widget, the /AcroForm entry, the
# reserved space and above all the /ByteRange - and the bytes that range
# covers are handed to a command prefix that answers with a CMS SignedData
# object in DER. Whoever holds the key decides what that prefix is: an
# "openssl cms -sign" pipeline, a card reader, an HSM, a signing service.
#
# Without -signer the document is written with the placeholder still in it
# and /ByteRange filled in all the same - which is the two-stage way: the
# file goes to whoever can sign it, [::tclpdf::sign digest] says which bytes
# that is, and [::tclpdf::sign embed] puts the answer back. Filling
# /ByteRange even then is the whole point of that stage: without it nobody
# on the other side knows what to hash.
#
# Three mechanics decide whether this works at all, and each of them is a
# way to get it wrong:
#
#   The digest covers the file MINUS the signature. /ByteRange is a pair
#   array (start, length) that describes everything except the value of
#   /Contents (12.8.1, Table 255), and for ETSI.CAdES.detached it shall
#   cover the entire file. So the two numbers in the middle depend on where
#   the signature ends up - which is not known until the file exists.
#
#   Every edit after that point has to be LENGTH-NEUTRAL. Writing the real
#   /ByteRange over the placeholder, and the DER over the reserved zeros,
#   must not move a single byte: the xref offsets are already written, and
#   /ByteRange describes its own file. Hence a placeholder of fixed width
#   for the array, padded with spaces, and a /Contents value padded with
#   zeros BEFORE the '>' - which 12.8.3.3.1 does not merely permit but
#   prescribes ("shall fit precisely ... shall be padded with zeros at the
#   end of the string").
#
#   The same holds for /M, the time of signing, and that is why it is a
#   placeholder as well. It has to stand in the file BEFORE the bytes are
#   handed out, because it sits inside the range they cover - a date written
#   afterwards would be a claim nobody signed. Where a -signer signs the
#   document as it is written, the moment is the write and the value is
#   written outright. Where it is not, the dictionary carries a date of
#   nothing but zeros and [::tclpdf::sign digest] writes the current time
#   over it, in exactly its room, before it answers. Either way the time is
#   the moment of signing and either way the signature covers it.
#
#   The object offsets are not to be had from the writer, and are not
#   needed. writer.tcl counts them into a local variable while it writes,
#   and nothing asks it afterwards. So the placeholders are found in the
#   FINISHED FILE by searching for them - which is exact rather than
#   approximate: /ByteRange appears once, and the reserved zeros are tens of
#   thousands of bytes that occur nowhere else.
#
# The work therefore happens in two events, not one: [SignWrite] on
# beforeWrite builds the objects, and [SignAfterWrite] on afterWrite - the
# one event that carries the finished file's path - patches the file. This
# is also why the channel way is refused while a signature is pending:
# [writeChannel] fires afterWrite with an EMPTY path, and there is nothing
# to reopen.
#
# WHICH /SubFilter IS THE CALLER'S CHOICE, not a consequence of the file
# version: "-subfilter pkcs7" writes /adbe.pkcs7.detached and is the default,
# "-subfilter cades" writes /ETSI.CAdES.detached and with it the claim to be a
# PAdES signature (ETSI EN 319 142-1). That claim costs something the caller
# cannot see from here, so it is checked: Table 1 of that standard says the
# signing-time attribute "shall not be present" in the CMS object at any
# baseline level, while a signer writes it unless told otherwise: "openssl
# cms -sign" leaves it out with "-no_signing_time", which OpenSSL 3 has and
# the LibreSSL shipped as /usr/bin/openssl on macOS does not; pyHanko and the
# EU DSS library omit it by themselves, BouncyCastle adds it unasked.
# A DER carrying the attribute is refused under /ETSI.CAdES.detached - see
# [NoSigningTime], which is the one place this module looks into the bytes it
# is handed, and looks exactly two OIDs far: the attribute, and the RFC 3161
# timestamp token whose own signing time a B-T signature legitimately carries.
# The OTHER half of that same table row is the entry with the key M, which
# "shall be present" at every baseline level - so "-date {}", the one call
# that keeps /M out, is refused under cades as well ([Claim]). One line of one
# table, and the same kind of answer to both halves of it.
#
# WHETHER THE FIELD IS VISIBLE IS THE CALLER'S CHOICE, and where it is,
# THIS MODULE DOES NOT DRAW IT. Without -rect the widget is the invisible
# one of the standard's own example (12.8.5.3): /Rect [0 0 0 0] and /F 4,
# which is the only one of the three ways to be invisible that 12.7.5.5 puts
# as a "shall" for a WRITER, and the only one that needs no appearance
# stream (Table 166, first exception). With -rect the field gets a place on
# the page named by -page, and then it needs something to draw there:
# -appearance names a form XObject the caller built with "form create", and
# it is hung into the widget as /AP << /N ... >>.
#
# The cut is deliberate, and it is the same one the module is built on
# everywhere else. A signature appearance is a frame with a name, a reason
# and a date in it - that is layout, and the caller's document does layout
# already: this package draws form XObjects, breaks lines, embeds faces and
# knows the document's unit. A drawing engine of this module's own would be
# a second place where the font, the wording and the arrangement are
# decided, and the caller could overrule none of it. So what is built here
# is again only the part a signature module has to build - the field, the
# rectangle and the reference - and what goes into the rectangle is the
# caller's.
#
# Which is why the two halves are refused apart rather than silently
# completed. A -rect without an -appearance is a visible field with nothing
# to show: veraPDF rule 6.3.3-1 fails it ("Every annotation ... shall have
# at least one appearance dictionary", from which Table 166 exempts a zero
# rectangle and nothing else), and a reader draws it as blank. An
# -appearance without a -rect is a drawing on a rectangle of no area, which
# nothing ever paints. /F 4 stands in both cases: rule 6.3.2-2 asks for
# Print set and Hidden, Invisible, NoView and ToggleNoView clear, and a
# visible field is no exception to it.
#
# A VISIBLE SIGNATURE FIELD IS A FORM FIELD, and a tagged document treats it
# as one. ISO 14289-1, 7.18.4 ("A Widget annotation shall be nested within a
# Form tag") and ISO 14289-2, 8.10.1 ("Each widget annotation shall be
# enclosed by a Form structure element") make no exception for /FT /Sig, and
# 7.18.1 wants every annotation in the structure tree in reading order and
# described. So the widget gets the same treatment every other field's does,
# from the same code: a Form structure element opened at the [sign] call -
# which is where the reading order is - with the object reference into it and
# the /StructParent key back out, and -tooltip and -contents for the two ways
# a field says what it is (/TU, ISO 32000-2, 14.9.3; /Contents, ISO 14289-2,
# 8.10.2.3). It also stands in the document's field table, so that [$doc ua]
# asks it the three questions it asks every widget, in the same sentences,
# and so that a name taken twice is refused whichever call came second.
#
# AND THE INVISIBLE ONE IS AN ARTIFACT, which is the other half of the same
# rule rather than an omission: ISO 14289-2, 8.9.2.4.13 - "a widget
# annotation of zero height and width shall be an artifact" - 8.10.1, which
# exempts an artifact from the Form element, and 8.10.3.5, which says it of
# this field by name. So the default signature enters neither the tree nor
# the field table, and PDF/UA asks it nothing. The RECTANGLE decides which of
# the two a signature is, not the claim: [$doc ua] may stand before this call
# or after it, and a tree that depended on the order would make the two
# orders write different files.
#
# What the first version does not do, each refused by name rather than
# written wrong:
#
#   Encryption and a signature together. 7.6.2 exempts exactly one thing
#   from encryption - "any hexadecimal strings representing the value of the
#   Contents key in a Signature dictionary" - and not the other strings of
#   that dictionary. Buildable, unmeasured; the mirror check sits in
#   encrypt.tcl.
#
#   A second signature IN ONE DOCUMENT. That needs an incremental update
#   (7.5.6) with its own xref section and its own %%EOF, and this package
#   writes a file in one piece - so it happens on the FINISHED file instead,
#   through [::tclpdf::sign add], which is the third entry point below and
#   the only way a signature can be added without moving the bytes the first
#   one covers.
#
# PDF/A and ZUGFeRD are NOT refused: ISO 19005-3 clause 6.4.3 states three
# requirements ON signatures, which would be pointless if it forbade them.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::io 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::sign {
  namespace export {[a-z]*}
  namespace ensemble create

  # An unknown subcommand of this ensemble, refused in this package's words.
  # Tcl's own answer is "unknown or ambiguous subcommand \"foo\": must be
  # add, digest, embed" with -errorcode {TCL LOOKUP SUBCOMMAND foo}, and
  # doc/tclpdf.md:1723 names [tclpdf] itself as the ONE refusal that carries
  # no TCLPDF code. A namespace ensemble of the package is not that
  # exception - measured 2026-08-26 on all four of them.
  #
  # The subcommands are read off the ensemble rather than listed here, so
  # the message cannot fall behind the module.
  namespace ensemble configure ::tclpdf::sign -unknown \
      ::tclpdf::sign::Unknown

  # The /ByteRange placeholder: four numbers of fixed width, written before
  # the real ones are known and overwritten with them afterwards. Ten digits
  # hold every offset up to 9 999 999 999 bytes, which is two orders of
  # magnitude past anything this package writes.
  #
  # It is a constant, and the width is the point of it: the array has to be
  # replaced without moving a byte, so whatever is written back has to fit
  # into exactly this room. The leading "0 " is already the first pair's
  # start, which is zero for every signature that covers the whole file.
  variable byteRangePlaceholder {[0 0000000000 0000000000 0000000000]}

  # How far after the /ByteRange array the /Contents key may sit before the
  # dictionary is taken to be one this module did not write. The two are
  # written next to each other, which is eleven bytes; the room is generous
  # so that a differently spaced dictionary is still found, and finite so
  # that the /Contents of an annotation further down is not.
  variable contentsDistance 64

  # And how far BEFORE the array the /SubFilter may sit. Same idea and the
  # same generosity: [SignWrite] writes it directly in front of /ByteRange,
  # which for the longer of the two values is 32 bytes.
  variable subFilterDistance 64

  # The /M placeholder: a date of nothing but zeros, written where the time
  # of signing is not yet known - the two-stage way, where the document is
  # prepared here and signed elsewhere and later. [digest] writes the real
  # time over it, and the fixed width is what allows that: the entry lies
  # inside the bytes the signature covers, so it has to exist before they are
  # handed out and may not move a byte when it is filled.
  #
  # The year 0000 is what marks it as a placeholder rather than as a date -
  # no clock produces one - and finding it still there is the check made
  # before it is written over.
  #
  # ISO 32000-2 struck the apostrophe after the offset minutes, so a 2.0 file
  # spells the same value one character shorter (7.9.4, and [pdfObj date]
  # takes the version for exactly that reason). The placeholder is trimmed
  # with it, by [DatePlaceholder].
  variable datePlaceholder {D:00000000000000+00'00'}

  # The signing-time attribute's object identifier, 1.2.840.113549.1.9.5, as
  # DER: tag 06, length 09, and the nine bytes of the identifier. Written as
  # hexadecimal and decoded once, so that the value in the source is the one
  # the standards quote rather than eleven escape sequences.
  variable signingTimeOid [binary decode hex 06092a864886f70d010905]

  # The object identifier of the RFC 3161 timestamp token attribute,
  # id-smime-aa-timeStampToken, 1.2.840.113549.1.9.16.2.14, as DER: tag 06,
  # length 0b, and the eleven bytes of the identifier. A PAdES B-T signature
  # carries one, and everything inside it - including a signing time of its
  # own - belongs to the timestamp authority rather than to the signer, which
  # is what [NoSigningTime] tells the two apart by.
  variable timeStampOid [binary decode hex 060b2a864886f70d010910020e]
}

#
# ---------------------------------------------------------------------------
# The file, as bytes
# ---------------------------------------------------------------------------
#
# These know nothing about documents: they take the bytes of a finished PDF
# and answer where the signature sits, what it covers, what may be written
# over it and whether the file still says what it said. Both consumers use
# them - the document's own afterWrite and the two-stage entry points below -
# so the arithmetic and the checks that decide whether a signature verifies
# exist once, and neither way can be the one that forgot a check.
#

# Where the signature dictionary's two placeholders are.
#
# Answers a dictionary: byteRangeStart and byteRangeEnd (the indices of the
# array's brackets), byteRange (its four numbers), contents (the index of the
# '<' of the value), hexLength (the number of hexadecimal digits between the
# delimiters) and subFilter (the name the dictionary states, which says what
# the file claims to be).
#
# "what" names the thing being read in the error messages - a file name for
# the two-stage way, "the document just written" for the write.
#
# WHICH /ByteRange IS MEANT, and the answer changed on 2026-08-22. It used to
# be decided by POSITION - the last one in the file - which is right for a
# file that holds nothing but signature dictionaries and wrong for every
# other one: /Reason, /Name, /Location and /ContactInfo are written into the
# file as the caller spelled them, so a caller string spelling out a
# /SubFilter, a /ByteRange and a /Contents of its own stands BEHIND the real
# dictionary (the builder writes those four entries last) and was taken for
# the newer signature. The consequence was not a broken file but a signed
# one: the CMS object went into the string, the real /Contents kept its
# zeros, [sign state] reported success and no structural check saw anything.
#
# What decides it now is the VALUE, which is the criterion [add] has used
# from the start: reserved room is nothing but zeros between the delimiters,
# and a signature never is - every DER object begins with 0x30. All four
# callers of this want the one signature that is still waiting for its value,
# so that is what is looked for, and finding two of them is refused rather
# than guessed at. The order of 7.5.6 still holds for everything else: an
# incremental update appends, so older signatures are the ones further
# forward, and they are finished, since [add] refuses to append onto one that
# is not.
#
# "unfilled" is what separates the three WRITING callers from the one reading
# one. [add], [embed] and the document's own afterWrite put a value into the
# room, so for them a file whose signatures all have theirs is a refusal
# rather than a target - that is where a second [embed] used to overwrite a
# good signature without a word. [digest] answers which bytes a file states
# as signed, which is a question a finished file answers too, so it asks with
# a 0 and gets the newest signature whether or not it is still waiting. The
# refusal for TWO waiting signatures stands in both cases: handing out bytes
# to be signed from a dictionary that may not be the right one is the same
# mistake, whoever asked.

proc ::tclpdf::sign::Unknown {ensemble subcommand args} {
  set known [lsort [lmap command \
      [info commands ${ensemble}::\[a-z\]*] {namespace tail $command}]]
  return -code error -errorcode [list TCLPDF SIGN SUBCOMMAND $subcommand] \
      "tclpdf: unknown [namespace tail $ensemble] subcommand\
      \"$subcommand\" - known are: [join $known {, }]"
}

proc ::tclpdf::sign::Locate {data what {unfilled 1}} {
  set positions {}
  set from 0
  while {1} {
    set at [string first /ByteRange $data $from]
    if {$at < 0} {
      break
    }
    lappend positions $at
    set from [expr {$at + 10}]
  }
  if {![llength $positions]} {
    return -code error -errorcode [list TCLPDF SIGN NONE $what] \
        "tclpdf: $what carries no signature - there is no\
        /ByteRange in it. A document is prepared for signing by\
        \[\$doc sign\] before it is written, and a finished file gains a\
        further signature through \[::tclpdf::sign add\]"
  }

  # Each occurrence read on its own; one that does not read as a signature
  # dictionary is not a candidate rather than an error, because a file of
  # ours may legitimately carry such a thing - inside a string.
  set readable {}
  set reserved {}
  foreach at $positions {
    if {[catch {Entry $data $at $what} located]} {
      continue
    }
    lappend readable $located
    if {[Waiting $data $located]} {
      lappend reserved $located
    }
  }
  if {![llength $readable]} {
    # Not one of them reads as a signature dictionary. The message is the one
    # [Entry] makes for the last occurrence - it names the part that is
    # missing, which is what a caller can do something with.
    return [Entry $data [lindex $positions end] $what]
  }
  if {![llength $reserved] && !$unfilled} {
    # The reading caller: no room left to fill, so what is meant is the
    # newest signature the file has - which is the last one, by 7.5.6.
    return [lindex $readable end]
  }
  if {![llength $reserved]} {
    return -code error -errorcode [list TCLPDF SIGN NONE $what] \
        "tclpdf: no signature of $what is waiting for its\
        value - every /Contents in it holds one already. The value goes into\
        the room reserved for it exactly once, and a second one written over\
        it would destroy the first: reserved room is nothing but zeros\
        between the delimiters, and a signature is never that, since every\
        DER object begins with 0x30. A FURTHER signature is appended with\
        \[::tclpdf::sign add\]"
  }
  if {[llength $reserved] > 1} {
    return -code error -errorcode [list TCLPDF SIGN MANY $what] \
        "tclpdf: [llength $reserved] signatures of $what are\
        waiting for their value, and this module prepares one at a time -\
        \[::tclpdf::sign add\] refuses to append onto a signature that has\
        none yet. So one of these /ByteRange entries stands inside a STRING\
        rather than in a signature dictionary: -reason, -name, -location and\
        -contact go into the file as they were written, and one written like\
        a signature dictionary would decide where the signature goes.\
        Refused rather than guessed at"
  }
  return [lindex $reserved 0]
}

# Whether the /Contents this entry describes is still the reserved room.
#
# The whole criterion is in one line and in [add]'s own words: reserved room
# is zeros, and a DER object begins with 0x30, so a value that is nothing but
# zeros is room and anything else is a signature.
proc ::tclpdf::sign::Waiting {data located} {
  set at [dict get $located contents]
  return [regexp {^0+$} [string range $data [expr {$at + 1}] \
      [expr {$at + [dict get $located hexLength]}]]]
}

# Whether ANY signature in the file is still waiting for its value - the
# question [add] asks before it appends, over the whole file rather than
# over the newest signature, and without [Locate]: see the comment there.
#
# /ByteRange and /Contents next to each other, within the same room [Entry]
# allows, and the /Contents nothing but zeros. /SubFilter is deliberately
# NOT required here where [Entry] requires it: a foreign file may spell its
# signature dictionary in any order, and the question is about the file, not
# about whether tclpdf wrote it.
proc ::tclpdf::sign::WaitingAnywhere {data} {
  variable contentsDistance
  set from 0
  while {1} {
    set at [string first /ByteRange $data $from]
    if {$at < 0} {
      return 0
    }
    set from [expr {$at + 10}]
    set close [string first \] $data $at]
    if {$close < 0} {
      continue
    }
    set key [string first /Contents $data $close]
    if {$key < 0 || $key - $close > $contentsDistance} {
      continue
    }
    set open [string first < $data $key]
    set to [string first > $data $open]
    if {$open < 0 || $to < 0 || $to <= $open + 1} {
      continue
    }
    if {[regexp {^0+$} [string range $data [expr {$open + 1}] \
        [expr {$to - 1}]]]} {
      return 1
    }
  }
}

# One occurrence of /ByteRange read as the signature dictionary around it, or
# an error naming what is not there. Split out of [Locate] so that reading
# one and CHOOSING among several are two things - the choice has to be able
# to pass over an occurrence without the whole call failing.
proc ::tclpdf::sign::Entry {data at what} {
  set open [string first \[ $data $at]
  set close [string first \] $data $open]
  if {$open < 0 || $close < 0 || $close <= $open} {
    return -code error -errorcode [list TCLPDF SIGN FOREIGN ByteRange] \
        "tclpdf: the /ByteRange of $what is not an array -\
        the file is not one tclpdf wrote"
  }
  set numbers {}
  foreach word [regexp -all -inline {[0-9]+} \
      [string range $data [expr {$open + 1}] [expr {$close - 1}]]] {
    # [scan] and not [expr]: "0000000010" is a leading-zero literal, and Tcl
    # reads that as octal - "0000000008" would be an error and "0000000010"
    # would be eight.
    lappend numbers [scan $word %d]
  }
  if {[llength $numbers] != 4} {
    return -code error -errorcode [list TCLPDF SIGN FOREIGN ByteRange] \
        "tclpdf: the /ByteRange of $what holds\
        [llength $numbers] numbers and a signature written here holds four -\
        the file is not one tclpdf wrote"
  }

  # The /SubFilter, which is how the two-stage way learns whether this file
  # claims PAdES - [embed] has no document object to ask, and the claim
  # decides what it accepts (see [NoSigningTime]). It stands directly in
  # front of /ByteRange, as [SignWrite] writes it.
  variable subFilterDistance
  set key [string last /SubFilter $data $at]
  if {$key < 0 || $at - $key > $subFilterDistance
      || ![regexp {^/SubFilter (/[^][()<>{}/%[:space:]]+)} \
          [string range $data $key [expr {$at - 1}]] -> subFilter]} {
    return -code error -errorcode [list TCLPDF SIGN FOREIGN SubFilter] \
        "tclpdf: the signature dictionary of $what has no\
        /SubFilter in front of its /ByteRange - the file is not one tclpdf\
        wrote"
  }

  variable contentsDistance
  set key [string first /Contents $data $close]
  if {$key < 0 || $key - $close > $contentsDistance} {
    return -code error -errorcode [list TCLPDF SIGN FOREIGN Contents] \
        "tclpdf: the signature dictionary of $what has no\
        /Contents next to its /ByteRange - the file is not one tclpdf wrote"
  }
  set from [string first < $data $key]
  set to [string first > $data $from]
  if {$from < 0 || $to < 0 || $to <= $from} {
    return -code error -errorcode [list TCLPDF SIGN FOREIGN Contents] \
        "tclpdf: the /Contents of $what is not a hexadecimal\
        string - 12.8.3.3.1 requires one, with '<' and '>' delimiters"
  }
  set hexLength [expr {$to - $from - 1}]
  if {$hexLength == 0 || $hexLength % 2} {
    return -code error -errorcode [list TCLPDF SIGN FOREIGN Contents] \
        "tclpdf: the /Contents of $what holds $hexLength\
        hexadecimal digits, which is not a whole number of bytes"
  }
  return [dict create byteRangeStart $open byteRangeEnd $close \
      byteRange $numbers contents $from hexLength $hexLength \
      subFilter $subFilter]
}

# The /ByteRange this file needs: everything except the value of /Contents,
# the delimiters included (12.8.1, and 12.8.3.3.1 for why the delimiters
# fall inside the gap - the space BETWEEN the ranges is what the hexadecimal
# string has to fit into precisely).
proc ::tclpdf::sign::Range {data located} {
  set gap [dict get $located contents]
  set after [expr {$gap + 2 + [dict get $located hexLength]}]
  return [list 0 $gap $after [expr {[string length $data] - $after}]]
}

# Write a /ByteRange over the placeholder, padded with spaces to exactly the
# room it found. Length-neutral by construction and checked to be: the array
# describes offsets into its own file, so a byte gained or lost here
# invalidates the very thing being written.
proc ::tclpdf::sign::WriteRange {data located byteRange} {
  set open [dict get $located byteRangeStart]
  set close [dict get $located byteRangeEnd]
  set room [expr {$close - $open + 1}]
  set text \[[join $byteRange { }]
  set pad [expr {$room - 1 - [string length $text]}]
  if {$pad < 0} {
    return -code error -errorcode [list TCLPDF SIGN ROOM ByteRange] \
        "tclpdf: the /ByteRange \[$byteRange\] does not fit\
        into the [expr {$room - 2}] characters reserved for it - the\
        document is larger than a signature written here can describe"
  }
  append text [string repeat { } $pad] \]
  return [string replace $data $open $close $text]
}

# The bytes a /ByteRange covers, in order - what gets signed.
proc ::tclpdf::sign::Bytes {data byteRange} {
  set bytes {}
  foreach {start length} $byteRange {
    append bytes [string range $data $start [expr {$start + $length - 1}]]
  }
  return $bytes
}

# Write a DER-encoded CMS object over the reserved zeros, padded with zeros
# again up to the reserved room (12.8.3.3.1, and the padding is a "shall"
# there, not a convenience).
#
# The refusal carries -errorcode TCLPDF SIGN SPACE with what was needed and
# what was reserved, so that a caller can react to it - raise -size and write
# again - without reading the message. Truncating instead would produce a
# file every validator calls signed and no verifier accepts.
proc ::tclpdf::sign::Fill {data located der} {
  set room [dict get $located hexLength]
  set hex [binary encode hex $der]
  if {[string length $hex] > $room} {
    return -code error -errorcode \
        [list TCLPDF SIGN SPACE [string length $der] [expr {$room / 2}]] \
        "tclpdf: the signature is [string length $der] bytes and\
        [expr {$room / 2}] were reserved for it - raise the reserved space\
        with \"sign -size [string length $der]\" or more"
  }
  append hex [string repeat 0 [expr {$room - [string length $hex]}]]
  set at [dict get $located contents]
  return [string replace $data [expr {$at + 1}] [expr {$at + $room}] $hex]
}

# The /M placeholder as it is written for a file of this version, and the
# one place the two spellings of 7.9.4 are told apart.
proc ::tclpdf::sign::DatePlaceholder {version} {
  variable datePlaceholder
  if {[package vcompare $version 2.0] >= 0} {
    return [string range $datePlaceholder 0 end-1]
  }
  return $datePlaceholder
}

# The version the file states in its header (7.5.2). Needed for the same
# reason [DatePlaceholder] takes one: the date written over the placeholder
# has to be spelled the way the placeholder was, or it does not fit the room.
# writer.tcl writes the header from the document's version and from nothing
# else, so the file is the authority here.
proc ::tclpdf::sign::HeaderVersion {data} {
  if {![regexp {^%PDF-([0-9]+\.[0-9]+)} $data -> version]} {
    return 1.7
  }
  return $version
}

# Where the /M placeholder is, as a pair of indices for its first and last
# character, or the empty list when the file carries none - which is the case
# whenever the document was written with a -date of its own or with none at
# all.
#
# Found by searching the finished file for it, as everything else here is
# found. The search string is the key, the delimiter and a year no clock
# produces, so neither a date that is really a date nor the value of some
# other entry is taken for it. It starts at /Contents because [SignWrite]
# writes /M BEHIND the reserved room - which is not a detail of the layout but
# the reason the entry can be filled in later at all: everything after that
# room lies in the second range, and hence inside what the signature covers.
proc ::tclpdf::sign::LocateDate {data located what} {
  variable datePlaceholder
  set mark "/M ([string range $datePlaceholder 0 15]"
  set at [string first $mark $data [dict get $located contents]]
  if {$at < 0} {
    return {}
  }
  set open [expr {$at + 3}]
  set close [string first ) $data $open]
  if {$close < 0} {
    return -code error -errorcode [list TCLPDF SIGN FOREIGN M] \
        "tclpdf: the /M of $what is not a literal string -\
        the file is not one tclpdf wrote"
  }
  return [list [expr {$open + 1}] [expr {$close - 1}]]
}

# Write a date over the placeholder, into exactly the room it occupies. The
# entry lies inside the bytes the signature covers, so this is as
# length-neutral as the other two patches and refused rather than fudged when
# it cannot be.
proc ::tclpdf::sign::WriteDate {data range date what} {
  lassign $range from to
  set room [expr {$to - $from + 1}]
  if {[string length $date] != $room} {
    return -code error -errorcode [list TCLPDF SIGN ROOM M] \
        "tclpdf: the signing time \"$date\" is\
        [string length $date] characters and the /M entry of $what holds\
        $room - the date is written OVER the placeholder, inside the bytes\
        the signature covers, and nothing there may change length.\
        \[::tclpdf::pdfObj date\] writes one that fits"
  }
  return [string replace $data $from $to $date]
}

# Refuse a CMS object that states a signing time where the file claims PAdES.
#
# ETSI EN 319 142-1, Table 1 puts the signing-time attribute at "shall not be
# present" for every baseline level, and the entry with the key M in the
# signature dictionary at "shall be present" - the opposite of what ISO
# 32000-2, Table 255 recommends, and a "shall" against a "should". So a
# document written with -subfilter cades claims something its signer can take
# away from it, and this is where that is noticed rather than by a validator
# months later.
#
# THE SEARCH IS DELIBERATELY COARSE. It looks for the DER encoding of the
# attribute's OID anywhere in the object and does not parse ASN.1: this module
# does not understand CMS, and is not going to start understanding it for one
# attribute. What it does read is the ORDER of two OIDs, and that is enough to
# tell the one case apart that a plain search gets wrong.
#
# A PAdES B-T signature carries an RFC 3161 timestamp token as an UNSIGNED
# attribute, and that token is a CMS SignedData of its own with a signing time
# of its own - the timestamp authority's, not the signer's. The outer
# SignerInfo can be perfectly clean while the OID is in the object, so a
# search that only asks WHETHER the OID occurs refuses a signature that the
# standard allows.
#
# The order decides it, and it decides it structurally rather than by luck:
# RFC 5652 defines SignerInfo with signedAttrs BEFORE unsignedAttrs, and DER
# writes the fields in that order. So a signing time of the signer's own -
# which is a signed attribute - always lies BEFORE the timestamp token, and
# one that belongs to a token always lies behind it. The refusal therefore
# stands only where the signing-time OID comes before the first timestamp
# token, or where there is no token at all. A signer that sets both - an
# outer signing time and a timestamp - still puts the outer one in front and
# is still refused, which is right: the outer attribute is the forbidden one.
#
# THE PRICE OF NOT PARSING ASN.1, said rather than hidden: the certificates
# stand in the DER before the SignerInfos, so an OID that appears in a
# certificate appears before any token and is read as an outer signing time.
# No certificate has a reason to carry this OID, but nothing here rules it
# out - and -subfilter pkcs7 remains the way past for a caller whose object
# is one this cannot judge.
proc ::tclpdf::sign::NoSigningTime {der subFilter what} {
  if {$subFilter ne "/ETSI.CAdES.detached"} {
    return
  }
  variable signingTimeOid
  variable timeStampOid
  set time [string first $signingTimeOid $der]
  if {$time < 0} {
    return
  }
  set token [string first $timeStampOid $der]
  if {$token >= 0 && $token < $time} {
    return
  }
  return -code error -errorcode {TCLPDF SIGN SIGNINGTIME} "tclpdf: the\
      signature for $what carries a signing-time attribute (OID\
      1.2.840.113549.1.9.5) and $subFilter claims a PAdES signature, where\
      ETSI EN 319 142-1, Table 1 says that attribute shall not be present -\
      the time of signing belongs in /M, which tclpdf writes. A signer writes\
      the attribute unless told otherwise: \"openssl cms -sign\" leaves it out\
      with \"-no_signing_time\", which OpenSSL 3 has and LibreSSL does not,\
      while BouncyCastle adds it unasked. Write the document with \"sign\
      -subfilter pkcs7\", which claims no PAdES, or have it signed by\
      something that leaves the attribute out - pyHanko and the EU DSS\
      library do so by themselves"
}

# A file whose /ByteRange is still the placeholder was never written through
# [$doc write], and signing it would mean signing the four zeros as well.
proc ::tclpdf::sign::Prepared {located what} {
  if {[lindex [dict get $located byteRange] 1] == 0} {
    return -code error -errorcode [list TCLPDF SIGN STATE unwritten] \
        "tclpdf: the /ByteRange of $what is still the\
        placeholder - the document was not written through \[\$doc write\],\
        and there is nothing that says which bytes to sign"
  }
  return
}

# The file has to agree with itself. A /ByteRange that does not describe this
# very file - because something was appended to it, or because the gap is not
# where /Contents is - names bytes whose digest no reader recomputes, and a
# signature made or embedded over them fails with nothing to point at.
#
# Both entry points ask this, and that is why it stands here rather than in
# one of them: [digest] refused such a file from the first version and [embed]
# did not, so ten bytes appended to a prepared file were enough to get a
# document that looks signed, carries a real CMS object and verifies nowhere.
#
# Answers the four numbers, which is what the caller wanted them for.
proc ::tclpdf::sign::Describes {data located what} {
  set byteRange [dict get $located byteRange]
  set needed [Range $data $located]
  if {$byteRange ne $needed} {
    return -code error -errorcode [list TCLPDF SIGN CHANGED $what] \
        "tclpdf: the /ByteRange of $what does not describe\
        this file - it says \[$byteRange\] and the file needs \[$needed\].\
        The file was changed after it was written"
  }
  return $byteRange
}

# A CMS object is a string of BYTES. Text where bytes were asked for is the
# one mistake that gets past everything: under Tcl 8.6 [binary encode hex]
# writes the low byte of each character and the file carries hexadecimal
# nonsense that looks signed, under Tcl 9 the same call raises an error about
# code points that says nothing about signatures. Hence one check for both
# ways in, made before either of them writes anything.
#
# The range is written as escapes rather than as literal characters, as
# writer.tcl does and for the same reason: Tcl 8.6 reads this file through the
# system encoding and Tcl 9 as UTF-8.
#
# AND IT HAS TO BE ONE. That check is a single byte, and it is the one [add]
# already reads a reserved /Contents by: DER writes a CMS ContentInfo as a
# SEQUENCE, a SEQUENCE is tag 0x30, so every DER object of this kind begins
# with that byte. It is not an ASN.1 parser and is not meant to be - this
# module does not understand CMS - but it catches what otherwise reaches the
# file unremarked: a signer, or a caller of [embed], handing over something
# that is not a signature at all. Measured before it was checked: "hello"
# went into a document as 68656c6c6f and every structural check called the
# result signed.
proc ::tclpdf::sign::Der {der} {
  if {[regexp {[^\u0000-\u00ff]} $der]} {
    return -code error -errorcode [list TCLPDF SIGN SIGNER text] \
        "tclpdf: the signature is text, not bytes - it has to\
        be a CMS SignedData object in DER, and a character above 0xff cannot\
        be a byte of one"
  }
  if {$der eq {}} {
    return -code error -errorcode [list TCLPDF SIGN SIGNER empty] \
        "tclpdf: the signature is empty - what belongs here is\
        a CMS SignedData object in DER, which is what \"openssl cms -sign\
        -outform DER\" writes"
  }
  if {[string index $der 0] ne "\u0030"} {
    return -code error -errorcode [list TCLPDF SIGN SIGNER der] \
        "tclpdf: the signature is not a DER object - a CMS\
        SignedData object (12.8.3.3.1) is written as an ASN.1 SEQUENCE and\
        every one of those begins with the byte 0x30. This one begins with\
        0x[format %02x [scan [string index $der 0] %c]]. \"openssl cms\
        -sign -outform DER\" writes what belongs here"
  }
  return
}

# The signer called, its answer checked, and the file with the answer in it.
#
# The whole of the signing step, and it exists once because there are two
# callers of it - the document's own afterWrite and [add] - and every check
# in it is one neither of them may be the one to forget. Answers the patched
# bytes and the length of the DER object.
#
# It does not write anything: whoever called it decides what to do with a
# file whose signer failed, and the two answer that differently (see
# [SignAfterWrite]).
proc ::tclpdf::sign::Signed {data located byteRange length signer what} {
  set der [uplevel #0 [list {*}$signer [Bytes $data $byteRange]]]
  if {$der eq {}} {
    return -code error -errorcode [list TCLPDF SIGN SIGNER empty] \
        "tclpdf: the -signer prefix answered nothing - it\
        has to answer a CMS SignedData object in DER, which is what\
        \"openssl cms -sign -outform DER\" writes"
  }
  # A signer that answers text rather than bytes, or something that is no DER
  # object at all, would be hexadecimal nonsense in the file and nothing
  # before a verifier would say so.
  Der $der
  # And a signer that states the time of signing in the CMS object takes a
  # PAdES claim away from the document it was made for. Said here rather than
  # left to a validator.
  NoSigningTime $der [dict get $located subFilter] $what
  set data [Fill $data $located $der]
  if {[string length $data] != $length} {
    return -code error -errorcode [list TCLPDF SIGN INTERNAL length] \
        "tclpdf: writing the signature into $what changed the\
        file length, which cannot be - the /ByteRange describes its own file"
  }
  return [list $data [string length $der]]
}

#
# ---------------------------------------------------------------------------
# The objects a signature is made of
# ---------------------------------------------------------------------------
#
# The signature dictionary, the field and the moment - built here rather than
# in the method that writes them, because there are TWO writers of them: the
# document's own [SignWrite], which puts them into a file being written whole,
# and [add], which puts the same objects into an incremental update on a
# finished one. Two builders would be two places where the order of the keys
# is decided, and that order is not cosmetic: [Locate] finds the placeholders
# by searching the finished file for them, and /M has to stand behind the
# reserved room or it falls outside the bytes the signature covers.
#
# The strings go through [pdfObj str] rather than through the document's own
# [Str], which asks the encryptor first. The two are the same thing wherever
# a signature exists: [$doc sign] refuses an encrypted document and
# [$doc encrypt] refuses a signed one, so a document with a signature
# dictionary in it never has a string encryptor.
#

# The signature dictionary (Table 255), as the body of one object.
#
# Every value in it is a DIRECT object, which 12.8.1 says twice and which has
# teeth: a /Contents written as "7 0 R" would put the signature outside the
# dictionary the digest covers.
#
# /SubFilter, /ByteRange and /Contents stand next to each other and in this
# order - the file is searched for them afterwards, and [Locate] expects to
# find each just beside the one before it. /M comes last, and that too is
# required rather than tidy: everything behind the reserved room lies in the
# second range, so the entry that gets filled in later is inside what the
# signature covers.
#
# /Contents is written as raw syntax rather than as a hexadecimal string: the
# value is the one string 7.6.2 exempts from encryption, and it is not a value
# at all yet but the room for one.
proc ::tclpdf::sign::Dictionary {values} {
  variable byteRangePlaceholder
  set pairs [list \
      Type /Sig \
      Filter /Adobe.PPKLite \
      SubFilter [dict get $values subFilter] \
      ByteRange $byteRangePlaceholder \
      Contents <[string repeat 0 [expr {2 * [dict get $values size]}]]>]
  foreach {key entry} {name Name reason Reason location Location
      contact ContactInfo} {
    if {[dict get $values $key] ne {}} {
      lappend pairs $entry [::tclpdf::pdfObj str [dict get $values $key]]
    }
  }
  if {[dict get $values date] ne {}} {
    lappend pairs M [::tclpdf::pdfObj str [dict get $values date]]
  }
  return [::tclpdf::pdfObj dictionary $pairs]
}

# The signature field and its widget annotation, in ONE object: a signature
# field never refers to more than one annotation (12.7.5.5), and 12.5.6.19
# lets the two dictionaries be merged in exactly that case.
#
# "value" and "page" are the references to the signature dictionary and to the
# page, "rect" the rectangle of a visible field and "appearance" the reference
# to its form XObject - all four as PDF syntax, because where they come from
# differs between the two writers and none of it is decided here.
#
# Without a rectangle the widget is the invisible signature of the standard's
# own example (12.8.5.3): /Rect [0 0 0 0], which Table 166 is the one
# exception for - it needs no appearance stream, and there is none.
#
# /F 4 in both cases, and it is not the invisibility that asks for it:
# veraPDF rule 6.3.2-2 wants Print set and Hidden, Invisible, NoView and
# ToggleNoView clear of EVERY annotation, so a visible field carries the same
# flags as the invisible one.
#
# "describe" is what PDF/UA asks of the same object and what the direct
# writer fills in: /TU, the field's accessible name (ISO 32000-2, 14.9.3),
# /Contents, this widget's own description (ISO 14289-2, 8.10.2.3), and
# /StructParent, the annotation's half of the join to the Form structure
# element that encloses it (ISO 32000-2, 14.7.5.4). All three empty for the
# incremental writer, which refuses a file that claims PDF/UA rather than
# rebuilding a structure tree it did not write - see [add].
#
# The keys stand where a form field puts them: /TU beside /T, which is the
# field's half, and /Contents and /StructParent at the end with /F and /P,
# which are the annotation's - the order [FieldWidgetPairs] and
# [FieldCommonPairs] give a merged field in field.tcl.
proc ::tclpdf::sign::Widget {field value page rect appearance {describe {}}} {
  set describe [dict merge {tooltip {} contents {} structParent {}} $describe]
  set annotation [list \
      Type /Annot \
      Subtype /Widget \
      FT /Sig \
      T [::tclpdf::pdfObj str $field]]
  if {[dict get $describe tooltip] ne {}} {
    lappend annotation TU [::tclpdf::pdfObj str [dict get $describe tooltip]]
  }
  lappend annotation V $value
  if {$rect eq {}} {
    lappend annotation Rect [::tclpdf::pdfObj arr {0 0 0 0}]
  } else {
    lappend annotation Rect $rect \
        AP [::tclpdf::pdfObj dictionary [list N $appearance]]
  }
  lappend annotation F 4 P $page
  if {[dict get $describe contents] ne {}} {
    lappend annotation Contents \
        [::tclpdf::pdfObj str [dict get $describe contents]]
  }
  # A key pointing into a parent tree that has no entry for it is worse than
  # none, so it is written only where a Form structure element was actually
  # made - the same rule [FieldWidgetPairs] follows for every other widget.
  if {[dict get $describe structParent] ne {}} {
    lappend annotation StructParent [dict get $describe structParent]
  }
  return [::tclpdf::pdfObj dictionary $annotation]
}

# What goes into /M, the time of signing, for a file of this version.
#
# "now" is the moment of SIGNING, and the two ways of signing reach it
# differently: where a signer signs the document as it is written, the moment
# is the write and the value is written outright; where there is none, the
# signing happens elsewhere and later, and what goes in is the placeholder
# that [::tclpdf::sign digest] writes the real time over. An explicit date is
# the caller's own statement and is written as it stands; the empty string
# keeps the entry out altogether.
proc ::tclpdf::sign::Moment {date signer version} {
  if {$date ne "now"} {
    # In the spelling this file uses: the caller's date was held against the
    # version the document had at the [sign] call, and the version can move
    # afterwards - which for /M is not cosmetic, since the value has to fit
    # the room the placeholder holds. See [respellDate] in document.tcl.
    return [::tclpdf::document::respellDate $date $version]
  }
  if {$signer eq {}} {
    return [DatePlaceholder $version]
  }
  return [::tclpdf::pdfObj date {} $version]
}

#
# ---------------------------------------------------------------------------
# The two-stage way
# ---------------------------------------------------------------------------
#
# For a signature that is not made in this process: the document is written
# without -signer, these two carry it to whoever holds the key and back.
#

# What is to be signed in a prepared file.
#
#   set job [::tclpdf::sign digest invoice.pdf]
#   set der [signWithTheCard [dict get $job bytes]]
#   ::tclpdf::sign embed invoice.pdf $der
#
# Answers a dictionary: bytes (what the CMS object has to be made over),
# byteRange (the four numbers as the file states them), offset (where the
# value will go), size (how many bytes are reserved for it), subFilter (what
# the file claims to be, which decides what [embed] accepts) and date (the
# time of signing this call wrote, empty where the file states one of its
# own).
#
# THIS CALL WRITES THE FILE, in the one way that is length-neutral: the /M
# placeholder is replaced by the time of signing before the bytes are handed
# out. It has to happen here and it can happen nowhere else - /M lies inside
# the second range, so a date written after this moment would break the very
# digest being prepared, and one written when the document was made would be
# the moment of preparing rather than of signing. -date names another time,
# which is for the caller who signs at a moment they have to state rather
# than measure; it has to be spelled as [pdfObj date] spells it, because it
# is written into the room the placeholder holds and not a character more.
proc ::tclpdf::sign::digest {path args} {
  set options [::tclpdf::option parse {date now} $args "sign digest"]
  set date [dict get $options date]
  if {$date ne "now" && [::tclpdf::document::parseDate $date] eq {}} {
    return -code error -errorcode [list TCLPDF SIGN ARGUMENT date] \
        "tclpdf: sign digest -date takes a PDF date such as\
        D:20260818120000+02'00' (ISO 32000-1, 7.9.4) or \"now\", which is the\
        default and means the moment the bytes are handed out - not \"$date\""
  }
  set data [::tclpdf::io read $path]
  set what "\"$path\""
  # 0: a file that is already signed answers this question as well, and
  # answering it is all this call then does - there is no placeholder left to
  # write over, so the file is not touched.
  set located [Locate $data $what 0]
  Prepared $located $what
  set byteRange [Describes $data $located $what]

  # A file whose /M is not the placeholder is left as it is: the document was
  # written with a -date naming a time of its own, or with -date {} and no
  # entry at all, and both are the caller's own statement about the time -
  # not something to be overwritten by a second call that knows less.
  #
  # AND ONLY WHILE THE VALUE IS STILL TO COME. A file whose /Contents already
  # holds a CMS object has had these very bytes signed, and /M lies among
  # them: writing the time into it now would destroy the signature that
  # covers it. Such a file is answered about and not touched - which is what
  # is left of this call once there is nothing to prepare.
  set range [LocateDate $data $located $what]
  if {[llength $range] && [Waiting $data $located]} {
    if {$date eq "now"} {
      set date [::tclpdf::pdfObj date {} [HeaderVersion $data]]
    }
    set length [string length $data]
    set data [WriteDate $data $range $date $what]
    if {[string length $data] != $length} {
      return -code error -errorcode [list TCLPDF SIGN INTERNAL length] \
          "tclpdf: writing the signing time into $what changed\
          the file length, which cannot be - the /ByteRange describes its own\
          file"
    }
    ::tclpdf::io write $path $data
  } else {
    set date {}
  }
  return [dict create bytes [Bytes $data $byteRange] byteRange $byteRange \
      offset [dict get $located contents] \
      size [expr {[dict get $located hexLength] / 2}] \
      subFilter [dict get $located subFilter] date $date]
}

# Put a DER-encoded CMS object into a prepared file. Answers its length in
# bytes; refuses one that does not fit, with the error code above.
proc ::tclpdf::sign::embed {path der} {
  # Before the file is even read: a caller who hands over text rather than
  # bytes is told so by the same sentence the write way says it with.
  Der $der
  set data [::tclpdf::io read $path]
  set what "\"$path\""
  set located [Locate $data $what]
  Prepared $located $what
  # And the file still has to describe itself - the same question [digest]
  # asks. Embedding into a file that was changed after it was written puts a
  # real signature over the wrong bytes, which no verifier accepts and no
  # structural check notices.
  Describes $data $located $what
  # What the file claims decides what may go into it: a PAdES claim and a
  # signing time in the CMS object cannot both stand. The claim is read out
  # of the file, because in this way there is no document object left to ask.
  NoSigningTime $der [dict get $located subFilter] $what
  set filled [Fill $data $located $der]
  if {[string length $filled] != [string length $data]} {
    return -code error -errorcode [list TCLPDF SIGN INTERNAL length] \
        "tclpdf: writing the signature into $what changed the\
        file length, which cannot be - the /ByteRange describes its own file"
  }
  ::tclpdf::io write $path $filled
  return [string length $der]
}

#
# ---------------------------------------------------------------------------
# The options both entry points check
# ---------------------------------------------------------------------------
#
# [$doc sign] and [::tclpdf::sign add] take the same options and refuse the
# same values, so the sentences that explain them exist once. "what" is the
# call being made - "sign" or "sign add" - and is the only difference between
# the two readings.
#

# Which /SubFilter, and with it which claim the file makes about itself.
# Table 255 leaves a writer exactly two values: /adbe.pkcs7.detached arrived
# with PDF 1.6, /ETSI.CAdES.detached - PAdES - with 2.0, and neither is
# deprecated. The two that are deprecated for writers, adbe.x509.rsa_sha1 and
# adbe.pkcs7.sha1, are not offered at all ("PDF writers shall not use this
# value"), which is why the error names the ones that exist rather than the
# one that was asked for.
#
# It is a CHOICE and not a consequence of the file version. tclpdf read it off
# the version until 2026-08-20, and that coupling was built so that a PDF/A-3
# invoice - written as 1.7 at most - stays signable; but what came out of it
# was a PAdES claim made by the file format rather than by anybody, on
# documents whose signer then broke it (see [NoSigningTime]). The default is
# the value that claims less.
proc ::tclpdf::sign::SubFilter {value what} {
  switch -- $value {
    pkcs7 {return /adbe.pkcs7.detached}
    cades {return /ETSI.CAdES.detached}
  }
  return -code error -errorcode [list TCLPDF SIGN ARGUMENT subfilter] \
      "tclpdf: $what -subfilter is the signature profile and\
      takes \"pkcs7\" for /adbe.pkcs7.detached (PDF 1.6, and the default) or\
      \"cades\" for /ETSI.CAdES.detached (PDF 2.0, and the claim to be a\
      PAdES signature - ETSI EN 319 142-1), not \"$value\""
}

# What the /SubFilter and the date have to say to one another.
#
# ETSI EN 319 142-1, Table 1 puts "the entry with the key M in the Signature
# Dictionary" at "shall be present" for every baseline level - B-B, B-T, B-LT
# and B-LTA alike - and its note g) spells out what belongs there: "the
# generator shall include the claimed UTC time of the signature". A document
# that claims PAdES and states no time is therefore not one, and "-date {}"
# is precisely the call that states none.
#
# REFUSED RATHER THAN OVERRULED. "-date {}" is the caller saying that no time
# is to be stated - ISO 32000-2, Table 255 read to the letter, which
# recommends /M only where the signature itself carries no time - and writing
# one anyway would answer a request with its opposite. The other half of the
# same table row is already refused this way and not repaired either: a CMS
# object stating a signing time is turned away under cades ([NoSigningTime])
# rather than stripped. One line of one table, one kind of answer.
proc ::tclpdf::sign::Claim {subFilter date what} {
  if {$subFilter ne "/ETSI.CAdES.detached" || $date ne {}} {
    return
  }
  return -code error -errorcode [list TCLPDF SIGN ARGUMENT date] \
      "tclpdf: $what -date {} keeps /M out of the signature\
      dictionary and -subfilter cades claims a PAdES signature, where ETSI\
      EN 319 142-1, Table 1 has the M entry at \"shall be present\" for every\
      baseline level - it is where the claimed time of signing stands (note\
      g). The two cannot both stand: leave -date at \"now\", which means the\
      moment of signing, name a time of your own, or write the document with\
      -subfilter pkcs7, which claims no PAdES"
}

# How much room is reserved for the signature value.
proc ::tclpdf::sign::Size {value what} {
  if {![string is integer -strict $value] || $value < 1} {
    return -code error -errorcode [list TCLPDF SIGN ARGUMENT size] \
        "tclpdf: $what -size is the number of bytes reserved\
        for the signature and takes a positive integer, not \"$value\".\
        Measured: a CMS object with an RSA-2048 certificate and its issuer\
        is 2599 bytes, one with ECDSA P-256 2209 - the default of 16384\
        leaves room for a timestamp and a longer chain"
  }
  return $value
}

# Which page the widget sits on, counted as [page current] counts.
proc ::tclpdf::sign::PageIndex {value what} {
  if {![string is integer -strict $value] || $value < 0} {
    return -code error -errorcode [list TCLPDF SIGN ARGUMENT page] \
        "tclpdf: $what -page is a page index counted from 0,\
        as \"page current\" counts, not \"$value\""
  }
  return $value
}

# The command prefix that answers the CMS object. Only its SHAPE is checked
# here - whether it is callable at all is answered when it is called, and by
# then there is a file to point at.
proc ::tclpdf::sign::Signer {value what} {
  if {[catch {llength $value}]} {
    return -code error -errorcode [list TCLPDF SIGN ARGUMENT signer] \
        "tclpdf: $what -signer is a command prefix, called as\
        \"{*}\$prefix \$bytes\" and answering a CMS SignedData object in\
        DER - \"$value\" is not a well-formed list"
  }
  return $value
}

#
# ---------------------------------------------------------------------------
# A further signature on a finished file
# ---------------------------------------------------------------------------
#
#   ::tclpdf::sign add invoice.pdf -signer mySigner -reason "Countersigned"
#
# A second signature - or a third - onto a file that is already finished, and
# a first one onto a file this package did not write. It goes in as an
# incremental update (ISO 32000-2, 7.5.6): every byte the file had stays where
# it is, and everything new is appended behind the last %%EOF. That is not one
# way of doing it among several, it is the only one - a signature covers the
# bytes of the file it sits in, so anything that rewrites the file breaks the
# signature already there.
#
# A PACKAGE COMMAND, NOT A DOCUMENT METHOD, and it stands beside [digest] and
# [embed] for the reason those two do: the subject is a finished file on disk,
# addressed by its path. There is no document object for it and there cannot
# be one - what the objects of a foreign file mean, and what else points at
# them, is exactly the knowledge a reader does not have. [$doc sign] is the
# call for a document being written; this is the call for a file that exists.
#
# IT IS CALLED "add" AND NOT "append" for a reason worth writing down: a proc
# named ::tclpdf::sign::append would shadow the core [append] command for
# every other proc in this namespace, and four of them build strings with it.
# The name that reads best is the name that breaks the module.
#
# WHAT IT WRITES, and it is more than the signature dictionary. Measured on a
# doubly signed file made by pyHanko (2026-08-21): the dictionary, the field
# and its widget are NEW objects, and two objects the file already has get a
# second copy - the CATALOG, whose /AcroForm has to list the new field and
# carry /SigFlags 3, and the PAGE the widget sits on, whose /Annots has to
# name it. Appending the dictionary alone produces a field that stands in no
# /Fields array, which is a signature no form-aware reader finds. Where the
# file has no /AcroForm at all - because it was never signed - one is written.
#
# THE /ByteRange OF THE NEW SIGNATURE COVERS THE WHOLE FILE, and 12.8.1 says
# how far exactly: "from the '%PDF-' comment at the beginning of the PDF
# document to the end of the '%%EOF' comment, possibly followed by an optional
# EOL marker, terminating the incremental update that adds the digital
# signature dictionary". Since this call appends exactly one update and that
# update's %%EOF is the last thing in the file, the range is the whole file
# minus the value of /Contents - the same arithmetic [Range] does for a
# document written in one piece. One byte short of it and pdfsig turns from
# "Total document signed" to "Not total document signed" without anything
# being cryptographically wrong.
#
# THE OLDER SIGNATURE STAYS VALID and keeps covering ITS OWN revision, which
# is what 7.5.6 makes possible and what nothing here may disturb: the appended
# bytes lie outside its ranges, and its own bytes are not touched. pdfsig then
# reports "Not total document signed" for it - and that is the CORRECT answer
# for an older signature on a file that has grown since, not a defect.
#
# WHAT IS NOT BUILT HERE, each refused by name rather than written wrong:
#
#   A VISIBLE field. What a visible field shows is a form XObject, and drawing
#   one takes a document: a font, a unit, a layout. This call has a file and
#   no document, so -rect and -appearance are not offered at all. A first
#   signature that is to be visible is written with [$doc sign -rect].
#
#   RAISING THE FILE'S VERSION. The header is inside the bytes that stay
#   untouched, so a file below the version floor of the /SubFilter asked for
#   is refused rather than raised. 7.5.6 NOTE 4 describes the one way to raise
#   it - a /Version entry in a replaced catalog - and it is not written here
#   behind the caller's back: on a PDF/A file, which is a profile of ISO
#   32000-1, that entry would break the profile.
#
#   A SECOND SIGNATURE ONTO AN UNFINISHED ONE. A file whose newest signature
#   still holds the reserved zeros is refused: [digest] and [embed] reach the
#   NEWEST signature of a file, so filling the older one afterwards is not
#   possible, and signing it BEFORE would sign bytes this update then changes.
#   Finish that signature first, then add the next.
#
#   A DOCUMENT TIMESTAMP (/Type /DocTimeStamp) and a certification (/DocMDP).
#   Both are dictionaries of their own with their own rules, and neither is
#   what this call writes.
#
#   A SIGNATURE ON A FILE THAT CLAIMS PDF/UA. The widget would land on a page
#   without /Tabs /S and outside the structure tree, which is a conformant
#   file made non-conformant by a call that says nothing - see the refusal in
#   [add] for what an incremental update would have to rewrite, and why that
#   is knowable for a document being written and not for a foreign file.
#

# Answers what was written, as a dictionary: field, page, size, subFilter,
# date, signed, byteRange, length (the CMS object's size, empty where none was
# written) and appended (how many bytes the update added).
proc ::tclpdf::sign::add {path args} {
  # Required HERE rather than at the head of this file, and it is the point of
  # the split: a document that signs itself needs no PDF reader, and pulling
  # import.tcl and update.tcl into every signing script would be a dependency
  # nobody asked for. A file that is signed a second time cannot avoid them.
  package require tclpdf::update 1.0-

  set options [::tclpdf::option parse {
    signer {} size 16384 name {} reason {} location {} contact {}
    date now field {} page 0 subfilter pkcs7
  } $args "sign add"]
  set subFilter [SubFilter [dict get $options subfilter] "sign add"]
  set size [Size [dict get $options size] "sign add"]
  set page [PageIndex [dict get $options page] "sign add"]
  set signer [Signer [dict get $options signer] "sign add"]
  set date [dict get $options date]
  Claim $subFilter $date "sign add"

  set data [::tclpdf::io read $path]
  set what "\"$path\""

  # The version floor of the /SubFilter, read off the file's own header
  # because that is where the version of a file stands and an update cannot
  # move it.
  set version [HeaderVersion $data]

  # The date, held against THAT version - the file's, not this process's.
  # 7.9.4 spells the zone offset with a closing apostrophe in 1.x and
  # without it in 2.0, and the value goes into /M as it was written; the
  # package spells its own dates that way ([Moment] hands the version to
  # [pdfObj date] and to [DatePlaceholder]), and a caller's has to match.
  # Nothing has been written at this point - the file has only been read.
  if {$date ni {{} now}
      && [::tclpdf::document::parseDate $date $version] eq {}} {
    return -code error -errorcode [list TCLPDF SIGN ARGUMENT date] \
        "tclpdf: sign add -date takes a PDF date as a\
        $version file spells it - [expr {[package vcompare $version 2.0] < 0
            ? {D:20260818120000+02'00' (ISO 32000-1, 7.9.4)}
            : {D:20260818120000+02'00 (ISO 32000-2, 7.9.4, which struck the\
               closing apostrophe)}}] - or \"now\", which is the default and\
        means the moment of signing, or the empty string for no /M at all.\
        Not \"$date\""
  }
  set floor [expr {$subFilter eq "/ETSI.CAdES.detached" ? "2.0" : "1.6"}]
  if {[package vcompare $version $floor] < 0} {
    return -code error -errorcode [list TCLPDF VERSION $floor] \
        "tclpdf: $what states version $version in its header\
        and $subFilter needs $floor (ISO 32000-2, Table 255) - an incremental\
        update cannot raise it, because the header is inside the bytes it\
        leaves untouched. 7.5.6 NOTE 4 names the one way, a /Version entry in\
        the catalog, and this call does not write it: on a PDF/A file that\
        entry would break the profile"
  }

  # A signature that is still waiting for its value, and why that is the end
  # of the road rather than something to work around - see the head of this
  # section.
  #
  # Read off the whole file rather than through [Locate], and each half of
  # that is deliberate. THE WHOLE FILE, because an unfilled signature ANYWHERE
  # in it can no longer be filled once this update is appended - [embed]
  # reaches the newest one - so an older one waiting for its value is the same
  # dead end as the newest. NOT THROUGH [Locate], because the signature found
  # here may be a foreign one: [Locate] reads the dictionary tclpdf writes,
  # with /SubFilter, /ByteRange and /Contents in that order and next to each
  # other, and a file that has been through qpdf has them in another. What
  # says it beyond doubt is the value itself - a /Contents that is nothing but
  # zeros between its delimiters is reserved room and not a signature, since
  # every DER object begins with 0x30. And that /Contents has to belong to a
  # SIGNATURE: the search used to be over the whole file for the two words
  # alone, so an annotation whose /Contents was written as a hexadecimal
  # string of zeros - "<00>", which tclpdf never writes and a foreign tool
  # may - locked the file out of [add] for good. /ByteRange next to it is
  # what tells a signature dictionary from anything else, and it is the one
  # part of the dictionary no reordering moves away from /Contents.
  if {[WaitingAnywhere $data]} {
    return -code error -errorcode [list TCLPDF SIGN STATE waiting] \
        "tclpdf: a signature of $what is still waiting for its\
        value - its /Contents holds nothing but the reserved zeros. Put the\
        CMS object in with \[::tclpdf::sign embed\] first: appending a further\
        signature now would cover those zeros, and the object that belongs\
        there could never be written without breaking it"
  }

  # A FILE THAT CLAIMS PDF/UA IS NOT SIGNED HERE, and the refusal stands
  # before the update session is opened - nothing has been read into a
  # session, nothing added, nothing written.
  #
  # A signature widget is an annotation, and PDF/UA asks three things of the
  # page and the tree it lands in: /Tabs /S on every page that carries an
  # annotation (ISO 14289-1, 7.18.3), a Form structure element enclosing the
  # widget (7.18.4; ISO 14289-2, 8.10.1) and an accessible description
  # (7.18.1). An incremental update (7.5.6) can only add objects and replace
  # whole ones, so meeting them means rewriting the page, the parent tree,
  # the element the Form belongs under and the structure tree root of a file
  # THIS PACKAGE DID NOT WRITE - a number tree that may be several levels of
  # /Kids and /Limits deep, and an element nesting that differs from one
  # producer to the next. That is the difference between the two entry
  # points: [$doc sign] knows the tree because it built it, and this call is
  # for files it has never seen.
  #
  # Measured 2026-08-26: a veraPDF-conformant PDF/UA-1 file came out of this
  # call failing clause 7.18.3, test 1 - and the /Tabs alone would have made
  # it validator-green while the widget still stood outside the tree. Half a
  # repair on a conformance claim is worse than none, so the file is left
  # exactly as it was.
  #
  # The claim is read through the reader's public side - the same "pdfua"
  # entry [::tclpdf::pdf info] answers a caller with, out of the pdfuaid
  # namespace of the XMP packet. A file that cannot be read at all makes no
  # claim, and what is wrong with it is [::tclpdf::update open]'s sentence to
  # say two lines further down, in its own vocabulary.
  package require tclpdf::importInfo 1.0-
  if {![catch {::tclpdf::pdf info $path} facts]
      && [dict exists $facts pdfua] && [dict get $facts pdfua] ne {}} {
    return -code error -errorcode [list TCLPDF SIGN STATE ua] \
        "tclpdf: $what claims PDF/UA-[dict get $facts pdfua] and\
        \[::tclpdf::sign add\] would break that claim - a signature widget is\
        an annotation, and PDF/UA asks for /Tabs /S on its page (ISO 14289-1,\
        7.18.3), for a Form structure element around it (7.18.4; ISO 14289-2,\
        8.10.1) and for a description (7.18.1), none of which an incremental\
        update can add to a structure tree this package did not write. Sign\
        the document as it is written, with \[\$doc sign\], which builds all\
        three; or prepare it that way and hand the finished file to\
        \[::tclpdf::sign digest\] and \[::tclpdf::sign embed\]. The file is\
        unchanged"
  }

  set upd [::tclpdf::update open $path]
  try {
    if {[$upd base] != [string length $data]} {
      return -code error -errorcode [list TCLPDF SIGN CHANGED $what] \
          "tclpdf: $what changed while it was being signed -\
          it was [string length $data] bytes and the update read [$upd base]"
    }

    set catalog [Number [$upd trailer Root] $what "the trailer's /Root"]
    set catalogValue [Value [$upd body $catalog]]
    set pageNumber [PageNumber $upd $catalogValue $page $what]

    # The field's partial name has to be unique among its siblings
    # (12.7.4.2), and the one name a caller would otherwise take is the one
    # the signature already there took. So the default is the first free name
    # of the form the readers use, and a name that is taken is refused rather
    # than written twice.
    # A certification that forbids every change. Asked before the first
    # object is added to the session, so a refusal leaves the file as it was.
    # Measured 2026-08-26: a file with /Perms << /DocMDP ... >> and
    # /TransformParams << /P 1 >> took a second signature without a word -
    # 33 506 bytes appended, two fields afterwards - and the result is a
    # document whose certification signature every verifier reports as
    # broken. /P 2 and /P 3 expressly allow a further signature (Table 257),
    # so only 1 is refused.
    set docMdp [DocMdp $upd $catalogValue]
    if {$docMdp eq "1"} {
      return -code error -errorcode [list TCLPDF SIGN STATE certified] \
          "tclpdf: $what is certified with DocMDP /P 1, which\
          permits no change to the document at all (ISO 32000-2, 12.8.4.2,\
          Table 257) - appending a signature is a change, and it would\
          invalidate the certification signature that is already there.\
          /P 2 and /P 3 do allow a further signature"
    }

    set taken [FieldNames $upd $catalogValue]
    set field [dict get $options field]
    if {$field eq {}} {
      set number 1
      while {"Signature$number" in $taken} {
        incr number
      }
      set field "Signature$number"
    } elseif {$field in $taken} {
      return -code error -errorcode [list TCLPDF SIGN FIELD $field] \
          "tclpdf: $what already carries a signature field\
          named \"$field\" - a partial field name has to be unique among its\
          siblings (ISO 32000-2, 12.7.4.2). Taken are: [join $taken {, }].\
          Leave -field out and the first free name of the form Signature<n>\
          is used"
    }

    # The two new objects: the dictionary with both placeholders in it, and
    # the field merged with its widget. Written through the same two builders
    # the document's own write uses, into the numbering of the file being
    # continued - which is what makes an update session speak the writer's
    # vocabulary in the first place.
    set signature [$upd add [Dictionary [dict create \
        subFilter $subFilter size $size \
        name [dict get $options name] reason [dict get $options reason] \
        location [dict get $options location] \
        contact [dict get $options contact] \
        date [Moment $date $signer $version]]]]
    set widget [$upd add [Widget $field [$upd ref $signature] \
        [$upd ref $pageNumber] {} {}]]

    # And the two objects that already exist and now say something more.
    Enlist $upd $catalog $catalogValue $widget
    Annotate $upd $pageNumber $widget

    # The appendix rather than [$upd write]: the file is written ONCE, with
    # the two patches already in it. A signer that fails - and one that
    # cannot fit its object into the reserved room is a signer that fails -
    # then leaves the file exactly as it found it, instead of leaving a
    # prepared signature nobody asked for behind.
    set appended [$upd appendix]
  } finally {
    $upd destroy
  }

  append data $appended
  set length [string length $data]
  set located [Locate $data $what]
  set byteRange [Range $data $located]
  set data [WriteRange $data $located $byteRange]
  if {[string length $data] != $length} {
    return -code error -errorcode [list TCLPDF SIGN INTERNAL length] \
        "tclpdf: writing /ByteRange into $what changed the file\
        length, which cannot be - it describes its own file"
  }

  set signed 0
  set derLength {}
  if {$signer ne {}} {
    # No catch around it, and that is the promise this call makes: nothing has
    # been written yet, so a signer that fails leaves the file exactly as it
    # found it - the update is thrown away with the error.
    lassign [Signed $data $located $byteRange $length $signer $what] \
        data derLength
    set signed 1
  }
  ::tclpdf::io write $path $data
  return [dict create field $field page $page size $size subFilter $subFilter \
      date [dict get $options date] signed $signed byteRange $byteRange \
      length $derLength appended [string length $appended]]
}

# An object body as a parsed value, and back again.
#
# The parser is import.tcl's own, run over the syntax [$upd body] hands back
# rather than over the file: an update session answers with the object as the
# file has it, and reading it with regular expressions is how a /Fields array
# that happens to be an indirect reference becomes a silent mistake. The map
# [Serialize] renumbers references through is the identity here - an update
# writes into the file's own numbering, so every number stays the one it was.
proc ::tclpdf::sign::Value {body} {
  set position 0
  return [::tclpdf::importRead::Parse $body position]
}

proc ::tclpdf::sign::Syntax {value} {
  set map {}
  foreach number [::tclpdf::importRead::Refs $value] {
    dict set map $number $number
  }
  return [::tclpdf::importRead::Serialize $value $map]
}

# The object number a reference names, from PDF syntax or from a parsed value.
proc ::tclpdf::sign::Number {reference what which} {
  if {[lindex $reference 0] eq "r"} {
    return [lindex [lindex $reference 1] 0]
  }
  if {[regexp {^\s*([0-9]+)\s+[0-9]+\s+R\s*$} $reference -> number]} {
    return $number
  }
  return -code error -errorcode [list TCLPDF SIGN FOREIGN $which] \
      "tclpdf: $which of $what is \"$reference\" and an\
      indirect reference was needed - the file is not one an update can be\
      appended to"
}

# One level of indirection resolved: a value that is a reference, read back as
# the object it names.
proc ::tclpdf::sign::Direct {upd value} {
  if {[lindex $value 0] ne "r"} {
    return $value
  }
  return [Value [$upd body [lindex [lindex $value 1] 0]]]
}

# The object number of the page at that index, counted from 0 as [page
# current] counts, by walking the page tree the way 7.7.3.4 describes it.
#
# The NUMBER rather than the dictionary, which is what [import::Page] answers
# and why that one is not used here: the widget needs a /P pointing at the
# page, and the page needs a second copy of itself with /Annots in it.
proc ::tclpdf::sign::PageNumber {upd catalogValue index what} {
  set node [Number [::tclpdf::importRead::Get $catalogValue Pages] $what \
      "the /Pages entry of the catalog"]
  set remaining [expr {$index + 1}]
  set total 0
  while {1} {
    set value [Value [$upd body $node]]
    if {[lindex [::tclpdf::importRead::Get $value Type] 1] eq "Page"} {
      return $node
    }
    if {!$total} {
      set total [lindex [Direct $upd \
          [::tclpdf::importRead::Get $value Count]] 1]
    }
    set kids [Direct $upd [::tclpdf::importRead::Get $value Kids]]
    set descended 0
    foreach kid [lindex $kids 1] {
      set number [Number $kid $what "a /Kids entry of the page tree"]
      set child [Value [$upd body $number]]
      if {[lindex [::tclpdf::importRead::Get $child Type] 1] eq "Pages"} {
        set count [lindex [Direct $upd \
            [::tclpdf::importRead::Get $child Count]] 1]
      } else {
        set count 1
      }
      if {$remaining <= $count} {
        set node $number
        set descended 1
        break
      }
      incr remaining -$count
    }
    if {!$descended} {
      return -code error -errorcode [list TCLPDF SIGN ARGUMENT page] \
          "tclpdf: sign add -page $index names a page $what\
          does not have - it has $total page[expr {$total == 1 ? {} : {s}}].\
          The signature widget sits on a page, and that page has to exist"
    }
  }
}

# The DocMDP permission a certified file states, or the empty string.
#
# 12.8.4.2: a certification signature is the one signature that says what may
# be done to the document afterwards. The catalog carries /Perms /DocMDP
# pointing at that signature dictionary, its /Reference holds a signature
# reference dictionary with /TransformMethod /DocMDP, and its
# /TransformParams /P is the number of Table 257: 1 - "No changes to the
# document shall be permitted; any change to the document shall invalidate
# the signature", 2 - filling in forms and signing is allowed, 3 - and
# commenting as well. 2 is the default when /P is absent.
#
# Read defensively at every step: a file that has none of this is the normal
# case and answers the empty string, and a /Perms written in a shape this
# does not recognise is not an error either - the question being asked is
# "does this file forbid what is about to be done", and only a clear yes
# counts.
proc ::tclpdf::sign::DocMdp {upd catalogValue} {
  set perms [Direct $upd [::tclpdf::importRead::Get $catalogValue Perms]]
  if {[lindex $perms 0] ne "d"} {
    return {}
  }
  set entry [::tclpdf::importRead::Get $perms DocMDP]
  if {$entry eq {}} {
    return {}
  }
  set signature [Direct $upd $entry]
  set references [Direct $upd [::tclpdf::importRead::Get $signature Reference]]
  if {[lindex $references 0] ne "a"} {
    return {}
  }
  foreach reference [lindex $references 1] {
    set value [Direct $upd $reference]
    if {[lindex [::tclpdf::importRead::Get $value TransformMethod] 1]
        ne "DocMDP"} {
      continue
    }
    set params [Direct $upd \
        [::tclpdf::importRead::Get $value TransformParams]]
    set p [::tclpdf::importRead::Get $params P]
    if {$p eq {}} {
      # Table 257: the default.
      return 2
    }
    if {[lindex $p 0] eq "n" && [string is integer -strict [lindex $p 1]]} {
      return [lindex $p 1]
    }
    return {}
  }
  return {}
}

# The /AcroForm of the file, as {value number}: the parsed dictionary and, for
# one that stands in the catalog as a reference, the object it lives in - the
# empty string where it is written into the catalog itself or is not there at
# all. Both spellings occur; tclpdf writes the direct one, and the file that
# was measured for this used the other.
proc ::tclpdf::sign::AcroForm {upd catalogValue} {
  set entry [::tclpdf::importRead::Get $catalogValue AcroForm]
  if {$entry eq {}} {
    return [list [list d {}] {}]
  }
  if {[lindex $entry 0] eq "r"} {
    set number [lindex [lindex $entry 1] 0]
    return [list [Value [$upd body $number]] $number]
  }
  return [list $entry {}]
}

# The partial names of the fields the file already has - the /T of every entry
# in /Fields. Only the top level is read, and that is what 12.7.4.2 asks for:
# a name has to be unique among its SIBLINGS.
proc ::tclpdf::sign::FieldNames {upd catalogValue} {
  lassign [AcroForm $upd $catalogValue] form
  set fields [Direct $upd [::tclpdf::importRead::Get $form Fields]]
  set names {}
  foreach entry [lindex $fields 1] {
    set value [Direct $upd $entry]
    set name [Text [::tclpdf::importRead::Get $value T]]
    if {$name ne {}} {
      lappend names $name
    }
  }
  return $names
}

# The text a /T holds, whichever of the two ways it is written in.
#
# BOTH ARE NEEDED, and reading only the literal one was the hole: [pdfObj str]
# writes a string of pure ASCII as a literal and EVERY other one as UTF-16BE
# in hexadecimal, so a field named "Freigabe" arrives here as {s Freigabe} and
# one whose name carries an umlaut as {h feff...}. A reader that knows only
# {s ...} does not see the second at all - and then the uniqueness 12.7.4.2
# asks for is not checked for exactly the names a caller is most likely to
# collide on, nor is the free "Signature<n>" counted correctly. A foreign
# file may write a plain ASCII name that way too, and then it was the
# numbering that walked past a taken name.
#
# The counterpart of [::tclpdf::pdfObj::Utf16Be], which writes what this
# reads. importInfo.tcl carries a reader's full version of the same thing -
# the PDFDocEncoding table, and tolerance for the UTF-16LE that files in the
# wild carry - and it is not reached for here: [add] would then require a
# whole PDF reader package to compare two field names, and what has to be
# read back is what a WRITER produced. Anything that is neither spelling is
# compared as the bytes it is, which is what a foreign file gets.
proc ::tclpdf::sign::Text {value} {
  switch -- [lindex $value 0] {
    s {
      set bytes [lindex $value 1]
    }
    h {
      # An odd number of digits is read as if a 0 followed (7.3.4.3), and
      # white space between them is not part of the string.
      set hex [regsub -all {[^0-9A-Fa-f]} [lindex $value 1] {}]
      if {[string length $hex] % 2} {
        append hex 0
      }
      set bytes [binary decode hex $hex]
    }
    default {
      return {}
    }
  }
  if {[string range $bytes 0 1] ne "\u00FE\u00FF"} {
    return $bytes
  }
  # UTF-16BE behind the byte order mark 7.9.2.2 asks for. Combined by hand
  # rather than through an encoding name, because the two interpreters do not
  # offer the same one - and the surrogate pair is put back together the way
  # [Utf16Be] took it apart, with the result checked: where [format %c]
  # cannot hold the combined value, the two halves ARE what this interpreter
  # means by that character.
  binary scan [string range $bytes 2 end] Su* units
  set out {}
  set high {}
  foreach unit $units {
    if {$high ne {}} {
      if {$unit >= 0xDC00 && $unit <= 0xDFFF} {
        set code [expr {0x10000 + (($high - 0xD800) << 10) + ($unit - 0xDC00)}]
        set char [format %c $code]
        if {[scan $char %c] == $code} {
          append out $char
        } else {
          append out [format %c%c $high $unit]
        }
        set high {}
        continue
      }
      append out [format %c $high]
      set high {}
    }
    if {$unit >= 0xD800 && $unit <= 0xDBFF} {
      set high $unit
      continue
    }
    append out [format %c $unit]
  }
  if {$high ne {}} {
    append out [format %c $high]
  }
  return $out
}

# The new field into /AcroForm /Fields, and /SigFlags 3 with it.
#
# /SigFlags 3 is SignaturesExist and AppendOnly (Table 225): the document has
# a signature field, and it may only be written on incrementally. It is SET
# rather than merged, because a file that carries a signature and says
# otherwise says something that is no longer true.
#
# Which object gets the second copy follows the file: an /AcroForm that stands
# in the catalog is written back with the catalog, one behind a reference is
# written back on its own, and a /Fields array of its own is a third. Each is
# replaced exactly where the file keeps it, which is what leaves everything
# else pointing at what it pointed at.
proc ::tclpdf::sign::Enlist {upd catalog catalogValue widget} {
  lassign [AcroForm $upd $catalogValue] form number
  set entry [::tclpdf::importRead::Get $form Fields]
  set fields [Direct $upd $entry]
  if {$fields eq {}} {
    set fields [list a {}]
  }
  set items [lindex $fields 1]
  lappend items [list r [list $widget 0]]
  if {[lindex $entry 0] eq "r"} {
    $upd replace [lindex [lindex $entry 1] 0] [Syntax [list a $items]]
  } else {
    ::tclpdf::importRead::Put form Fields [list a $items]
  }
  ::tclpdf::importRead::Put form SigFlags [list n 3]
  if {$number ne {}} {
    $upd replace $number [Syntax $form]
    return
  }
  ::tclpdf::importRead::Put catalogValue AcroForm $form
  $upd replace $catalog [Syntax $catalogValue]
  return
}

# The widget into the page's /Annots, in the second copy of the page object -
# or, where the array is an object of its own, in the second copy of that.
proc ::tclpdf::sign::Annotate {upd number widget} {
  set value [Value [$upd body $number]]
  set entry [::tclpdf::importRead::Get $value Annots]
  set annots [Direct $upd $entry]
  if {$annots eq {}} {
    set annots [list a {}]
  }
  set items [lindex $annots 1]
  lappend items [list r [list $widget 0]]
  if {[lindex $entry 0] eq "r"} {
    $upd replace [lindex [lindex $entry 1] 0] [Syntax [list a $items]]
    return
  }
  ::tclpdf::importRead::Put value Annots [list a $items]
  $upd replace $number [Syntax $value]
  return
}
#
# ---------------------------------------------------------------------------
# The document's side
# ---------------------------------------------------------------------------
#

oo::define ::tclpdf::document::document {

  # $doc sign ?-signer prefix? ?-size bytes? ?-subfilter pkcs7|cades?
  #           ?-name text? ?-reason text? ?-location text? ?-contact text?
  #           ?-date date? ?-field name? ?-page index?
  #           ?-rect {x y w h}? ?-appearance form?
  #           ?-tooltip text? ?-contents text?
  # $doc sign state             what was declared, and what came of it
  method sign {args} {
    if {[llength $args] && [string index [lindex $args 0] 0] ne "-"} {
      switch -- [lindex $args 0] {
        state {return [my SignState]}
        default {
          return -code error -errorcode [list TCLPDF SIGN ARGUMENT subcommand] \
              "tclpdf: unknown sign subcommand\
              \"[lindex $args 0]\" - known is: state"
        }
      }
    }

    # Everything down to the version call is a CHECK and changes nothing: a
    # refused call has to leave the document exactly as it was, down to the
    # version floor. The rule encrypt.tcl and pdfa.tcl follow, and for the
    # same measured reason - a half-applied claim is worse than none.
    set options [::tclpdf::option parse {
      signer {} size 16384 name {} reason {} location {} contact {}
      date now field Signature1 page 0 subfilter pkcs7 rect {} appearance {}
      tooltip {} contents {}
    } $args "sign"]

    # Which /SubFilter, how much room, which page and what the signer is:
    # the four checks [::tclpdf::sign add] makes word for word, and they are
    # made in one place - see [SubFilter] for what the value decides.
    set subFilter [::tclpdf::sign::SubFilter \
        [dict get $options subfilter] sign]
    set size [::tclpdf::sign::Size [dict get $options size] sign]
    if {[dict get $options field] eq {}} {
      return -code error -errorcode [list TCLPDF SIGN ARGUMENT field] \
          "tclpdf: sign -field is the name of the signature\
          field and cannot be empty - a field dictionary without a partial\
          field name is not a field at all, only a widget annotation (ISO\
          32000-2, 12.7.4.2)"
    }
    # And not a name a form field already has. The mirror of this check has
    # stood in field.tcl ([FieldTaken], which asks [my state sign]) since it
    # was written, and only that ONE order was ever refused: measured
    # 2026-08-26, "field text Signature1 ...; sign -field Signature1" was
    # taken, the document was written, and "qpdf --json --json-key=acroform"
    # showed two entries with "fullname": "Signature1" in one /Fields array
    # - a /Tx and a /Sig. 12.7.4.2 makes the fully qualified name the way a
    # form is addressed, and two fields under one name resolve to one:
    # whichever a reader finds first answers for both, and nothing reports
    # the other. The manual (:988) promised both orders all along.
    #
    # [state fields] is READ, not reached into: the field module owns the
    # dictionary and this is the same question it asks itself.
    set fields [my state fields]
    if {$fields ne {} && [dict exists $fields [dict get $options field]]} {
      return -code error -errorcode \
          [list TCLPDF SIGN FIELD [dict get $options field]] \
          "tclpdf: this document already has a field named\
          \"[dict get $options field]\" - both would stand in the same\
          /Fields array under one partial field name (ISO 32000-2,\
          12.7.4.2) and two fields under one name resolve to one. Pass\
          \"sign -field\" another name, or rename the form field"
    }
    # "now" is the default and says what it means - the moment of signing,
    # which for a -signer is the write and for the two-stage way is the
    # moment [::tclpdf::sign digest] hands the bytes out. The empty string
    # keeps /M out of the dictionary altogether. Anything else is a PDF date,
    # and is checked by the one check the package has for those.
    if {[dict get $options date] ni {{} now}} {
      my CheckDate [dict get $options date] "sign -date"
    }
    # And what the two say to one another: a PAdES claim without a time of
    # signing is not one (ETSI EN 319 142-1, Table 1).
    ::tclpdf::sign::Claim $subFilter [dict get $options date] sign
    set page [::tclpdf::sign::PageIndex [dict get $options page] sign]
    # The two halves of a visible field. Each is useless without the other,
    # and each without the other is a mistake that shows up nowhere until a
    # validator or a reader is asked - so it is named here. See the head of
    # this file for why the drawing itself is the caller's.
    set rect [dict get $options rect]
    set appearance [dict get $options appearance]
    if {$rect ne {} && $appearance eq {}} {
      return -code error -errorcode [list TCLPDF SIGN ARGUMENT appearance] \
          "tclpdf: sign -rect makes the signature field\
          VISIBLE, and a visible field needs something to show - pass\
          -appearance with the name of a form XObject drawn beforehand with\
          \"form create\". Without one the field is an annotation with no\
          appearance dictionary, which veraPDF rule 6.3.3-1 fails and which\
          a reader draws as nothing. Leave -rect out for the invisible\
          signature of ISO 32000-2, 12.8.5.3"
    }
    if {$appearance ne {} && $rect eq {}} {
      return -code error -errorcode [list TCLPDF SIGN ARGUMENT rect] \
          "tclpdf: sign -appearance is what a VISIBLE\
          signature field shows, and without -rect {x y w h} the field has\
          no area on the page - an appearance stream is painted into the\
          rectangle of its annotation (ISO 32000-2, 12.5.5), and a rectangle\
          of no area is painted nowhere. Pass -rect as well, or leave\
          -appearance out"
    }
    if {$rect ne {}} {
      if {[llength $rect] != 4} {
        return -code error -errorcode [list TCLPDF SIGN ARGUMENT rect] \
            "tclpdf: sign -rect is {x y w h} - the top left\
            corner of the signature field and its size, in the unit of the\
            document, as \"link -at\" and \"rect -at\" count - not \"$rect\""
      }
      # A NUMBER A PDF CAN HOLD, which is more than [string is double] asks.
      # NaN and Inf pass that test and then fail no comparison either - "NaN
      # <= 0" is false, so the width and height check below waves them
      # through as well. What they hit is the write, and there it is a raw
      # Tcl sentence about a non-numeric floating-point value - by which time
      # the state is set and the call cannot be made again. So the rule that
      # decides whether a number has a PDF spelling at all is asked here,
      # where the answer still costs nothing: [pdfObj num] refuses NaN, both
      # infinities and everything beyond the PDF real range of about
      # +/-3.403e38 (ISO 32000-1, Annex C.2).
      foreach value $rect {
        if {![string is double -strict $value]
            || [catch {::tclpdf::pdfObj num $value}]} {
          return -code error -errorcode [list TCLPDF SIGN ARGUMENT rect] \
              "tclpdf: sign -rect is {x y w h} in numbers a\
              PDF can hold - not \"$rect\". NaN, an infinity and anything\
              beyond about +/-3.403e38 have no PDF spelling (ISO 32000-1,\
              Annex C.2)"
        }
      }
      lassign $rect left top width height
      if {$width <= 0 || $height <= 0} {
        return -code error -errorcode [list TCLPDF SIGN ARGUMENT rect] \
            "tclpdf: sign -rect {$rect} has a width of $width\
            and a height of $height - a visible signature field needs both\
            above zero, or there is no area for its appearance to be painted\
            into"
      }
    }
    ::tclpdf::sign::Signer [dict get $options signer] sign

    if {[my state sign] ne {}} {
      return -code error -errorcode [list TCLPDF SIGN STATE signing] \
          "tclpdf: this document is already being signed -\
          sign is called once, because a document is written in one piece and\
          a second signature has to be appended as an incremental update (ISO\
          32000-2, 7.5.6) so that the first one keeps the bytes it covers.\
          Write this document, then put the second signature on the finished\
          file with \[::tclpdf::sign add\]"
    }
    # The mirror of this check sits in encrypt.tcl, so that whichever call
    # comes second is the one that says so. 7.6.2 takes exactly the
    # /Contents hexadecimal string out of the encryption and leaves the
    # other strings of the signature dictionary in it - buildable, and not
    # measured against a single reader.
    if {[my state encrypt] ne {}} {
      return -code error -errorcode [list TCLPDF SIGN STATE encrypted] \
          "tclpdf: this document is encrypted, and tclpdf\
          does not sign an encrypted document - 7.6.2 exempts only the\
          /Contents string of a signature dictionary from encryption, not\
          the rest of it. Drop the \[\$doc encrypt\] call or the sign call,\
          they cannot both stand"
    }

    # From here on the document changes.
    #
    # The floor follows from the value, and each of the two brings its own.
    # The default is the lower one on purpose: PDF/A-2 and -3 are profiles of
    # ISO 32000-1 and are written as 1.7 at most (pdfa.tcl says so with
    # [LimitVersion]), so a signature that demanded 2.0 would refuse every
    # ZUGFeRD invoice - by the back door, through a version error, while ISO
    # 19005-3 clause 6.4.3 expressly provides for signatures.
    #
    # The caller's signer has to produce what the SubFilter promises - a
    # CAdES-BES object for the one, a plain CMS object for the other - which
    # is why [sign state] answers the value.
    if {$subFilter eq "/ETSI.CAdES.detached"} {
      my RequireVersion 2.0 "a PAdES signature (/SubFilter\
          /ETSI.CAdES.detached - ISO 32000-2, Table 255)"
    } else {
      my RequireVersion 1.6 "a digital signature (/SubFilter\
          /adbe.pkcs7.detached - ISO 32000-2, Table 255)"
    }

    # THE WIDGET'S PLACE IN THE STRUCTURE TREE, MADE HERE AND NOT AT THE
    # WRITE. A signature field is a form field: ISO 14289-1, 7.18.4 - "A
    # Widget annotation shall be nested within a Form tag" - and ISO 14289-2,
    # 8.10.1 - "Each widget annotation shall be enclosed by a Form structure
    # element" - make no exception for /FT /Sig, and 7.18.1 wants every
    # annotation "represented in the structure tree in correct reading
    # order". Correct reading order is the order of the script, so the
    # element is opened where the caller called [sign] - an element made on
    # beforeWrite would land after everything else, which is the reason
    # field.tcl gives at [FieldStructureOpen] and the same one here.
    #
    # The core's own two halves are used rather than a second set: the Form
    # element, the object reference into it and the /StructParent key are the
    # same question for every widget of every field type, and two answers to
    # it are two answers waiting to differ. [FieldStructureOpen] does what
    # can still refuse - a Form may not stand everywhere - and
    # [FieldStructureKey] does what needs the object number; between them
    # stands nothing but the reservation, which cannot raise. In a document
    # that is not tagged both answer empty and nothing is written.
    #
    # The module is required by name because this is not the [unknown] path:
    # [FieldEnlist] and [FieldRectangle] are in the topic table of
    # document.tcl and these two are not, and the topic has to be there
    # before the first of them is called.
    #
    # It stands AFTER the version floor and BEFORE the state, so that a
    # refusal from the tree leaves a document that can be signed again -
    # [state sign] unset, and no second call answering "already being
    # signed". The floor is the one thing that stays, exactly as it does for
    # a field declared where no Form may stand.
    #
    # AND ONLY A VISIBLE SIGNATURE HAS A PLACE IN THE TREE AT ALL. ISO
    # 14289-2, 8.9.2.4.13: "a widget annotation of zero height and width
    # shall be an artifact", which 8.10.1 is the exemption of - "unless the
    # widget annotation is an artifact" - and 8.10.3.5 says of this very
    # field: "A signature field's widget annotation shall be considered an
    # artifact if it meets the criteria defined in 8.9.2.2". NOTE 1 of
    # 8.9.2.4.13 gives the reason and the workflow it comes from: the widgets
    # of document timestamps are invisible, unpredictable in number, and
    # "it is important that invisible widgets be exempt from any tagging
    # requirements otherwise imposed by this document".
    #
    # So the RECTANGLE decides, not the claim - measured, and it has to be
    # that way: [$doc ua -part 2] may stand before this call or after it, and
    # a tree that depended on which order the caller chose would make one of
    # the two orders write a different file. veraPDF 1.30 agrees from both
    # sides (2026-08-27): the invisible signature outside the tree is
    # conformant under ua1 AND ua2, and a Form element around it fails ua2
    # rule 8.9.2.4.13-1 ("A Widget annotation of zero height and width is not
    # marked as an Artifact"); the VISIBLE one out of the tree fails ua1
    # rules 7.18.1-3 and 7.18.4-1, which is the finding this is the answer
    # to.
    #
    # The invisible signature therefore enters neither the tree nor the field
    # table below: an artifact is not real content, and there is nothing for
    # PDF/UA to ask about it. -tooltip and -contents are written all the same
    # where the caller passed them - ISO 14289-1, 7.18.1 exempts only the
    # hidden flag, a rectangle outside the CropBox and Popup, so a
    # description is never wrong.
    set structParent {}
    if {$rect ne {}} {
      package require tclpdf::field 1.0-
      set structure [lindex \
          [my FieldStructureOpen [dict get $options field] {}] 0]
      set widgetNumber [my reservation sign.widget]
      set structParent [my FieldStructureKey $structure $widgetNumber $page]
    }

    my state sign [dict create \
        signer [dict get $options signer] \
        size $size \
        name [dict get $options name] \
        reason [dict get $options reason] \
        location [dict get $options location] \
        contact [dict get $options contact] \
        date [dict get $options date] \
        field [dict get $options field] \
        page $page \
        rect $rect \
        appearance $appearance \
        tooltip [dict get $options tooltip] \
        contents [dict get $options contents] \
        structParent $structParent \
        subFilter $subFilter \
        signed 0 byteRange {} length {}]

    # AND INTO THE FIELD TABLE, because a visible signature IS a form field
    # of this document: it stands in the same /Fields array under the same
    # rules of 12.7.4.2, and PDF/UA asks its widget the same three questions
    # it asks every other one - an accessible name (/TU, 7.18.1 with ISO
    # 32000-2, 14.9.3), a description of the widget itself under part 2
    # (8.10.2.3), and a place in the structure tree (7.18.4). One list and
    # one asker, rather than a second state for ua.tcl to remember to ask:
    # the record here is what [fieldsWithoutDescription],
    # [fieldWidgetsWithoutDescription] and [fieldsOutsideStructure] read, and
    # [UaCheckFields] judges the signature by the same sentences it judges a
    # text field by. A signature declared before [$doc tagged 1] is reported
    # by the third of them, exactly as a text field declared there is.
    #
    # It is a record WITHOUT a build method, which is what tells field.tcl
    # that the object is not its to write: field and widget are merged into
    # one object here (12.5.6.19), by [SignWrite] on the same beforeWrite
    # event, and [FieldWrite] passes the record over.
    #
    # The name check above ([state fields] read for a clash) and this entry
    # are the two halves of one rule, and they make it symmetric: whichever
    # of [$doc field ...] and [$doc sign] comes second is the one refused.
    if {$rect ne {}} {
      set fields [my state fields]
      dict set fields [dict get $options field] [dict create \
          name [dict get $options field] \
          type Sig \
          page $page \
          rect $rect \
          widget $widgetNumber \
          structParent $structParent \
          tooltip [dict get $options tooltip] \
          contents [dict get $options contents] \
          label {} flags 0 data {}]
      my state fields $fields
    }

    # The channel way is refused BEFORE the bytes go anywhere: the core asks
    # [state needsFile] and reports the reason it finds there. Saying it in
    # [SignAfterWrite] alone would be a sentence spoken over a socket that
    # already carries a document with an empty placeholder in it.
    my state needsFile "tclpdf: a signed document cannot be written to a\
        channel - /ByteRange and the signature are written INTO the finished\
        file, and a channel cannot be read back. Write it with \[\$doc write\
        \$path\]; the two-stage way then hands the file on"

    my onSelf beforeWrite SignWrite
    # afterWrite carries the path, and [onSelf] passes no arguments on - its
    # lambda takes the method name and the document and nothing else. So the
    # subscription is made by hand, in the same shape and for the same
    # reason: a command prefix is called from the global context, where a
    # method whose name starts with a capital is out of reach unless it is
    # exported.
    oo::objdefine [self] export SignAfterWrite
    my on afterWrite [list apply {{name document path} {
      $document $name $path
    }} SignAfterWrite]

    return [my SignState]
  }

  # What was declared, and what the last write made of it. The signer is not
  # in it: it is a command prefix that may carry a passphrase or a key file,
  # and answering with it would put it into every log that prints what a
  # document claims.
  method SignState {} {
    set current [my state sign]
    if {$current eq {}} {
      return {}
    }
    return [dict filter $current key date field page rect appearance size \
        tooltip contents subFilter signed byteRange length]
  }

  # The objects, built on beforeWrite: the signature dictionary with both
  # placeholders in it, the signature field as a single widget annotation,
  # and the /AcroForm entry that lists the field.
  #
  # Runs on every write and is idempotent - the two object numbers come from
  # [reservation] and are written over, the annotation is registered once,
  # and the catalog entry is set to what it already said.
  method SignWrite {} {
    set current [my state sign]
    set page [dict get $current page]
    if {$page >= [my page count]} {
      return -code error -errorcode [list TCLPDF SIGN ARGUMENT page] \
          "tclpdf: sign -page $page names a page this document\
          does not have - it has [my page count] page(s). The signature\
          widget sits on a page, and that page has to exist when the file is\
          written"
    }
    set sigNumber [my reservation sign.dictionary]
    set widgetNumber [my reservation sign.widget]

    # The signature dictionary (Table 255), built by the one builder both
    # writers use - see [::tclpdf::sign::Dictionary] for what stands in it
    # and in which order.
    #
    # /M, the time of signing, and it is written ALWAYS - the one thing the
    # two ways of signing may not differ in.
    #
    # Table 255 recommends the opposite ("should be used only when the time
    # of signing is not available in the signature", and a CMS object carries
    # a signingTime attribute), and ETSI EN 319 142-1, Table 1 requires it
    # ("shall be present") while forbidding the CMS attribute. A shall beats
    # a should, and the measurements agree with the shall: all five compared
    # signers - pyHanko, EU DSS, iText, LibreOffice, PDFBox - write /M
    # without exception, and Acrobat, Foxit and BFO read the time from /M
    # alone. A file of ours without it was the one of seven specimens in a
    # reader that reported the signing time as unavailable.
    #
    # Where the time is not yet known - no -signer, so the signing happens
    # elsewhere and later - what goes in is the placeholder, and
    # [::tclpdf::sign digest] writes the real time over it at the moment it
    # hands the bytes out. That keeps the entry honest in the way a date
    # written here would not be: it states the moment of signing, not the
    # moment of preparing, and it is inside the bytes the signature covers
    # either way.
    #
    # An explicit date is the caller's own statement and is written as it
    # stands, and -date {} keeps the entry out for whoever reads Table 255 to
    # the letter.
    #
    # The file version decides how the zone offset is spelled, as it does
    # for /CreationDate: 2.0 dropped the apostrophe after the minutes.
    set date [::tclpdf::sign::Moment [dict get $current date] \
        [dict get $current signer] [[my writer] version]]
    [my writer] put $sigNumber [::tclpdf::sign::Dictionary \
        [dict merge $current [dict create date $date]]]

    # The rectangle of a visible field and the form XObject shown in it are
    # worked out here rather than at the sign call, for the reason -page is -
    # the page and the form may both come after it, and the write is where
    # everything exists at once.
    set rect {}
    set appearance {}
    if {[dict get $current rect] ne {}} {
      set rect [my SignRectangle $page [dict get $current rect]]
      set appearance [my SignAppearance [dict get $current appearance]]
    }
    # The three keys PDF/UA asks of the widget, decided at the [sign] call
    # and written here: /TU, /Contents and the /StructParent that joins the
    # annotation to the Form structure element opened around it. Nothing is
    # worked out at this point - the element and the key were made where the
    # caller stood, which is the only place that knows the reading order.
    [my writer] put $widgetNumber [::tclpdf::sign::Widget \
        [dict get $current field] [[my writer] ref $sigNumber] \
        [[my writer] ref [dict get [my Page $page] number]] \
        $rect $appearance [dict filter $current key \
            tooltip contents structParent]]

    # Into the page's /Annots, the same scratch state link.tcl uses - once,
    # however often the document is written.
    set reference [[my writer] ref $widgetNumber]
    my AnnotationOnPage $page $reference

    # /SigFlags 3 is SignaturesExist and AppendOnly (Table 225): the document
    # has a signature field, and it may only be written on incrementally.
    # Optional by Table 224 and set in the standard's own example.
    #
    # Handed to the FIELD core rather than written here. /AcroForm is one
    # catalogue key and a document may hold a signature AND text fields, so
    # it has one writer - field.tcl, which collects whatever was enlisted and
    # writes the single entry on the catalog event. This module contributes
    # its widget and its flags and nothing else; what a document with only a
    # signature in it comes out as is unchanged, and tests/sign.test measures
    # exactly that.
    my FieldEnlist $reference -sigflags 3
    return
  }

  # Where a visible field sits, as the four numbers /Rect takes.
  #
  # The arithmetic itself is [FieldRectangle] in field.tcl, shared with every
  # other form field: a signature widget and a text field ask the same
  # question of the same page - where does {x y w h} counted from the top
  # left corner land, and does it land on the page at all - and two copies of
  # that answer are two answers waiting to differ. What stays here is the
  # WORDING, because a caller who wrote "sign -rect" has to read "sign -rect"
  # back.
  method SignRectangle {page rect} {
    return [my FieldRectangle $page $rect "sign -rect"]
  }

  # The reference to the form XObject a visible field shows.
  #
  # An appearance stream IS a form XObject with a bounding box (12.5.5,
  # Table 168), which is what "form create" writes and what this method does
  # nothing else with than hand on: the caller drew it, and none of the
  # decisions in it are made here.
  #
  # Looked up at write time, as -page is, so that the sign call keeps its
  # promise of standing anywhere before the write - a form created after it
  # counts as much as one created before.
  method SignAppearance {name} {
    set forms [my state forms]
    if {![dict exists $forms $name]} {
      set known [dict keys $forms]
      if {![llength $known]} {
        set known "none - this document has no form at all"
      } else {
        set known [join $known {, }]
      }
      return -code error -errorcode [list TCLPDF SIGN ARGUMENT appearance] \
          "tclpdf: sign -appearance names no form of this\
          document: \"$name\" - known are: $known. What a visible signature\
          field shows is a form XObject the caller draws beforehand with\
          \"form create\", under the name passed here"
    }
    return [my resource XObject [dict get $forms $name resource]]
  }

  # The file exists: fill in /ByteRange, and the signature itself when a
  # signer was named. Both edits are length-neutral, and both are checked to
  # be - see the head of this file.
  method SignAfterWrite {path} {
    set current [my state sign]
    if {$path eq {}} {
      # [writeChannel] fires this event with an empty path, and there is
      # nothing to reopen: the bytes are gone down a socket or a pipe, and
      # /ByteRange cannot be computed before the file is complete. Said
      # here because it is the first moment the two ways are told apart -
      # up to it, both build the same document.
      return -code error -errorcode [list TCLPDF SIGN STATE channel] \
          "tclpdf: a signed document cannot be written to a\
          channel - /ByteRange and the signature are written INTO the\
          finished file, and a channel cannot be read back. Write it with\
          \[\$doc write \$path\]; the two-stage way then hands the file on"
    }
    set data [::tclpdf::io read $path]
    set length [string length $data]
    set located [::tclpdf::sign::Locate $data "the document just written"]
    set byteRange [::tclpdf::sign::Range $data $located]
    set data [::tclpdf::sign::WriteRange $data $located $byteRange]
    if {[string length $data] != $length} {
      return -code error -errorcode [list TCLPDF SIGN INTERNAL length] \
          "tclpdf: writing /ByteRange changed the file length,\
          which cannot be - it describes its own file"
    }

    set signed 0
    set derLength {}
    if {[dict get $current signer] ne {}} {
      # THE FILE IS WRITTEN EITHER WAY, and that is what a failing signer
      # cost until 2026-08-22. The bytes are patched in memory and go out at
      # the end, so an error anywhere in the signing step used to leave the
      # file as [write] had put it there - with the /ByteRange placeholder
      # still in it, which [Prepared] refuses by name: the document could
      # then be neither signed here nor handed to the two-stage way, and
      # [add] promises the opposite for the same failure ("leaves the file
      # exactly as it found it").
      #
      # What is on disk after a failure now is the PREPARED document - the
      # /ByteRange filled in, the reserved room still zeros - which is
      # exactly the file a write without -signer produces. So the signer can
      # be tried again through [::tclpdf::sign digest] and [embed] without
      # writing the document a second time, and the error itself is passed
      # on untouched, options and all: a caller reacting to
      # "-errorcode {TCLPDF SIGN SPACE ...}" still gets it.
      if {[catch {::tclpdf::sign::Signed $data $located $byteRange $length \
          [dict get $current signer] "the document just written"} \
          result options]} {
        ::tclpdf::io write $path $data
        my state sign [dict merge $current [dict create signed 0 \
            byteRange $byteRange length {}]]
        return -options $options $result
      }
      lassign $result data derLength
      set signed 1
    }
    ::tclpdf::io write $path $data
    my state sign [dict merge $current [dict create signed $signed \
        byteRange $byteRange length $derLength]]
    return
  }
}

package provide tclpdf::sign 1.6