#
# tclpdf - PDF generation for Tcl
#
# importInfo - what a finished PDF says about itself
#
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
##
# The inventory side of the reader in importRead.tcl: page count and page
# boxes, the document information dictionary, encryption, revisions, the XMP
# claim, output intents, attachments, signatures and the faces a file uses.
# Nothing here is read that [pdf import] does not read anyway - the point of
# the topic is that it answers without taking anything over.
#
package require Tcl 8.6.11-
package require tclpdf::importRead 1.0-
package require tclpdf::option 1.0-
package require tclpdf::pdfObj 1.0-

namespace eval ::tclpdf::pdf {
  # The reader's procedures are called by their plain names here, as they were
  # when both halves lived in one file. [namespace path] keeps that so: it is
  # a one-way link into the infrastructure this topic stands on, not an import
  # that would make the names look like this namespace's own.
  namespace path {::tclpdf::importRead}

  namespace export {[a-z]*}
  namespace ensemble create
}

# The five entries. They are one-liners on purpose, and NOTHING written in
# this namespace may call [info] unqualified from now on: a procedure of that
# name lives here and would answer instead. The work is in ::tclpdf::import,
# where the reader is.

proc ::tclpdf::pdf::info {path} {
  return [::tclpdf::pdf::Inventory $path]
}

proc ::tclpdf::pdf::pages {path} {
  set reader [::tclpdf::pdf::Reader $path]
  return [::tclpdf::pdf::PageInventory reader]
}

proc ::tclpdf::pdf::fonts {path} {
  set reader [::tclpdf::pdf::Reader $path]
  return [::tclpdf::pdf::FontInventory reader]
}

proc ::tclpdf::pdf::metadata {path} {
  set reader [::tclpdf::pdf::Reader $path]
  return [::tclpdf::pdf::Metadata reader]
}

# The one entry that is not a one-liner, because it is the one that takes an
# option. -xfa 1 asks for the /AcroForm shadow copy of an XFA form, which is
# refused without it - see the head of "the fields" below.
proc ::tclpdf::pdf::fields {path args} {
  set options [::tclpdf::option parse {xfa 0} $args "pdf fields"]
  set xfa [dict get $options xfa]
  if {![string is boolean -strict $xfa]} {
    return -code error -errorcode {TCLPDF IMPORT OPTION} "tclpdf: -xfa of\
        \"pdf fields\" is a boolean, got \"$xfa\""
  }
  # No "tolerate encrypted" here, on purpose: [pdf info] can report what an
  # encrypted file says out of its trailer, and a field cannot say anything
  # out of one - its name and its value are strings.
  set reader [::tclpdf::pdf::Reader $path]
  return [::tclpdf::pdf::FieldInventory reader $xfa]
}

# The file, looked at before it is opened. These four commands are pointed at
# a path someone typed, and a missing one has to be refused the way this
# package refuses everything - naming itself and the path - rather than
# arriving as Tcl's bare "couldn't open". [pdf import] makes the same check
# before it opens anything, for the same reason.
proc ::tclpdf::pdf::Reader {path {tolerateEncrypted 0}} {
  if {![file exists $path]} {
    return -code error -errorcode {TCLPDF IMPORT FILE} \
        "tclpdf: no file \"$path\""
  }
  return [Open $path $tolerateEncrypted]
}

# -------------------------------------------------------------- the document

proc ::tclpdf::pdf::Inventory {path} {
  set reader [Reader $path 1]
  set bytes [dict get $reader bytes]

  # Every key is always there, with an empty value where the file has nothing
  # to say - a caller that first has to test whether a key exists writes the
  # same three lines around every field it reads.
  set facts [dict create path $path bytes [string length $bytes] \
      version [Header $bytes] catalogVersion {} \
      xref [dict get $reader flavour] \
      sections [llength [dict get $reader sections]] \
      revisions [Revisions [dict get $reader sections]] \
      id [Identifier reader] encrypted 0 encryption {} \
      pages {} size {} info {} xmp 0 pdfa {} pdfua {} tagged 0 form none \
      outputIntents {} attachments {} signatures {}]

  if {[Get [dict get $reader trailer] Encrypt] ne {}} {
    dict set facts encrypted 1
    dict set facts encryption [Encryption reader]
    return $facts
  }

  set root [Catalog reader]
  # A catalog /Version overrides the header from PDF 1.4 on (7.5.5), and only
  # upwards. Both are reported rather than one merged number: which of them a
  # reader honours differs, and a file whose two disagree is worth seeing.
  dict set facts catalogVersion [Plain reader [Get $root Version]]
  dict set facts pages [PageCount reader]
  if {[dict get $facts pages] ne {} && [dict get $facts pages] > 0} {
    set geometry [Geometry reader [Page reader 1] 1]
    dict set facts size [list [dict get $geometry width] \
        [dict get $geometry height]]
  }
  dict set facts info [Document reader]
  dict set facts tagged [expr {[Plain reader [Get [Resolve reader \
      [Get $root MarkInfo]] Marked]] eq "true"}]
  set acroform [Resolve reader [Get $root AcroForm]]
  if {[lindex $acroform 0] eq "d"} {
    dict set facts form [expr {[Get $acroform XFA] ne {} ? "XFA" : "AcroForm"}]
    dict set facts signatures [Signatures reader $acroform]
  }
  dict set facts outputIntents [OutputIntents reader $root]
  dict set facts attachments [Attachments reader $root]

  set packet [Metadata reader]
  if {$packet ne {}} {
    dict set facts xmp 1
    dict set facts pdfa \
        [Claim $packet pdfaid part][Claim $packet pdfaid conformance]
    dict set facts pdfua [Claim $packet pdfuaid part]
  }
  return $facts
}

