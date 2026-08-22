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

# The four entries. They are one-liners on purpose, and NOTHING written in
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
proc ::tclpdf::pdf::Signatures {readerVar acroform} {
  upvar 1 $readerVar reader
  set state [dict create found {} seen {} \
      bytes [string length [dict get $reader bytes]]]
  Fields reader [Resolve reader [Get $acroform Fields]] {} {} state
  return [dict get $state found]
}

# One level of the field tree. /FT and /T are inheritable down it (12.7.4.2):
# a field may be split into a parent naming the type and kids carrying the
# widgets, and the fully qualified name is the /T values of the chain joined
# with dots.
proc ::tclpdf::pdf::Fields {readerVar array type prefix stateVar} {
  upvar 1 $readerVar reader $stateVar state
  if {[lindex $array 0] ne "a"} {
    return
  }
  foreach item [lindex $array 1] {
    if {[lindex $item 0] eq "r"} {
      set number [lindex [lindex $item 1] 0]
      if {[dict exists $state seen $number]} continue
      dict set state seen $number 1
    }
    set field [Resolve reader $item]
    if {[lindex $field 0] ne "d"} continue
    set kind [Plain reader [Get $field FT]]
    if {$kind eq {}} {
      set kind $type
    }
    set name [Text [Resolve reader [Get $field T]]]
    if {$name eq {}} {
      set name $prefix
    } elseif {$prefix ne {}} {
      set name $prefix.$name
    }
    # A node is a FIELD where it names itself: 12.7.4.2 permits a missing /T
    # only for a widget annotation merged into a field, and the widgets a
    # field hangs its /Kids on are not fields of their own. Without that test
    # a signature over one field, drawn on one page, is answered twice - once
    # for the field and once for its widget, the second time with every claim
    # empty because the signature dictionary hangs off the field.
    if {$kind eq "Sig" && [Get $field T] ne {}} {
      dict lappend state found \
          [SignatureField reader $field $name [dict get $state bytes]]
    }
    Fields reader [Resolve reader [Get $field Kids]] $kind $name state
  }
  return
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

package provide tclpdf::importInfo 1.1
