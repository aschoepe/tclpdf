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
# baseline level, while "openssl cms -sign" and BouncyCastle add it unasked.
# A DER carrying the attribute is refused under /ETSI.CAdES.detached - see
# [NoSigningTime], which is the one place this module looks into the bytes it
# is handed, and looks exactly two OIDs far: the attribute, and the RFC 3161
# timestamp token whose own signing time a B-T signature legitimately carries.
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
proc ::tclpdf::sign::Locate {data what} {
  # Every /ByteRange in the file, and the LAST of them is the one meant.
  #
  # Until 2026-08-21 a second one was refused here, because a file this
  # module had written carried exactly one and a second meant a signature
  # from elsewhere that guessing would have got wrong. [::tclpdf::sign add]
  # is what changed that: it appends a further signature as an incremental
  # update, so a file with two of them is now one of ours, and [digest] and
  # [embed] have to reach the one that is still waiting for its value.
  #
  # WHY THE LAST ONE IS THE RIGHT ONE, and it is a property of 7.5.6 rather
  # than a habit: an incremental update appends. Every object it writes lies
  # behind every byte the file had before, so the newest signature dictionary
  # is always the one furthest into the file - and the older ones are
  # finished, since [add] refuses to append onto a signature whose value is
  # still the reserved zeros. What this does NOT do is search for a
  # dictionary that is unfilled: a caller who prepares two signatures and
  # then fills the first would be signing bytes that the second still
  # changes, and there is no order in which that works.
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
    return -code error "tclpdf: $what carries no signature - there is no\
        /ByteRange in it. A document is prepared for signing by\
        \[\$doc sign\] before it is written, and a finished file gains a\
        further signature through \[::tclpdf::sign add\]"
  }
  set at [lindex $positions end]

  set open [string first \[ $data $at]
  set close [string first \] $data $open]
  if {$open < 0 || $close < 0 || $close <= $open} {
    return -code error "tclpdf: the /ByteRange of $what is not an array -\
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
    return -code error "tclpdf: the /ByteRange of $what holds\
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
    return -code error "tclpdf: the signature dictionary of $what has no\
        /SubFilter in front of its /ByteRange - the file is not one tclpdf\
        wrote"
  }

  variable contentsDistance
  set key [string first /Contents $data $close]
  if {$key < 0 || $key - $close > $contentsDistance} {
    return -code error "tclpdf: the signature dictionary of $what has no\
        /Contents next to its /ByteRange - the file is not one tclpdf wrote"
  }
  set from [string first < $data $key]
  set to [string first > $data $from]
  if {$from < 0 || $to < 0 || $to <= $from} {
    return -code error "tclpdf: the /Contents of $what is not a hexadecimal\
        string - 12.8.3.3.1 requires one, with '<' and '>' delimiters"
  }
  set hexLength [expr {$to - $from - 1}]
  if {$hexLength == 0 || $hexLength % 2} {
    return -code error "tclpdf: the /Contents of $what holds $hexLength\
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
    return -code error "tclpdf: the /ByteRange \[$byteRange\] does not fit\
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
    return -code error "tclpdf: the /M of $what is not a literal string -\
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
    return -code error "tclpdf: the signing time \"$date\" is\
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
      the time of signing belongs in /M, which tclpdf writes. \"openssl cms\
      -sign\" and BouncyCastle add the attribute unasked and offer no switch\
      to leave it out, so neither can produce a PAdES signature. Write the\
      document with \"sign -subfilter pkcs7\", which claims no PAdES, or have\
      it signed by something that leaves the attribute out - pyHanko and the\
      EU DSS library do"
}