# How often the file was written on, out of the offsets of its cross-reference
# chain. Not simply the number of sections, and the difference is the whole
# point of the proc: a LINEARIZED file (Annex F) carries a second section at
# the FRONT, for the first page, which chains back to the main section at the
# end - two sections that were written in one go. An incremental update
# (7.5.6) appends its section, so its offset is HIGHER than the one it chains
# to; the linearized pair is the one step in a chain that runs the other way.
# So: one revision per section, minus every ascending step.
#
# Measured on 2026-08-21 over 166 files - 106 foreign ones and the 61 this
# package writes, plus its own updated examples: on every one of them the
# ascending step is present exactly where "qpdf --check" reports "File is
# linearized", and absent everywhere else. The one file where the two readings
# part is a linearized magazine that was later updated: qpdf says it is no
# longer linearized, this counts 3 sections as 2 revisions, and both are
# right about different questions.
#
# Whether a file IS linearized in qpdf's sense is deliberately not reported -
# that needs the hint tables checked against the objects they promise, which
# is a different job from reading a cross-reference chain.
proc ::tclpdf::pdf::Revisions {sections} {
  set revisions [llength $sections]
  foreach a [lrange $sections 0 end-1] b [lrange $sections 1 end] {
    if {$a < $b} {
      incr revisions -1
    }
  }
  return $revisions
}

# The version out of the header (7.5.2), looked for in the first kilobyte
# rather than at byte 0: a file with junk in front of its header is what Annex
# H tells a reader to cope with, and the cross-reference offsets of such a
# file are the ones this reader has just followed.
proc ::tclpdf::pdf::Header {bytes} {
  if {[regexp {%PDF-(\d+\.\d+)} [string range $bytes 0 1023] -> version]} {
    return $version
  }
  return {}
}

# The file identifier (14.4) as two hexadecimal strings, the way every tool
# prints it. It stands in the TRAILER and is therefore readable even from an
# encrypted file - /ID is the one pair of strings a security handler leaves
# alone (7.6.2).
proc ::tclpdf::pdf::Identifier {readerVar} {
  upvar 1 $readerVar reader
  set id [Get [dict get $reader trailer] ID]
  if {[lindex $id 0] ne "a"} {
    return {}
  }
  set out {}
  foreach item [lindex $id 1] {
    switch -- [lindex $item 0] {
      s {lappend out [string toupper [binary encode hex [lindex $item 1]]]}
      h {lappend out [string toupper [regsub -all {[^0-9A-Fa-f]} \
          [lindex $item 1] {}]]}
    }
  }
  return $out
}

# What the /Encrypt dictionary says about itself: names and numbers, which is
# exactly what a security handler does not encrypt, and what makes this
# answerable at all. /P travels as the number it is - see the head of this
# section.
proc ::tclpdf::pdf::Encryption {readerVar} {
  upvar 1 $readerVar reader
  set encrypt [Resolve reader [Get [dict get $reader trailer] Encrypt]]
  set facts {}
  foreach key {Filter SubFilter V R Length P} {
    lappend facts [string tolower $key] [Plain reader [Get $encrypt $key]]
  }
  # WHICH algorithm the standard handler uses is not in /V but in the crypt
  # filter it names (7.6.5): V2 is RC4, AESV2 is AES-128, AESV3 is AES-256.
  set standard [Resolve reader [Get [Resolve reader [Get $encrypt CF]] StdCF]]
  lappend facts method [Plain reader [Get $standard CFM]]
  return $facts
}

# The entries of the document information dictionary (14.3.3), every value
# decoded as the text string it is. Custom keys travel with the eight the
# standard names - a producer that writes /Company is answered with it.
#
# The two dates are handed on AS THEY STAND, "D:20260821101222+02'00'" and
# all. Converting to seconds would lose what the file says - the zone form,
# and the truncated shapes real producers write - and this package has
# [::tclpdf::document::parseDate] for the caller who wants the fields.
proc ::tclpdf::pdf::Document {readerVar} {
  upvar 1 $readerVar reader
  set value [Resolve reader [Get [dict get $reader trailer] Info]]
  if {[lindex $value 0] ne "d"} {
    return {}
  }
  set out {}
  foreach {key item} [lindex $value 1] {
    set item [Resolve reader $item]
    switch -- [lindex $item 0] {
      s - h {lappend out $key [Text $item]}
      default {lappend out $key [lindex $item 1]}
    }
  }
  return $out
}

proc ::tclpdf::pdf::Catalog {readerVar} {
  upvar 1 $readerVar reader
  return [Resolve reader [Get [dict get $reader trailer] Root]]
}

# The number of pages, out of the page tree root (7.7.3.2). Empty where the
# file states none: /Count is required, and a file without it is broken in a
# way this reports rather than repairs.
proc ::tclpdf::pdf::PageCount {readerVar} {
  upvar 1 $readerVar reader
  set count [Plain reader [Get [Resolve reader \
      [Get [Catalog reader] Pages]] Count]]
  if {![string is entier -strict $count]} {
    return {}
  }
  return $count
}

# The output intents of the catalog (14.11.5) - the entry that says under
# which condition the colours of this file are to be read, and the one a
# PDF/A file must carry. "profile" says whether the ICC profile itself is in
# the file, which is what makes the intent usable and PDF/A demands.
proc ::tclpdf::pdf::OutputIntents {readerVar root} {
  upvar 1 $readerVar reader
  set intents [Resolve reader [Get $root OutputIntents]]
  if {[lindex $intents 0] ne "a"} {
    return {}
  }
  set out {}
  foreach item [lindex $intents 1] {
    set intent [Resolve reader $item]
    lappend out [dict create subtype [Plain reader [Get $intent S]] \
        identifier [Text [Resolve reader \
            [Get $intent OutputConditionIdentifier]]] \
        condition [Text [Resolve reader [Get $intent OutputCondition]]] \
        registry [Text [Resolve reader [Get $intent RegistryName]]] \
        profile [expr {[Get $intent DestOutputProfile] ne {}}]]
  }
  return $out
}

# The embedded files, out of the /EmbeddedFiles name tree of the catalog
# (7.11.4). What is NOT looked at is the older way of attaching a file, a
# FileAttachment annotation on a page (12.5.6.15): that is a walk over every
# annotation of every page, and it answers a different question - an
# attachment a reader offers in its attachment pane is one in this tree, and
# an invoice's XML has to be there.
proc ::tclpdf::pdf::Attachments {readerVar root} {
  upvar 1 $readerVar reader
  set tree [Resolve reader \
      [Get [Resolve reader [Get $root Names]] EmbeddedFiles]]
  if {[lindex $tree 0] ne "d"} {
    return {}
  }
  set out {}
  foreach {- item} [NameTree reader $tree {}] {
    set spec [Resolve reader $item]
    # /UF is the name as text, /F the same name in a byte encoding; a reader
    # takes /UF where both are there (7.11.3).
    set name [Text [Resolve reader [Get $spec UF]]]
    if {$name eq {}} {
      set name [Text [Resolve reader [Get $spec F]]]
    }
    set stream [Resolve reader [Get [Resolve reader [Get $spec EF]] F]]
    lappend out [dict create name $name \
        description [Text [Resolve reader [Get $spec Desc]]] \
        relationship [Plain reader [Get $spec AFRelationship]] \
        mime [Plain reader [Get $stream Subtype]] \
        size [Plain reader [Get [Resolve reader [Get $stream Params]] Size]]]
  }
  return $out
}

# A name tree flattened to {name value ...} (7.9.6). The nodes visited are
# remembered: a /Kids entry pointing back at an ancestor is a file this would
# otherwise walk forever on.
proc ::tclpdf::pdf::NameTree {readerVar node seen} {
  upvar 1 $readerVar reader
  set names [Resolve reader [Get $node Names]]
  if {[lindex $names 0] eq "a"} {
    set out {}
    foreach {key value} [lindex $names 1] {
      lappend out [Text [Resolve reader $key]] $value
    }
    return $out
  }
  set kids [Resolve reader [Get $node Kids]]
  if {[lindex $kids 0] ne "a"} {
    return {}
  }
  set out {}
  foreach kid [lindex $kids 1] {
    if {[lindex $kid 0] eq "r"} {
      set number [lindex [lindex $kid 1] 0]
      if {[dict exists $seen $number]} continue
      dict set seen $number 1
    }
    lappend out {*}[NameTree reader [Resolve reader $kid] $seen]
  }
  return $out
}

# The signature fields of the interactive form (12.7.5.5), each with what its
# signature dictionary claims. Whether the claim holds is not decided here -
# see the head of this section.
#
# The walk is [FieldWalk] below, the one [pdf fields] uses: the field tree,
# the inheritance of /FT down it and the rule that tells a field from a widget
# are one piece of reading, and were written twice here until the reading half
# of the form topic arrived and had to agree with this one.
proc ::tclpdf::pdf::Signatures {readerVar acroform} {
  upvar 1 $readerVar reader
  set state [dict create nodes {} seen {} widgets {}]
  FieldWalk reader [Resolve reader [Get $acroform Fields]] {d {}} {} state
  set size [string length [dict get $reader bytes]]
  set found {}
  foreach node [dict get $state nodes] {
    if {[Plain reader [Get [dict get $node inherited] FT]] ne "Sig"} continue
    lappend found [SignatureField reader [dict get $node field] \
        [dict get $node name] $size]
  }
  return $found
}

proc ::tclpdf::pdf::SignatureField {readerVar field name size} {
  upvar 1 $readerVar reader
  set value [Resolve reader [Get $field V]]
  set range {}
  foreach item [lindex [Resolve reader [Get $value ByteRange]] 1] {
    lappend range [Plain reader $item]
  }
  # Whether the signature covers the file to its last byte: /ByteRange is
  # {start length start length} and the second pair ends where the signed part
  # ends (12.8.1). A file written on after it was signed answers 0 here - and
  # that is the one thing about a signature this reader CAN decide, because it
  # is arithmetic over offsets rather than cryptography.
  set whole 0
  if {[llength $range] == 4} {
    set whole [expr {[lindex $range 2] + [lindex $range 3] == $size}]
  }
  return [dict create field $name \
      filter [Plain reader [Get $value Filter]] \
      subfilter [Plain reader [Get $value SubFilter]] \
      name [Text [Resolve reader [Get $value Name]]] \
      reason [Text [Resolve reader [Get $value Reason]]] \
      location [Text [Resolve reader [Get $value Location]]] \
      date [Text [Resolve reader [Get $value M]]] \
      byterange $range whole $whole]
}

# The XMP packet of the catalog (14.3.2), decoded like any other stream this
# reader takes bytes out of; empty where the file carries none. It is handed
# out RAW rather than parsed: reading XML properly means tdom, which this
# package requires only where a document builds a packet of its own, and a
# caller who wants more than a claim has the whole packet here.
proc ::tclpdf::pdf::Metadata {readerVar} {
  upvar 1 $readerVar reader
  set entry [Get [Catalog reader] Metadata]
  if {[lindex $entry 0] ne "r"} {
    return {}
  }
  lassign [Object reader [lindex [lindex $entry 1] 0]] value hasStream data
  if {!$hasStream} {
    return {}
  }
  return [DecodeStream reader $value $data "the metadata stream"]
}

# What a packet claims for one property, in both spellings a writer may use:
# as an element, and as an attribute on the rdf:Description - both are legal
# RDF and both occur in the wild. One regexp rather than a DOM, for the reason
# [::tclpdf::zugferd identify] gives for the invoice XML: pulling in a parser
# to read one string would make tdom a dependency of every caller.
#
# The limit of that, stated rather than hidden: the PREFIX is matched, not the
# namespace URI it is bound to. A packet binding the AIIM namespace to a
# prefix other than "pdfaid" answers empty here. Measured over 106 foreign
# files and the 61 this package writes: not one spells it otherwise, and the
# packets that do carry a claim are the ones written to be recognised.
proc ::tclpdf::pdf::Claim {packet prefix property} {
  if {[regexp "<$prefix:${property}(?:\\s\[^>\]*)?>(\[^<\]*)<" $packet \
      -> value]} {
    return [string trim $value]
  }
  if {[regexp "\\m$prefix:$property\\s*=\\s*\[\"'\](\[^\"'\]*)\[\"'\]" \
      $packet -> value]} {
    return [string trim $value]
  }
  return {}
}

# ----------------------------------------------------------------- the pages

proc ::tclpdf::pdf::PageInventory {readerVar} {
  upvar 1 $readerVar reader
  set count [PageCount reader]
  if {$count eq {}} {
    return {}
  }
  set out {}
  for {set number 1} {$number <= $count} {incr number} {
    set geometry [Geometry reader [Page reader $number] $number]
    lappend out [dict create number $number \
        mediabox [dict get $geometry media] \
        cropbox [dict get $geometry crop] \
        rotate [dict get $geometry rotate] \
        width [dict get $geometry width] height [dict get $geometry height]]
  }
  return $out
}