# A file whose /ByteRange is still the placeholder was never written through
# [$doc write], and signing it would mean signing the four zeros as well.
proc ::tclpdf::sign::Prepared {located what} {
  if {[lindex [dict get $located byteRange] 1] == 0} {
    return -code error "tclpdf: the /ByteRange of $what is still the\
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
    return -code error "tclpdf: the /ByteRange of $what does not describe\
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
proc ::tclpdf::sign::Der {der} {
  if {[regexp {[^\u0000-\u00ff]} $der]} {
    return -code error "tclpdf: the signature is text, not bytes - it has to\
        be a CMS SignedData object in DER, and a character above 0xff cannot\
        be a byte of one"
  }
  return
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
proc ::tclpdf::sign::Widget {field value page rect appearance} {
  set annotation [list \
      Type /Annot \
      Subtype /Widget \
      FT /Sig \
      T [::tclpdf::pdfObj str $field] \
      V $value]
  if {$rect eq {}} {
    lappend annotation Rect [::tclpdf::pdfObj arr {0 0 0 0}]
  } else {
    lappend annotation Rect $rect \
        AP [::tclpdf::pdfObj dictionary [list N $appearance]]
  }
  lappend annotation F 4 P $page
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
    return $date
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
    return -code error "tclpdf: sign digest -date takes a PDF date such as\
        D:20260818120000+02'00' (ISO 32000-1, 7.9.4) or \"now\", which is the\
        default and means the moment the bytes are handed out - not \"$date\""
  }
  set data [::tclpdf::io read $path]
  set what "\"$path\""
  set located [Locate $data $what]
  Prepared $located $what
  set byteRange [Describes $data $located $what]

  # A file whose /M is not the placeholder is left as it is: the document was
  # written with a -date naming a time of its own, or with -date {} and no
  # entry at all, and both are the caller's own statement about the time -
  # not something to be overwritten by a second call that knows less.
  set range [LocateDate $data $located $what]
  if {[llength $range]} {
    if {$date eq "now"} {
      set date [::tclpdf::pdfObj date {} [HeaderVersion $data]]
    }
    set length [string length $data]
    set data [WriteDate $data $range $date $what]
    if {[string length $data] != $length} {
      return -code error "tclpdf: writing the signing time into $what changed\
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
    return -code error "tclpdf: writing the signature into $what changed the\
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
  return -code error "tclpdf: $what -subfilter is the signature profile and\
      takes \"pkcs7\" for /adbe.pkcs7.detached (PDF 1.6, and the default) or\
      \"cades\" for /ETSI.CAdES.detached (PDF 2.0, and the claim to be a\
      PAdES signature - ETSI EN 319 142-1), not \"$value\""
}

# How much room is reserved for the signature value.
proc ::tclpdf::sign::Size {value what} {
  if {![string is integer -strict $value] || $value < 1} {
    return -code error "tclpdf: $what -size is the number of bytes reserved\
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
    return -code error "tclpdf: $what -page is a page index counted from 0,\
        as \"page current\" counts, not \"$value\""
  }
  return $value
}

# The command prefix that answers the CMS object. Only its SHAPE is checked
# here - whether it is callable at all is answered when it is called, and by
# then there is a file to point at.
proc ::tclpdf::sign::Signer {value what} {
  if {[catch {llength $value}]} {
    return -code error "tclpdf: $what -signer is a command prefix, called as\
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
  if {$date ni {{} now} && [::tclpdf::document::parseDate $date] eq {}} {
    return -code error "tclpdf: sign add -date takes a PDF date such as\
        D:20260818120000+02'00' (ISO 32000-1, 7.9.4), \"now\" - which is the\
        default and means the moment of signing - or the empty string for no\
        /M at all, not \"$date\""
  }

  set data [::tclpdf::io read $path]
  set what "\"$path\""

  # The version floor of the /SubFilter, read off the file's own header
  # because that is where the version of a file stands and an update cannot
  # move it.
  set version [HeaderVersion $data]
  set floor [expr {$subFilter eq "/ETSI.CAdES.detached" ? "2.0" : "1.6"}]
  if {[package vcompare $version $floor] < 0} {
    return -code error "tclpdf: $what states version $version in its header\
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
  # every DER object begins with 0x30.
  if {[regexp {/Contents[[:space:]]*<0+>} $data]} {
    return -code error "tclpdf: a signature of $what is still waiting for its\
        value - its /Contents holds nothing but the reserved zeros. Put the\
        CMS object in with \[::tclpdf::sign embed\] first: appending a further\
        signature now would cover those zeros, and the object that belongs\
        there could never be written without breaking it"
  }

  set upd [::tclpdf::update open $path]
  try {
    if {[$upd base] != [string length $data]} {
      return -code error "tclpdf: $what changed while it was being signed -\
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
    set taken [FieldNames $upd $catalogValue]
    set field [dict get $options field]
    if {$field eq {}} {
      set number 1
      while {"Signature$number" in $taken} {
        incr number
      }
      set field "Signature$number"
    } elseif {$field in $taken} {
      return -code error "tclpdf: $what already carries a signature field\
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
    return -code error "tclpdf: writing /ByteRange into $what changed the file\
        length, which cannot be - it describes its own file"
  }

  set signed 0
  set derLength {}
  if {$signer ne {}} {
    set der [uplevel #0 [list {*}$signer [Bytes $data $byteRange]]]
    if {$der eq {}} {
      return -code error "tclpdf: the -signer prefix answered nothing - it\
          has to answer a CMS SignedData object in DER, which is what\
          \"openssl cms -sign -outform DER\" writes"
    }
    Der $der
    NoSigningTime $der $subFilter $what
    set data [Fill $data $located $der]
    if {[string length $data] != $length} {
      return -code error "tclpdf: writing the signature into $what changed the\
          file length, which cannot be - the /ByteRange describes its own file"
    }
    set signed 1
    set derLength [string length $der]
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
  return [::tclpdf::import::Parse $body position]
}

proc ::tclpdf::sign::Syntax {value} {
  set map {}
  foreach number [::tclpdf::import::Refs $value] {
    dict set map $number $number
  }
  return [::tclpdf::import::Serialize $value $map]
}

# The object number a reference names, from PDF syntax or from a parsed value.
proc ::tclpdf::sign::Number {reference what which} {
  if {[lindex $reference 0] eq "r"} {
    return [lindex [lindex $reference 1] 0]
  }
  if {[regexp {^\s*([0-9]+)\s+[0-9]+\s+R\s*$} $reference -> number]} {
    return $number
  }
  return -code error "tclpdf: $which of $what is \"$reference\" and an\
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
  set node [Number [::tclpdf::import::Get $catalogValue Pages] $what \
      "the /Pages entry of the catalog"]
  set remaining [expr {$index + 1}]
  set total 0
  while {1} {
    set value [Value [$upd body $node]]
    if {[lindex [::tclpdf::import::Get $value Type] 1] eq "Page"} {
      return $node
    }
    if {!$total} {
      set total [lindex [Direct $upd \
          [::tclpdf::import::Get $value Count]] 1]
    }
    set kids [Direct $upd [::tclpdf::import::Get $value Kids]]
    set descended 0
    foreach kid [lindex $kids 1] {
      set number [Number $kid $what "a /Kids entry of the page tree"]
      set child [Value [$upd body $number]]
      if {[lindex [::tclpdf::import::Get $child Type] 1] eq "Pages"} {
        set count [lindex [Direct $upd \
            [::tclpdf::import::Get $child Count]] 1]
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
      return -code error "tclpdf: sign add -page $index names a page $what\
          does not have - it has $total page[expr {$total == 1 ? {} : {s}}].\
          The signature widget sits on a page, and that page has to exist"
    }
  }
}

# The /AcroForm of the file, as {value number}: the parsed dictionary and, for
# one that stands in the catalog as a reference, the object it lives in - the
# empty string where it is written into the catalog itself or is not there at
# all. Both spellings occur; tclpdf writes the direct one, and the file that
# was measured for this used the other.
proc ::tclpdf::sign::AcroForm {upd catalogValue} {
  set entry [::tclpdf::import::Get $catalogValue AcroForm]
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
  set fields [Direct $upd [::tclpdf::import::Get $form Fields]]
  set names {}
  foreach entry [lindex $fields 1] {
    set value [Direct $upd $entry]
    set name [::tclpdf::import::Get $value T]
    if {[lindex $name 0] eq "s"} {
      lappend names [lindex $name 1]
    }
  }
  return $names
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
  set entry [::tclpdf::import::Get $form Fields]
  set fields [Direct $upd $entry]
  if {$fields eq {}} {
    set fields [list a {}]
  }
  set items [lindex $fields 1]
  lappend items [list r [list $widget 0]]
  if {[lindex $entry 0] eq "r"} {
    $upd replace [lindex [lindex $entry 1] 0] [Syntax [list a $items]]
  } else {
    ::tclpdf::import::Put form Fields [list a $items]
  }
  ::tclpdf::import::Put form SigFlags [list n 3]
  if {$number ne {}} {
    $upd replace $number [Syntax $form]
    return
  }
  ::tclpdf::import::Put catalogValue AcroForm $form
  $upd replace $catalog [Syntax $catalogValue]
  return
}

# The widget into the page's /Annots, in the second copy of the page object -
# or, where the array is an object of its own, in the second copy of that.
proc ::tclpdf::sign::Annotate {upd number widget} {
  set value [Value [$upd body $number]]
  set entry [::tclpdf::import::Get $value Annots]
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
  ::tclpdf::import::Put value Annots [list a $items]
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
  # $doc sign state             what was declared, and what came of it
  method sign {args} {
    if {[llength $args] && [string index [lindex $args 0] 0] ne "-"} {
      switch -- [lindex $args 0] {
        state {return [my SignState]}
        default {
          return -code error "tclpdf: unknown sign subcommand\
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
    } $args "sign"]

    # Which /SubFilter, how much room, which page and what the signer is:
    # the four checks [::tclpdf::sign add] makes word for word, and they are
    # made in one place - see [SubFilter] for what the value decides.
    set subFilter [::tclpdf::sign::SubFilter \
        [dict get $options subfilter] sign]
    set size [::tclpdf::sign::Size [dict get $options size] sign]
    if {[dict get $options field] eq {}} {
      return -code error "tclpdf: sign -field is the name of the signature\
          field and cannot be empty - a field dictionary without a partial\
          field name is not a field at all, only a widget annotation (ISO\
          32000-2, 12.7.4.2)"
    }
    # "now" is the default and says what it means - the moment of signing,
    # which for a -signer is the write and for the two-stage way is the
    # moment [::tclpdf::sign digest] hands the bytes out. The empty string
    # keeps /M out of the dictionary altogether. Anything else is a PDF date,
    # and is checked by the one check the package has for those.
    if {[dict get $options date] ni {{} now}} {
      my CheckDate [dict get $options date] "sign -date"
    }
    set page [::tclpdf::sign::PageIndex [dict get $options page] sign]
    # The two halves of a visible field. Each is useless without the other,
    # and each without the other is a mistake that shows up nowhere until a
    # validator or a reader is asked - so it is named here. See the head of
    # this file for why the drawing itself is the caller's.
    set rect [dict get $options rect]
    set appearance [dict get $options appearance]
    if {$rect ne {} && $appearance eq {}} {
      return -code error "tclpdf: sign -rect makes the signature field\
          VISIBLE, and a visible field needs something to show - pass\
          -appearance with the name of a form XObject drawn beforehand with\
          \"form create\". Without one the field is an annotation with no\
          appearance dictionary, which veraPDF rule 6.3.3-1 fails and which\
          a reader draws as nothing. Leave -rect out for the invisible\
          signature of ISO 32000-2, 12.8.5.3"
    }
    if {$appearance ne {} && $rect eq {}} {
      return -code error "tclpdf: sign -appearance is what a VISIBLE\
          signature field shows, and without -rect {x y w h} the field has\
          no area on the page - an appearance stream is painted into the\
          rectangle of its annotation (ISO 32000-2, 12.5.5), and a rectangle\
          of no area is painted nowhere. Pass -rect as well, or leave\
          -appearance out"
    }
    if {$rect ne {}} {
      if {[llength $rect] != 4} {
        return -code error "tclpdf: sign -rect is {x y w h} - the top left\
            corner of the signature field and its size, in the unit of the\
            document, as \"link -at\" and \"rect -at\" count - not \"$rect\""
      }
      foreach value $rect {
        if {![string is double -strict $value]} {
          return -code error "tclpdf: sign -rect is {x y w h} in numbers,\
              not \"$rect\""
        }
      }
      lassign $rect left top width height
      if {$width <= 0 || $height <= 0} {
        return -code error "tclpdf: sign -rect {$rect} has a width of $width\
            and a height of $height - a visible signature field needs both\
            above zero, or there is no area for its appearance to be painted\
            into"
      }
    }
    ::tclpdf::sign::Signer [dict get $options signer] sign

    if {[my state sign] ne {}} {
      return -code error "tclpdf: this document is already being signed -\
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
      return -code error "tclpdf: this document is encrypted, and tclpdf\
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
        subFilter $subFilter \
        signed 0 byteRange {} length {}]

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
        subFilter signed byteRange length]
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
      return -code error "tclpdf: sign -page $page names a page this document\
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
    [my writer] put $widgetNumber [::tclpdf::sign::Widget \
        [dict get $current field] [[my writer] ref $sigNumber] \
        [[my writer] ref [dict get [my Page $page] number]] \
        $rect $appearance]

    # Into the page's /Annots, the same scratch state link.tcl uses - once,
    # however often the document is written.
    set annots [my state annots]
    set reference [[my writer] ref $widgetNumber]
    if {![dict exists $annots $page]
        || $reference ni [dict get $annots $page]} {
      dict lappend annots $page $reference
      my state annots $annots
    }

    # /SigFlags 3 is SignaturesExist and AppendOnly (Table 225): the document
    # has a signature field, and it may only be written on incrementally.
    # Optional by Table 224 and set in the standard's own example.
    my catalogEntry AcroForm [::tclpdf::pdfObj dictionary [list \
        Fields [::tclpdf::pdfObj arr [list $reference]] \
        SigFlags 3]]
    return
  }

  # Where a visible field sits, as the four numbers /Rect takes.
  #
  # THE ONE THING THIS METHOD IS FOR IS THE ORIGIN. A caller counts y from
  # the top of the page and a PDF counts it from the bottom, so the two
  # corners go through [coords] - the single place in this package where the
  # unit and the origin are converted, and the one link.tcl sends an
  # annotation's rectangle through for exactly this reason. -rect names the
  # TOP left corner and a size, as "link -at" with "link -size" does, so the
  # lower left corner of the PDF rectangle is the one at y + height.
  #
  # The page is passed rather than left to default: [coords] without an index
  # takes the CURRENT page, which at write time is the last one added, while
  # the signature widget sits on the page -page names.
  method SignRectangle {page rect} {
    lassign $rect left top width height
    lassign [my coords $left [expr {$top + $height}] $page] x0 y0
    lassign [my coords [expr {$left + $width}] $top $page] x1 y1
    # A rectangle STICKING OUT is allowed - nothing else in this package
    # takes the page edge for a boundary, a MediaBox need not start at zero,
    # and a field at the very edge is the caller's business. One entirely
    # BESIDE the page is refused, and it is the same refusal as -appearance
    # without -rect: an appearance nothing ever paints. This is the case
    # where the two most likely mistakes show up - a y counted from the
    # bottom, or a -rect in millimetres on a document set to points.
    lassign [dict get [my Page $page] boxes media] mediaX0 mediaY0 \
        mediaX1 mediaY1
    if {$x1 <= $mediaX0 || $x0 >= $mediaX1
        || $y1 <= $mediaY0 || $y0 >= $mediaY1} {
      # Both rectangles in the message, and both in points: the numbers the
      # caller wrote are in the message as well, so the comparison that
      # explains the mistake is there to be made.
      set where [join [lmap number [list $x0 $y0 $x1 $y1] {
        ::tclpdf::pdfObj num $number
      }]]
      set box [join [lmap number [list $mediaX0 $mediaY0 $mediaX1 $mediaY1] {
        ::tclpdf::pdfObj num $number
      }]]
      return -code error "tclpdf: sign -rect {$rect} puts the signature\
          field at $where in points, which is entirely outside page $page -\
          its media box is $box. A visible field has to have area on the\
          page it names: -rect counts {x y w h} from the TOP left corner of\
          the page, in the unit of the document"
    }
    return [::tclpdf::pdfObj arr [list \
        [::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] \
        [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1]]]
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
      return -code error "tclpdf: sign -appearance names no form of this\
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
      return -code error "tclpdf: a signed document cannot be written to a\
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
      return -code error "tclpdf: writing /ByteRange changed the file length,\
          which cannot be - it describes its own file"
    }

    set signed 0
    set derLength {}
    if {[dict get $current signer] ne {}} {
      set der [uplevel #0 [list {*}[dict get $current signer] \
          [::tclpdf::sign::Bytes $data $byteRange]]]
      if {$der eq {}} {
        return -code error "tclpdf: the -signer prefix answered nothing - it\
            has to answer a CMS SignedData object in DER, which is what\
            \"openssl cms -sign -outform DER\" writes"
      }
      # A signer that answers text rather than bytes would be hexadecimal
      # nonsense in the file, and nothing before a verifier would say so.
      ::tclpdf::sign::Der $der
      # And a signer that states the time of signing in the CMS object takes
      # a PAdES claim away from the document it was made for. Said here
      # rather than left to a validator: the file on disk still holds its
      # placeholder, so the way out is one option away.
      ::tclpdf::sign::NoSigningTime $der [dict get $current subFilter] \
          "the document just written"
      set data [::tclpdf::sign::Fill $data $located $der]
      if {[string length $data] != $length} {
        return -code error "tclpdf: writing the signature changed the file\
            length, which cannot be - /ByteRange describes its own file"
      }
      set signed 1
      set derLength [string length $der]
    }
    ::tclpdf::io write $path $data
    my state sign [dict merge $current [dict create signed $signed \
        byteRange $byteRange length $derLength]]
    return
  }
}

package provide tclpdf::sign 1.0