# ----------------------------------------------------------------- the fonts

# Every face the file uses, with the one thing about a font that decides
# whether the file can be relied on somewhere else: are its glyphs in it. The
# walk is the one pdffonts makes - every page, its resources, and the
# resources of the forms and patterns those reach - because a face used only
# inside a placed form is in the file just as much.
proc ::tclpdf::pdf::FontInventory {readerVar} {
  upvar 1 $readerVar reader
  set count [PageCount reader]
  if {$count eq {}} {
    return {}
  }
  set state [dict create fonts {} visited {}]
  for {set number 1} {$number <= $count} {incr number} {
    set page [Page reader $number]
    Faces reader [Get $page Resources] $number state
    # An annotation carries its appearance as a form XObject with resources
    # of its own (12.5.5), and a face used only there - the value in a filled
    # form field, a stamp, a callout - is in the file just the same. Measured
    # on a 60-page magazine full of interactive elements: 9 faces without
    # this walk, 20 with it, and pdffonts finds the same 20.
    foreach item [lindex [Resolve reader [Get $page Annots]] 1] {
      set appearances [Resolve reader [Get [Resolve reader $item] AP]]
      foreach {- appearance} [lindex $appearances 1] {
        set form [Resolve reader $appearance]
        if {[lindex $form 0] ne "d"} continue
        if {[Get $form BBox] ne {}} {
          Faces reader [Get $form Resources] $number state
        } else {
          # /N may be a dictionary of appearance STATES rather than one
          # form - a checkbox has an /Off and an /On (12.5.5).
          foreach {- item} [lindex $form 1] {
            Faces reader [Get [Resolve reader $item] Resources] $number state
          }
        }
      }
    }
  }
  return [dict values [dict get $state fonts]]
}

# One resource dictionary and everything reachable from it, for one page.
# "visited" is keyed by object number AND page: two pages sharing a dictionary
# - the normal case - is walked twice because the second page has to be
# recorded, and a form naming its own resources is not walked twice for the
# same page.
proc ::tclpdf::pdf::Faces {readerVar resources page stateVar} {
  upvar 1 $readerVar reader $stateVar state
  if {[lindex $resources 0] eq "r"} {
    set number [lindex [lindex $resources 1] 0]
    if {[dict exists $state visited $number $page]} {
      return
    }
    dict set state visited $number $page 1
  }
  set resources [Resolve reader $resources]
  if {[lindex $resources 0] ne "d"} {
    return
  }
  foreach {- item} [lindex [Resolve reader [Get $resources Font]] 1] {
    Face reader $item $page state
  }
  # A form XObject and a tiling pattern carry resources of their own, and a
  # face used only there is used by the file.
  foreach group {XObject Pattern} {
    foreach {- item} [lindex [Resolve reader [Get $resources $group]] 1] {
      Faces reader [Get [Resolve reader $item] Resources] $page state
    }
  }
  return
}

proc ::tclpdf::pdf::Face {readerVar item page stateVar} {
  upvar 1 $readerVar reader $stateVar state
  # A face is remembered under its object number where it has one, and under
  # the parsed dictionary itself where it stands directly in the resources: a
  # direct font dictionary has no identity of its own, and two pages carrying
  # the same one carry the same face.
  if {[lindex $item 0] eq "r"} {
    set key [lindex [lindex $item 1] 0]
    set object $key
  } else {
    set key $item
    set object {}
  }
  if {[dict exists $state fonts $key]} {
    # The pages are visited in order, so the same one is only ever the last
    # in the list - a face reached through thirty checkbox appearances of one
    # page is on that page once.
    set pages [dict get $state fonts $key pages]
    if {[lindex $pages end] ne $page} {
      lappend pages $page
      dict set state fonts $key pages $pages
    }
    return
  }
  set font [Resolve reader $item]
  if {[lindex $font 0] ne "d"} {
    return
  }
  set subtype [Plain reader [Get $font Subtype]]
  set base [Plain reader [Get $font BaseFont]]
  # A composite font describes itself in TWO dictionaries (9.7.1): the Type 0
  # font carries the encoding, its one descendant the glyphs. Which of them a
  # reader calls "the font" differs - pdffonts names the descendant - so both
  # are reported: "subtype" is what the resource says, "cid" what stands
  # behind it, and the descriptor is looked for where it actually is.
  set descendant {}
  set cid {}
  if {$subtype eq "Type0"} {
    set descendant [Resolve reader [lindex [lindex [Resolve reader \
        [Get $font DescendantFonts]] 1] 0]]
    set cid [Plain reader [Get $descendant Subtype]]
  }
  set carrier [expr {$descendant ne {} ? $descendant : $font}]
  set descriptor [Resolve reader [Get $carrier FontDescriptor]]
  set file {}
  foreach entry {FontFile FontFile2 FontFile3} {
    if {[Get $descriptor $entry] ne {}} {
      set file $entry
      break
    }
  }
  # A Type 3 font has no font file: its glyphs ARE content streams of this
  # file (9.6.5). So the file carries them, which is what "embedded" answers,
  # and why it says yes here. Its glyph procedures may use faces of their own,
  # through resources the font carries.
  if {$file eq {} && [Get $font CharProcs] ne {}} {
    set file CharProcs
    Faces reader [Get $font Resources] $page state
  }
  # Where a font names itself nowhere - which a Type 3 font may do, /BaseFont
  # being reserved for the others - the descriptor's /FontName is the name
  # every reader shows, pdffonts included, and the deprecated /Name of 9.6.5
  # is the last resort.
  if {$base eq {}} {
    set base [Plain reader [Get $descriptor FontName]]
  }
  if {$base eq {}} {
    set base [Plain reader [Get $font Name]]
  }
  set encoding [Resolve reader [Get $font Encoding]]
  set differences 0
  if {[lindex $encoding 0] eq "d"} {
    set differences [expr {[Get $encoding Differences] ne {}}]
    set encoding [Get $encoding BaseEncoding]
  }
  dict set state fonts $key [dict create object $object subtype $subtype \
      cid $cid basefont $base \
      subset [regexp {^[A-Z]{6}\+} $base] \
      embedded [expr {$file ne {}}] file $file \
      encoding [Plain reader $encoding] differences $differences \
      pages [list $page]]
  return
}

# ---------------------------------------------------------------- the fields

# THE FIELDS OF AN INTERACTIVE FORM (12.7) AND THE VALUES THAT STAND IN THEM -
# the reading half of what field.tcl, fieldText.tcl, fieldButton.tcl and
# fieldChoice.tcl write, and the answer to the only question a filled-in
# form is ever asked: what did the sender type. Until this existed the
# answer needed another program - "qpdf --json --json-key=acroform", or
# PDFBox through a Java runtime - for a walk this reader was making anyway.
#
# THE WORDS OF "type" ARE THE SUBCOMMANDS OF [$doc field]: text, check, radio,
# button, listbox and combo, not the /FT names Tx, Btn and Ch. The two halves
# of the package then speak one language - what [$doc field combo ...] wrote
# comes back as "combo" - and the caller who wants the raw name has /FT one
# lookup away in any case. "signature" is the one word with no subcommand
# behind it: a signature field is written by [$doc sign], and what its value
# claims is answered by [pdf info] under "signatures".
#
# /V IS A DIFFERENT DATA TYPE IN EVERY FIELD TYPE, and a reader that treats
# them alike answers nonsense. Table 226 says only "(various)"; the types are
# in the four sections below it:
#
#   text        a text string (12.7.5.3)          -> the string
#   check       a NAME, the on state or /Off      -> the name, without slash
#   radio       a NAME, the on state or /Off      -> the name, without slash
#   button      nothing at all (12.7.5.2.2)       -> empty
#   listbox     the DISPLAY text, or an array of  -> the text, or a list of
#   combo       display texts for a multi select     texts
#   signature   a signature DICTIONARY (12.7.5.5) -> "signed", and [pdf info]
#                                                    for what it claims
#
# The choice field is the trap: what stands in /V is the displayed text, and
# the EXPORT value - the one a form submission carries - is the first element
# of the matching /Opt entry and stands nowhere else in the field. "selected"
# answers that value, so a caller never has to guess; "options" hands out both
# halves as {export display} pairs, whether the file wrote the entry as one
# string or as the two-element array of Table 234.
#
# EVERY KEY IS ALWAYS THERE, with an empty value where the file says nothing -
# as everywhere in this file:
#
#   name        the fully qualified name (12.7.4.2): the partial names of the
#               chain, joined with dots
#   partial     the /T of this node alone
#   object      the object number of the field dictionary; empty where the
#               field stands directly in the array rather than as a reference
#   type        text, check, radio, button, listbox, combo, signature; the raw
#               /FT name where the file names a type this package does not
#               know, and empty where the chain carries none at all
#   value       /V, read as the type demands - the table above
#   default     /DV, read the same way
#   flags       the SET bits of /Ff by name, in bit order; an unnamed bit
#               travels as "bit<n>" rather than being dropped
#   options     /Opt as {export display} pairs, one per option
#   selected    the EXPORT values in force
#   tooltip     /TU, which is also the accessible name of the field (14.9.3)
#   readonly    the ReadOnly flag as 0 or 1 - the one flag a caller asks about
#               without wanting the whole list
#   required    the Required flag, likewise
#   pages       the page numbers this field's widgets sit on, ascending and
#               without repeats
#   widgets     one dictionary per widget annotation, in the order the file
#               lists them: page, rect (the /Rect as it is written), state
#               (its /AS name) and appearance (does it carry /AP /N)
#   appearance  1 where EVERY widget carries /AP /N, 0 where one does not, and
#               empty where the field has no widget at all. A widget without
#               it is drawn by nobody unless the file asks the reader to draw,
#               which is what /NeedAppearances does and 12.7.3 deprecates -
#               with the one exception 12.5.2 makes for a rectangle degenerate
#               in BOTH axes, which is how an invisible signature field is
#               written and why those answer 0 here without anything being
#               wrong with them
#
# MEASURED AGAINST TWO OTHER READERS, on 2026-08-23. Over 65 documents and 703
# fields - 56 foreign forms found on this machine plus this package's own
# examples - name, type, value, tooltip and widget count agree with Apache
# PDFBox (through tools/formcheck.java) on every field but one kind, and that
# one is deliberate: where a check box or a radio set carries NO /V at all,
# PDFBox answers "Off" and this answers empty, because that is what the file
# says. 12.7.5.2.3 makes /Off the off state and a missing value means the same
# thing, so a caller who wants the question rather than the entry reads
# "selected", which is empty in both cases.
#
# qpdf --json --json-key=acroform agrees on name, type and flags and differs
# in three ways that are worth knowing, because all three are about WHAT IS
# COUNTED rather than what is read: it enumerates WIDGETS, so a radio set of
# three buttons is three rows there and one record here; it therefore omits a
# field that has no widget, which PDFBox lists as this does; and its
# "alternativename" falls back to the field's name where the file writes no
# /TU, and reads that entry off the widget, so the /TU of a radio SET is lost
# there and answered here.
#
# WHAT IS NOT ANSWERED, and why. The XFA data of an XFA form (Table 224): it
# is an XML stream in a format defined outside ISO 32000, and the /AcroForm
# fields underneath it are a shadow copy that need not agree with it - so an
# XFA file is refused rather than half-answered, and -xfa 1 says "the shadow
# copy is what I want". An ENCRYPTED file is refused by the reader itself: a
# field name and a text value are STRINGS, and strings are the one thing every
# security handler encrypts (7.6.2), so an answer would be cipher text with
# the shape of a form. Measured on a 40-bit RC4 form: /FT, /Ff and /AS come
# through - names and numbers are not encrypted - and every /T and /V is
# binary rubbish. Half an answer with no way to tell which half is why the
# refusal stands.

proc ::tclpdf::pdf::FieldInventory {readerVar allowXfa} {
  upvar 1 $readerVar reader
  set acroform [Resolve reader [Get [Catalog reader] AcroForm]]
  if {[lindex $acroform 0] ne "d"} {
    return {}
  }
  if {[Get $acroform XFA] ne {} && !$allowXfa} {
    return -code error -errorcode {TCLPDF IMPORT XFA} "tclpdf:\
        [dict get $reader path] carries an XFA form (ISO 32000-2, Table 224,\
        deprecated in PDF 2.0): its data lives in an XML stream in a format\
        defined outside the PDF standard, and the /AcroForm fields beneath it\
        are a shadow copy that need not agree with it. Ask for that copy with\
        \"-xfa 1\" where it is what you want; \[::tclpdf::pdf info\] reports\
        the form as XFA either way"
  }
  set state [dict create nodes {} seen {} widgets [WidgetPages reader]]
  FieldWalk reader [Resolve reader [Get $acroform Fields]] {d {}} {} state
  set out {}
  foreach node [dict get $state nodes] {
    lappend out [FieldRecord reader $node state]
  }
  return $out
}

# One level of the field tree, collecting every NODE THAT NAMES ITSELF.
# 12.7.4.2: "A field dictionary that does not have a partial field name (T
# entry) of its own shall not be considered a field but simply a Widget
# annotation" - so the /Kids of a radio set are widgets, not four fields, and
# the same walk has to tell the two apart by /T alone.
#
# /FT, /Ff, /V and /DV are INHERITABLE down the tree (Table 226), and they are
# carried in "inherited" as the raw items rather than resolved here: a parent
# may name the type and the kids the widgets, and a set of radio buttons keeps
# its value on the parent while the kids answer /AS to it.
proc ::tclpdf::pdf::FieldWalk {readerVar array inherited prefix stateVar} {
  upvar 1 $readerVar reader $stateVar state
  if {[lindex $array 0] ne "a"} {
    return
  }
  foreach item [lindex $array 1] {
    if {[lindex $item 0] eq "r"} {
      set number [lindex [lindex $item 1] 0]
      # A /Kids that points back at an ancestor is a ring, and a file with one
      # exists: measured on a form written by jsPDF, "qpdf --json" answers
      # "loop detected while traversing /AcroForm" on three of its objects.
      if {[dict exists $state seen $number]} continue
      dict set state seen $number 1
      set object $number
    } else {
      set object {}
    }
    set field [Resolve reader $item]
    if {[lindex $field 0] ne "d"} continue
    # "inherited" is a PARSED DICTIONARY, {d {...}}, not a Tcl dict - so that
    # [Get] reads it exactly as it reads the field itself, and one accessor
    # answers both. It is copied per NODE and never written back into the
    # loop's own variable: an inheritable entry travels DOWN the tree
    # (12.7.4.2), and a sibling that took over the /V of the sibling before it
    # would answer a value nobody ever wrote.
    set carried $inherited
    foreach key {FT Ff V DV} {
      if {[Get $field $key] ne {}} {
        Put carried $key [Get $field $key]
      }
    }
    set partial [Text [Resolve reader [Get $field T]]]
    set name $prefix
    if {[Get $field T] ne {}} {
      set name [expr {$prefix eq {} ? $partial : "$prefix.$partial"}]
      dict lappend state nodes [dict create item $item object $object \
          field $field name $name partial $partial inherited $carried]
    }
    FieldWalk reader [Resolve reader [Get $field Kids]] $carried $name state
  }
  return
}

# What one field says about itself. The order of the keys is the order of the
# table at the head of this section.
proc ::tclpdf::pdf::FieldRecord {readerVar node stateVar} {
  upvar 1 $readerVar reader $stateVar state
  set field [dict get $node field]
  set inherited [dict get $node inherited]
  set kind [Plain reader [Get $inherited FT]]
  set bits [Plain reader [Get $inherited Ff]]
  if {![string is entier -strict $bits]} {
    set bits 0
  }
  set type [FieldType $kind $bits]
  set options [FieldOptions reader $field]
  set value [FieldValueText reader [Get $inherited V] $type]
  set widgets [FieldWidgets reader $node state]
  set pages {}
  set appearance {}
  foreach widget $widgets {
    if {[dict get $widget page] ne {} && [dict get $widget page] ni $pages} {
      lappend pages [dict get $widget page]
    }
    if {$appearance eq {} || $appearance} {
      set appearance [dict get $widget appearance]
    }
  }
  return [dict create name [dict get $node name] \
      partial [dict get $node partial] object [dict get $node object] \
      type $type value $value \
      default [FieldValueText reader [Get $inherited DV] $type] \
      flags [FieldFlagNames $kind $bits] options $options \
      selected [FieldSelected reader $field $type $value $options] \
      tooltip [Text [Resolve reader [Get $field TU]]] \
      readonly [expr {($bits & 1) != 0}] \
      required [expr {($bits & 2) != 0}] \
      pages [lsort -integer $pages] widgets $widgets \
      appearance $appearance]
}

# The word for a field type. /FT alone does not say it: three of the six
# things a caller calls a field are one /FT told apart by /Ff (Table 229 for
# the button, Table 233 for the choice), which is why the flags are read
# before the type and not after it.
proc ::tclpdf::pdf::FieldType {kind bits} {
  switch -- $kind {
    Tx {return text}
    Sig {return signature}
    Btn {
      if {$bits & (1 << 16)} {return button}
      if {$bits & (1 << 15)} {return radio}
      return check
    }
    Ch {return [expr {$bits & (1 << 17) ? "combo" : "listbox"}]}
  }
  # A file may name a type this package does not build - and one that names
  # none at all is legal for a node that only groups names (12.7.4.2). Both
  # are reported as they stand rather than guessed at: the words above are
  # lower case, so a raw /FT name is recognisable as one.
  return $kind
}

# The set bits of /Ff by name. NOT the table of [::tclpdf::field flags], and
# the reason is bit 26: it is RichText on a text field and RadiosInUnison on a
# button (Tables 231 and 229), so the same number has two names and only the
# field type says which. A writer is told the name and computes the bit, which
# that collision does not trouble; a reader is handed the bit and must find
# the name, and needs the type to do it. tests/importFields.test holds the two
# tables against each other so the split cannot drift.
proc ::tclpdf::pdf::FieldFlagNames {kind bits} {
  variable fieldFlagCommon
  variable fieldFlagByType
  set names $fieldFlagCommon
  if {[dict exists $fieldFlagByType $kind]} {
    set names [dict merge $names [dict get $fieldFlagByType $kind]]
  }
  set out {}
  for {set bit 1} {$bit <= 32} {incr bit} {
    if {!($bits & (1 << ($bit - 1)))} continue
    # A bit nobody names is REPORTED, not dropped: a foreign file that sets
    # one is saying something, and "bit26 on a signature field" is a fact a
    # caller can act on where "no flags" would be a lie.
    lappend out [expr {[dict exists $names $bit]
        ? [dict get $names $bit] : "bit$bit"}]
  }
  return $out
}

# /V or /DV as the field type demands - the table at the head of this section.
proc ::tclpdf::pdf::FieldValueText {readerVar item type} {
  upvar 1 $readerVar reader
  set value [Resolve reader $item]
  if {$value eq {}} {
    return {}
  }
  switch -- $type {
    button {
      # 12.7.5.2.2 gives a push button no value at all: it holds no state, it
      # only acts. A file that writes one anyway is not answered with it.
      return {}
    }
    signature {
      return [expr {[lindex $value 0] eq "d" ? "signed" : {}}]
    }
    listbox - combo {
      # "or an array of text strings" (Table 234) - a multiple selection.
      if {[lindex $value 0] eq "a"} {
        set out {}
        foreach entry [lindex $value 1] {
          lappend out [Text [Resolve reader $entry]]
        }
        return $out
      }
    }
  }
  # A name for the two button types, a string for everything else - and the
  # other way round where a file has it the other way round, because reading
  # a name with [Text] answers empty and losing the value is worse than
  # reporting it in the shape it was found in.
  #
  # A check box with no /V at all is answered EMPTY, not "Off". The two mean
  # the same thing to a reader - 12.7.5.2.3 - and PDFBox fills the name in;
  # this does not, because every other key in this answer is empty where the
  # file is silent, and "selected" says the same thing without the guess.
  if {[lindex $value 0] eq "nm"} {
    return [lindex $value 1]
  }
  return [Text $value]
}

# /Opt as {export display} pairs. Table 234: an entry is "either a text string
# representing one of the available options or an array consisting of two text
# strings: the option's export value and the text that shall be displayed".
# Where the file wrote one string, the two halves are the same string - which
# is what the standard means by it, and it saves every caller the test.
proc ::tclpdf::pdf::FieldOptions {readerVar field} {
  upvar 1 $readerVar reader
  set entries [Resolve reader [Get $field Opt]]
  if {[lindex $entries 0] ne "a"} {
    return {}
  }
  set out {}
  foreach entry [lindex $entries 1] {
    set entry [Resolve reader $entry]
    if {[lindex $entry 0] eq "a"} {
      set pair [lindex $entry 1]
      set export [Text [Resolve reader [lindex $pair 0]]]
      set display [expr {[llength $pair] > 1
          ? [Text [Resolve reader [lindex $pair 1]]] : $export}]
      lappend out [list $export $display]
    } else {
      set text [Text $entry]
      lappend out [list $text $text]
    }
  }
  return $out
}

# The EXPORT values in force. For a choice field that is the one thing /V does
# not say - see the head of this section - and there are two roads to it:
#
#   /I, "the zero-based indices in the Opt array of the currently selected
#   option items" (Table 234), which is exact and is written wherever /V is
#   ambiguous, and
#
#   /V matched against the DISPLAY halves of /Opt, for the ordinary file that
#   writes no /I.
#
# /I wins where it is there, because that is the entry the standard invented
# for the case the other road cannot decide: two options showing the same text.
# A value matching no option at all travels unchanged - an editable combo box
# (the Edit flag) may hold anything its user typed, and that IS the value.
#
# For a check box and a radio button the export value is /V itself: it is the
# name of the on state, and /Off - the one name 12.7.5.2.3 reserves - means
# nothing is chosen. Everything else has no export value to give.
proc ::tclpdf::pdf::FieldSelected {readerVar field type value options} {
  upvar 1 $readerVar reader
  switch -- $type {
    check - radio {
      return [expr {$value eq {} || $value eq "Off" ? {} : [list $value]}]
    }
    listbox - combo {}
    default {return {}}
  }
  set indices [Resolve reader [Get $field I]]
  if {[lindex $indices 0] eq "a"} {
    set out {}
    foreach entry [lindex $indices 1] {
      set index [Plain reader $entry]
      if {[string is entier -strict $index] && $index >= 0
          && $index < [llength $options]} {
        lappend out [lindex $options $index 0]
      }
    }
    if {[llength $out]} {
      return $out
    }
  }
  set out {}
  foreach text $value {
    set export $text
    foreach option $options {
      if {[lindex $option 1] eq $text} {
        set export [lindex $option 0]
        break
      }
    }
    lappend out $export
  }
  return $out
}

# The widget annotations of one field. Two shapes and both are normal
# (12.7.4.2): the field IS its widget, everything in one dictionary, where it
# has only one; or the field carries /Kids and each kid without a /T of its own
# is one of its widgets. A radio set is the second shape and cannot be the
# first - four buttons are four annotations and one field.
proc ::tclpdf::pdf::FieldWidgets {readerVar node stateVar} {
  upvar 1 $readerVar reader $stateVar state
  set field [dict get $node field]
  set items {}
  # /Subtype is what says it, /Rect what betrays it: a merged field-widget
  # written without /Subtype /Widget is out of line with Table 166 and occurs,
  # and a field dictionary has no rectangle for any other reason.
  if {[Plain reader [Get $field Subtype]] eq "Widget"
      || [Get $field Rect] ne {}} {
    lappend items [dict get $node item]
  }
  foreach kid [lindex [Resolve reader [Get $field Kids]] 1] {
    set widget [Resolve reader $kid]
    if {[lindex $widget 0] ne "d" || [Get $widget T] ne {}} continue
    lappend items $kid
  }
  set out {}
  foreach item $items {
    set widget [Resolve reader $item]
    set rect {}
    foreach number [lindex [Resolve reader [Get $widget Rect]] 1] {
      lappend rect [Plain reader $number]
    }
    set page {}
    if {[dict exists $state widgets $item]} {
      set page [dict get $state widgets $item]
    }
    lappend out [dict create page $page rect $rect \
        state [Plain reader [Get $widget AS]] \
        appearance [expr {[Get [Resolve reader [Get $widget AP]] N] ne {}}]]
  }
  return $out
}

# Which page each annotation stands on, keyed by the ITEM as the file wrote
# it - a reference for the normal case, the parsed dictionary for the rare
# annotation written directly into /Annots. Both are the same Tcl value in the
# field tree and in the page's array, so one dictionary answers both.
#
# The page is looked up here rather than through the widget's /P (Table 166),
# and the difference matters: /P names the page OBJECT, and turning an object
# number into "page 3" needs the page tree walked anyway. A widget that no
# page lists is answered with an empty page - it is in the file and in no
# reader's window, and that is a fact worth having rather than a hole to fill
# by guessing.
proc ::tclpdf::pdf::WidgetPages {readerVar} {
  upvar 1 $readerVar reader
  set count [PageCount reader]
  if {$count eq {}} {
    return {}
  }
  set map {}
  for {set number 1} {$number <= $count} {incr number} {
    foreach item [lindex [Resolve reader [Get [Page reader $number] Annots]] 1] {
      if {![dict exists $map $item]} {
        dict set map $item $number
      }
    }
  }
  return $map
}

namespace eval ::tclpdf::pdf {
  # The three flags every field type has (Table 227), and the ones each type
  # has of its own (Tables 229, 231 and 233), by the bit position the standard
  # counts from ONE: /Ff 1 is ReadOnly, not bit 1 of a zero-based count. See
  # [FieldFlagNames] for why this is not the writer's table turned round.
  variable fieldFlagCommon {1 ReadOnly 2 Required 3 NoExport}
  variable fieldFlagByType {
    Tx {13 Multiline 14 Password 21 FileSelect 23 DoNotSpellCheck
        24 DoNotScroll 25 Comb 26 RichText}
    Btn {15 NoToggleToOff 16 Radio 17 Pushbutton 26 RadiosInUnison}
    Ch {18 Combo 19 Edit 20 Sort 22 MultiSelect 23 DoNotSpellCheck
        27 CommitOnSelChange}
  }
}

# -------------------------------------------------------------- the plumbing

# A value the caller wants as plain text: a number, a name, a boolean. Written
# out because "[lindex [Resolve reader [Get $x Key]] 1]" stood in this file
# often enough for the next one to be the typo nobody sees.
proc ::tclpdf::pdf::Plain {readerVar value} {
  upvar 1 $readerVar reader
  return [lindex [Resolve reader $value] 1]
}

# A text string (7.9.2.2) as Tcl characters. Two encodings are possible and
# the byte order mark tells them apart: UTF-16BE with one, PDFDocEncoding
# without. A hexadecimal string is the same string written differently and is
# decoded first - a producer writing its title as <FEFF0054...> means what one
# writing a literal means.
proc ::tclpdf::pdf::Text {value} {
  switch -- [lindex $value 0] {
    s {set bytes [lindex $value 1]}
    h {
      # An odd number of digits is read as if a 0 followed (7.3.4.3), and
      # anything that is not a hexadecimal digit is white space in between.
      set hex [regsub -all {[^0-9A-Fa-f]} [lindex $value 1] {}]
      if {[string length $hex] % 2} {
        append hex 0
      }
      set bytes [binary decode hex $hex]
    }
    default {return {}}
  }
  set mark [string range $bytes 0 1]
  if {$mark eq "\xFE\xFF"} {
    return [Utf16 [string range $bytes 2 end] Su*]
  }
  # UTF-16LE is not what 7.9.2.2 allows, and files carrying it exist; read as
  # PDFDocEncoding it answers with a NUL between every character, which is
  # further from the intent than reading it.
  if {$mark eq "\xFF\xFE"} {
    return [Utf16 [string range $bytes 2 end] su*]
  }
  return [PdfDoc $bytes]
}

# UTF-16 to characters, correct under both interpreters WITHOUT a version
# switch - the counterpart of [::tclpdf::pdfObj::Utf16Be], which writes the
# same thing. Tcl 9 holds a character above the BMP as one code point, Tcl 8.6
# as the surrogate pair it arrived in, so the pair is combined and the result
# CHECKED: where [format %c] cannot hold the combined value it answers
# something else, and the two halves are then what this interpreter means by
# that character.
proc ::tclpdf::pdf::Utf16 {bytes format} {
  binary scan $bytes $format units
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

# PDFDocEncoding (Annex D.2) to characters. Bytes 0x20 to 0x7E and 0xA1 to
# 0xFF are Latin-1 and are therefore already what was read out of the file;
# what needs a table is the two blocks the encoding fills with typography and
# the Euro sign at 0xA0, where Latin-1 has a no-break space.
proc ::tclpdf::pdf::PdfDoc {bytes} {
  variable pdfDocEncoding
  set out {}
  foreach char [split $bytes {}] {
    set code [scan $char %c]
    if {[dict exists $pdfDocEncoding $code]} {
      append out [format %c [dict get $pdfDocEncoding $code]]
    } else {
      append out $char
    }
  }
  return $out
}

namespace eval ::tclpdf::pdf {
  # Written as hexadecimal because that is how Annex D.2 reads, and turned
  # into the numbers the lookup wants once, here, rather than on every
  # character of every string.
  variable pdfDocEncoding {
      0x18 0x02D8 0x19 0x02C7 0x1A 0x02C6 0x1B 0x02D9
      0x1C 0x02DA 0x1D 0x02DB 0x1E 0x02DC 0x1F 0x02DD
      0x80 0x2022 0x81 0x2020 0x82 0x2021 0x83 0x2026
      0x84 0x2014 0x85 0x2013 0x86 0x0192 0x87 0x2044
      0x88 0x2039 0x89 0x203A 0x8A 0x2212 0x8B 0x2030
      0x8C 0x201E 0x8D 0x201C 0x8E 0x201D 0x8F 0x2018
      0x90 0x2019 0x91 0x201A 0x92 0x2122 0x93 0xFB01
      0x94 0xFB02 0x95 0x0141 0x96 0x0152 0x97 0x0160
      0x98 0x0178 0x99 0x017D 0x9A 0x0131 0x9B 0x0142
      0x9C 0x0153 0x9D 0x0161 0x9E 0x017E 0xA0 0x20AC}
  set tclpdfTable {}
  foreach {tclpdfCode tclpdfTarget} $pdfDocEncoding {
    dict set tclpdfTable [scan $tclpdfCode %x] [scan $tclpdfTarget %x]
  }
  set pdfDocEncoding $tclpdfTable
  unset tclpdfTable tclpdfCode tclpdfTarget
}

package provide tclpdf::importInfo 1.2
