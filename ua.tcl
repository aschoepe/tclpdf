#
# tclpdf - PDF generation for Tcl
#
# ua - PDF/UA, the accessibility claim and what has to be true for it
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc tagged 1
#   $doc info Title "Safety briefing 2026"
#   $doc language de-DE
#   $doc ua 1
#
# A tagged document says what its marks ARE. PDF/UA (ISO 14289) is the promise
# that this is done completely and correctly enough for someone who cannot see
# the page to use it. The tree is the substance and structure.tcl builds it;
# what this module adds is the small remainder - the claim in the metadata,
# the two catalogue keys - and, more importantly, the refusal to make the
# claim when the document does not keep it.
#
# Off by default and explicit, exactly as [pdfa] is. Two reasons, and neither
# is caution for its own sake: a UA document must embed every font, which a
# document using the standard 14 cannot; and the claim is legally meaningful
# in public procurement, so nothing should acquire it as a side effect.
#
# What it checks at write time, and why each one is here rather than left to
# a validator: every one of them is invisible in the finished file to anyone
# who does not run a validator, and all of them name the call that has to
# change - which a validator cannot, because by then there is only an object
# number.
#
#   title        7.1 - the window has to show a title, not a file name
#   language     7.2 - a screen reader picks its voice from it
#   fonts        7.21.4 Note 5 - embedding is unconditional here, unlike
#                PDF/A, where the standard 14 stay exempt
#   headings     7.4.2 - H1 first, no level skipped
#   tables       7.5 / UA-2 8.2.5.26, Matterhorn 15-003 - every row spans
#                the same number of columns, colSpan and rowSpan counted
#                as the columns they cover
#   lists        7.6 - an ordered list names its numbering and its items
#                carry a Lbl; items with a Lbl under a list that says
#                nothing are refused the other way round
#   graphics     7.1, 7.3 - a picture, drawing or form placement is either
#                described (-alt) or declared decoration (-artifact 1);
#                one that fell into artifact by default was never judged
#   described    7.3 / UA-2 8.2.5.28.2 for a Figure, 7.7 for a Formula
#                under part 1 - an element the caller opened says what it
#                holds, through -alt or -actualText; an empty -alt is not
#                a description
#   links        7.18.5 - Contents on every annotation, and every one
#                inside a Link element (Matterhorn 28-011)
#   form fields  7.18.1 with ISO 32000-2 14.9.3 - a description on every
#                field (/TU), one per WIDGET where a field has several
#                (UA-2 8.10.2.4), and every widget inside the Form
#                structure element the field core makes for it (7.18.4,
#                UA-2 8.10.1)
#   viewer       7.1 - DisplayDocTitle, set by this module, is still on
#
# What it sets rather than demands: DisplayDocTitle, the pdfuaid schema, and
# for part 2 the structure namespace and the file version. None of those
# changes a single mark on a page, so asking the caller to write them out
# would be ceremony. DisplayDocTitle is nonetheless checked at write time,
# because a later [viewerPreferences] call can take it back.
#
# Part 2 is PDF 2.0 and therefore mutually exclusive with PDF/A-3 - and so
# with ZUGFeRD, which is a PDF/A-3 document by definition. That is the
# standards, not a limitation here, and it is said out loud when both are
# declared.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::option 1.0-
package require tclpdf::xmp 1.0-
package require tclpdf::viewerPreferences 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::ua {
  namespace export {[a-z]*}
  namespace ensemble create

  variable schema "http://www.aiim.org/pdfua/ns/id/"

  # The revision year that goes with part 2. ISO 14289-2 was published in
  # 2024, and pdfuaid:rev is the year, not the part.
  variable revision 2024

  # WTPDF - Well-Tagged PDF, the PDF Association's companion to UA-2. It adds
  # no requirement that UA-2 does not already make; what it adds is a way to
  # SAY so, through a PDF Declaration (WTPDF 6.1.2 and 6.1.3).
  #
  # TWO URIs per level, and that is not a mistake - the specification and the
  # validator disagree about one character.
  #
  # WTPDF 1.0 writes "http://pdfa.org/declarations/wtpdf/#reuse1.0", with a
  # slash before the hash, in all four places it names the identifiers
  # (6.1.2, 6.1.3 and both examples). veraPDF 1.30.2 tests for
  # "http://pdfa.org/declarations/wtpdf#reuse1.0", without it - the test
  # expression it reports is
  #
  #   declarations.contains('http://pdfa.org/declarations/wtpdf#accessibility1.0')
  #
  # so a file following the specification is reported as not conforming, and a
  # file satisfying the validator is not what the specification asked for.
  #
  # Both are written. The declaration mechanism explicitly allows several
  # claims in one document ("A document may contain multiple claims"), the
  # spelling from the specification is the one that means something, and the
  # second costs a line of XMP and makes the file recognisable to the tool
  # everyone checks with. Neither is a false statement about the document:
  # it does conform.
  variable declarations {
    reuse {
      "http://pdfa.org/declarations/wtpdf/#reuse1.0"
      "http://pdfa.org/declarations/wtpdf#reuse1.0"
    }
    accessibility {
      "http://pdfa.org/declarations/wtpdf/#accessibility1.0"
      "http://pdfa.org/declarations/wtpdf#accessibility1.0"
    }
  }

  variable declarationSchema "http://pdfa.org/declarations/"
}

# The PDF/A extension schema description for pdfuaid.
#
# PDF/A allows only the predefined XMP schemas unless a file describes the
# others in its own metadata (ISO 19005, 6.6.2.3.1). pdfuaid is not among the
# predefined ones, so a document claiming PDF/A AND PDF/UA has to carry this -
# without it veraPDF reports "All properties specified in XMP form shall use
# either the predefined schemas...", twice, once per property.
#
# Found by the example rather than by a test: nothing before it had validated
# a document that made both claims at once.
#
# The properties are quoted from Table 1 of each part - part and amd and corr
# in ISO 14289-1, part and rev in ISO 14289-2 - and all four are described,
# whichever part is claimed. Describing a property the file does not use is
# allowed; using one that is not described is what fails.
proc ::tclpdf::ua::extensionSchema {} {
  variable schema
  set properties {
    part "Open Choice of Integer" "PDF/UA version identifier"
    amd  "Open Choice of Text"    "PDF/UA amendment identifier"
    corr "Open Choice of Text"    "PDF/UA corrigenda identifier"
    rev  "Open Choice of Integer" "Year of the date of publication or revision"
  }
  append xml "    <rdf:Description rdf:about=\"\"\
      xmlns:pdfaExtension=\"http://www.aiim.org/pdfa/ns/extension/\"\
      xmlns:pdfaSchema=\"http://www.aiim.org/pdfa/ns/schema#\"\
      xmlns:pdfaProperty=\"http://www.aiim.org/pdfa/ns/property#\">\n"
  append xml "      <pdfaExtension:schemas>\n        <rdf:Bag>\n"
  append xml "          <rdf:li rdf:parseType=\"Resource\">\n"
  append xml "            <pdfaSchema:schema>PDF/UA Universal Accessibility\
      Schema</pdfaSchema:schema>\n"
  append xml "            <pdfaSchema:namespaceURI>$schema</pdfaSchema:namespaceURI>\n"
  append xml "            <pdfaSchema:prefix>pdfuaid</pdfaSchema:prefix>\n"
  append xml "            <pdfaSchema:property>\n              <rdf:Seq>\n"
  foreach {name type description} $properties {
    append xml "                <rdf:li rdf:parseType=\"Resource\">\n"
    append xml "                  <pdfaProperty:name>$name</pdfaProperty:name>\n"
    append xml "                  <pdfaProperty:valueType>$type</pdfaProperty:valueType>\n"
    append xml "                  <pdfaProperty:category>internal</pdfaProperty:category>\n"
    append xml "                  <pdfaProperty:description>$description</pdfaProperty:description>\n"
    append xml "                </rdf:li>\n"
  }
  append xml "              </rdf:Seq>\n            </pdfaSchema:property>\n"
  append xml "          </rdf:li>\n        </rdf:Bag>\n"
  append xml "      </pdfaExtension:schemas>\n    </rdf:Description>"
  return $xml
}

oo::define ::tclpdf::document::document {

  # $doc ua ?0|1?  |  $doc ua ?-part 1|2? ?-revision <year>?
  # $doc ua state
  #
  # The boolean form is the everyday one and means part 1: an accessible
  # document on the 1.7 path, which is what a letter, an invoice or a briefing
  # needs. Part 2 is asked for by name.
  method ua {args} {
    if {[llength $args] == 1 && [string is boolean -strict [lindex $args 0]]} {
      if {![lindex $args 0]} {
        my UaWithdraw
        return {}
      }
      set args {}
    }
    if {[llength $args] && [string index [lindex $args 0] 0] ne "-"} {
      switch -- [lindex $args 0] {
        state {return [my state ua]}
        default {
          return -code error -errorcode [list TCLPDF UA SUBCOMMAND unknown] \
              "tclpdf: unknown ua subcommand\
              \"[lindex $args 0]\" - known is: state"
        }
      }
    }
    variable ::tclpdf::ua::revision
    set current [my state ua]
    if {$current eq {}} {
      set current [dict create part 1 revision $revision wtpdf {}]
    }
    # Parsed over the public options only: the state carries "registered"
    # beside them, and parsing over the whole of it accepted "-registered 1"
    # and named it among the known options - measured. What is not an option
    # is added back afterwards.
    set current [dict merge $current [::tclpdf::option parse \
        [dict remove $current registered] $args "ua"]]
    # pdfuaid:rev is the year of the edition claimed, four digits (ISO
    # 14289-2 Table 1). Anything else would be written into the metadata as
    # given and mean nothing to a validator.
    if {![regexp {^\d{4}$} [dict get $current revision]]} {
      return -code error -errorcode [list TCLPDF UA ARGUMENT revision] \
          "tclpdf: -revision takes a four-digit year, not\
          \"[dict get $current revision]\" - pdfuaid:rev is the year of the\
          edition claimed (ISO 14289-2 Table 1), 2024 for the first"
    }
    variable ::tclpdf::ua::declarations
    foreach level [dict get $current wtpdf] {
      if {![dict exists $declarations $level]} {
        return -code error -errorcode [list TCLPDF UA ARGUMENT wtpdf] \
            "tclpdf: -wtpdf takes [join [dict keys $declarations]\
            { and }], not \"$level\" (WTPDF 6.1.2 and 6.1.3)"
      }
    }
    if {[llength [dict get $current wtpdf]] && [dict get $current part] != 2} {
      return -code error -errorcode [list TCLPDF UA STATE wtpdf] \
          "tclpdf: -wtpdf goes with PDF/UA-2 - WTPDF is a 2.0\
          specification, and its accessibility level is UA-2 plus a\
          declaration. Use \[\$doc ua -part 2 -wtpdf accessibility\]"
    }
    # Said at the call that creates the contradiction, whichever way round the
    # two were declared - and said BEFORE the raise below: pdfa caps the writer
    # at 1.7, so the raise would be refused by the writer with a message that
    # names PDF/A but not the way out; and until 2026-08-17 the raise came
    # first, which left the writer at 2.0 after the refusal - measured, the
    # PDF/A-3 file that followed had a %PDF-2.0 header.
    if {[dict get $current part] == 2 && [my state pdfa] ne {}} {
      return -code error -errorcode [list TCLPDF UA STATE pdfa3] \
          "tclpdf: PDF/UA-2 needs PDF 2.0 and PDF/A-3 is a PDF\
          1.7 format - the two cannot be claimed by one file. Use ua -part 1\
          with PDF/A-3, which is the combination ZUGFeRD needs"
    }
    switch -- [dict get $current part] {
      1 {
        # PDF/UA-1 (ISO 14289-1, 5.1) is a profile of ISO 32000-1, so the file
        # is PDF 1.7 - lifted the way pdfa lifts, and recorded, so that a
        # later [configure -version 1.4] is refused naming PDF/UA.
        if {[package vcompare [[my writer] version] 1.7] < 0} {
          my configure -version 1.7
        }
        my RequireVersion 1.7 "PDF/UA-1"
      }
      2 {
        # The version is raised here rather than checked at write time,
        # because everything written from now on has to know: 2.0 spells the
        # date differently and drops keys that 1.7 still wants. Through
        # [configure], as part 1 does, so that cget answers 2.0 - the writer
        # alone left the option at its old value - and recorded, so that a
        # later [configure -version 1.7] is refused naming PDF/UA-2 rather
        # than writing a %PDF-1.7 header over a part-2 claim; measured both
        # ways.
        if {[package vcompare [[my writer] version] 2.0] < 0} {
          my configure -version 2.0
        }
        my RequireVersion 2.0 "PDF/UA-2"
        # A UA-2 tree may not rely on the default namespace (UA-2 8.2.5.2);
        # structureWrite.tcl writes the 2.0 one and names it on every element
        # when this says so - or on its own, when a 2.0-only type asks for it.
        my state structureNamespace 1
      }
      default {
        return -code error -errorcode [list TCLPDF UA PART number] \
            "tclpdf: PDF/UA part must be 1 or 2, not\
            \"[dict get $current part]\" - part 1 is ISO 14289-1 on the PDF\
            1.7 path, part 2 is ISO 14289-2 and needs PDF 2.0"
      }
    }
    # The subscribers and the schemas are registered ONCE per document, and
    # stay registered through [ua 0]: each of them answers nothing while no
    # claim is made, so a claim withdrawn and made again does not describe
    # itself twice in the packet - which it did, measured with veraPDF, when
    # ua 0 dropped the mark and the next ua 1 registered everything anew.
    if {[my state uaRegistered] ne "1"} {
      my onSelf catalog UaCatalog
      variable ::tclpdf::ua::schema
      my xmpSchema pdfuaid $schema {part rev} UaXmpBody
      variable ::tclpdf::ua::declarationSchema
      my xmpSchema pdfd $declarationSchema {declarations conformsTo} \
          UaDeclarationBody
      my state uaRegistered 1
    }
    if {[my state ua] eq {}} {
      # DisplayDocTitle is mandatory (7.1) and has no alternative: a document
      # claiming UA and asking the viewer to show its file name would be
      # contradicting itself. Set, not demanded - it moves nothing on any page.
      #
      # Set HERE and not in UaCatalog, and that is not a matter of taste:
      # viewerPreferences subscribes to the catalog event on its first call,
      # and a subscriber added while that event is already running is added
      # too late to be called. Measured - the key was simply absent, with
      # nothing anywhere reporting a problem.
      #
      # What it was before is kept, so that [ua 0] can put it back: a caller
      # who set it before the claim keeps it, one who did not gets it taken
      # away again with the claim.
      set preferences [my viewerPreferences]
      my state uaDisplayDocTitleBefore [expr {
          [dict exists $preferences displayDocTitle] ?
          [dict get $preferences displayDocTitle] : "unset"}]
      my viewerPreferences -displayDocTitle 1
      # Written whether or not PDF/A is declared, because the two can be
      # declared in either order and this has to be in the packet by the time
      # it is built. In a document that is not PDF/A it describes a schema
      # nobody asked about - a kilobyte of metadata, and correct.
      my xmpRaw [::tclpdf::ua extensionSchema]
    }
    dict set current registered 1
    my state ua $current
    return $current
  }

  # [ua 0]: the claim is withdrawn, and everything the claim put there goes
  # with it - the state, the extension schema in the packet, the structure
  # namespace demand, DisplayDocTitle where it was ours to set. The
  # subscribers stay and answer nothing on an empty state (see UaCatalog,
  # UaXmpBody, UaDeclarationBody). Until 2026-08-18 only the state was
  # cleared: the write that followed died on the empty dictionary, and a
  # second [ua 1] registered the schema a second time.
  #
  # What cannot be taken back is the file version: part 1 raised it to 1.7
  # and recorded that as a requirement, and a requirement is a fact about
  # what the file already contains. A 1.7 file without a claim is a correct
  # file.
  method UaWithdraw {} {
    if {[my state ua] eq {}} {
      return
    }
    my state ua {}
    my state structureNamespace {}
    my state xmpRaw [lsearch -all -inline -not -exact [my state xmpRaw] \
        [::tclpdf::ua extensionSchema]]
    set before [my state uaDisplayDocTitleBefore]
    if {$before eq "unset"} {
      set preferences [my viewerPreferences]
      dict unset preferences displayDocTitle
      my state viewerPreferences $preferences
    } elseif {$before ne {}} {
      my viewerPreferences -displayDocTitle $before
    }
    my state uaDisplayDocTitleBefore {}
    return
  }

  # What PDF/UA contributes to the XMP packet. rev is part 2 only: UA-1 has
  # no revision and a validator reads one as a claim to something else.
  method UaXmpBody {} {
    set current [my state ua]
    if {$current eq {}} {
      return {}
    }
    set items [list [list text part [dict get $current part]]]
    if {[dict get $current part] == 2} {
      lappend items [list text rev [dict get $current revision]]
    }
    return $items
  }

  # The PDF Declaration, when one was asked for. Empty otherwise, and an
  # empty contribution is left out of the packet entirely rather than written
  # as a description with nothing in it.
  method UaDeclarationBody {} {
    variable ::tclpdf::ua::declarations
    if {[my state ua] eq {}} {
      return {}
    }
    set levels [dict get [my state ua] wtpdf]
    if {![llength $levels]} {
      return {}
    }
    set resources {}
    foreach level $levels {
      foreach uri [dict get $declarations $level] {
        lappend resources [list conformsTo $uri]
      }
    }
    return [list [list bag declarations $resources]]
  }

  # Runs at catalog time, after every beforeWrite subscriber - so the fonts
  # exist as objects by now and can be inspected rather than assumed. The
  # same reasoning, and the same measured mishap behind it, as PdfaCatalog.
  method UaCatalog {} {
    if {[my state ua] eq {}} {
      return
    }
    my UaCheck
    return
  }

  # Everything that has to be true, collected before anything is said. All of
  # them at once rather than one per run: a caller fixing five problems in
  # five write-and-read rounds is the failure mode this avoids.
  method UaCheck {} {
    set problems {}
    if {![my tagged]} {
      lappend problems "the document is not tagged - call \[\$doc tagged 1\]\
          before drawing; PDF/UA is a promise about the structure tree, and\
          without one there is nothing to promise"
    }
    if {[my info Title] eq {}} {
      lappend problems "no title - \[\$doc info Title \"...\"\] (7.1); it is\
          what a reader announces instead of the file name"
    }
    if {[my catalogEntry Lang] eq {}} {
      lappend problems "no language - \[\$doc language de-DE\] (7.2); a screen\
          reader picks its pronunciation from it"
    }
    # PDF/UA-1 is a profile of ISO 32000-1: its header is %PDF-1.n (ISO
    # 14289-1 6.1, veraPDF rule 6.1-1, measured to fail on a 2.0 file).
    # Checked here rather than capped in the writer, because a document may
    # move from part 1 to part 2 - which needs 2.0 - before it is written.
    if {[dict get [my state ua] part] == 1
        && [package vcompare [[my writer] version] 2.0] >= 0} {
      lappend problems "PDF/UA-1 is a PDF 1.7 format (ISO 14289-1, 6.1) and\
          this document is written as PDF [[my writer] version] - claim\
          part 2 instead, or leave -version alone"
    }
    lappend problems {*}[my UaCheckViewer]
    lappend problems {*}[my UaCheckFonts]
    lappend problems {*}[my UaCheckStructure]
    lappend problems {*}[my UaCheckLists]
    lappend problems {*}[my UaCheckGraphics]
    lappend problems {*}[my UaCheckDescribed]
    lappend problems {*}[my UaCheckLinks]
    lappend problems {*}[my UaCheckFields]
    lappend problems {*}[my UaCheckAttachments]
    if {[llength $problems] == 1} {
      return -code error -errorcode [list TCLPDF UA CLAIM problems] \
          "tclpdf: PDF/UA cannot be claimed - [lindex $problems 0]"
    }
    if {[llength $problems]} {
      return -code error -errorcode [list TCLPDF UA CLAIM problems] \
          "tclpdf: PDF/UA cannot be claimed, [llength $problems]\
          reasons:\n  - [join $problems "\n  - "]"
    }
    return
  }

  # The fact comes from font.tcl, which owns the question; what is UA's own
  # is the consequence. PDF/A can suggest dropping the declaration - here the
  # two faces without an embeddable representative rule the document out, and
  # saying so saves a search that has no result.
  method UaCheckFonts {} {
    set missing [my fontsWithoutProgram]
    if {![llength $missing]} {
      return {}
    }
    set problem "[join $missing {, }] [expr {[llength $missing] > 1 ?
        {carry no font program} : {carries no font program}}] - PDF/UA embeds\
        every face, the standard 14 included (7.21.4 Note 5)"
    if {[lsearch -glob $missing {*Symbol*}] >= 0
        || [lsearch -glob $missing {*Dingbat*}] >= 0} {
      append problem ". Symbol and ZapfDingbats have no embeddable\
          representative at all, so no document using them can claim PDF/UA"
    }
    return [list $problem]
  }

  # DisplayDocTitle is set by [ua] and can be taken back by a later
  # [viewerPreferences -displayDocTitle 0] - which the module setting it
  # cannot see, so the finished state is read here. Nothing else in the
  # preferences dictionary concerns UA.
  method UaCheckViewer {} {
    set preferences [my viewerPreferences]
    if {[dict exists $preferences displayDocTitle]
        && [dict get $preferences displayDocTitle]} {
      return {}
    }
    return [list "viewerPreferences -displayDocTitle must stay 1 under PDF/UA\
        (7.1) - the window shows the title instead of the file name, and\
        \[\$doc ua\] sets it; a later \[\$doc viewerPreferences\
        -displayDocTitle 0\] took it back"]
  }

  # A graphic that became an artifact because nobody said otherwise. An
  # artifact carries content past a reader entirely, and PDF/UA allows that
  # for decoration only (7.1); a picture without -alt was never judged either
  # way, and the claim cannot be made over an open question. The question
  # and its wording live in structure.tcl ([GraphicsUndescribed]), shared
  # with the PDF/A level A check in pdfa.tcl - only the clause differs. The
  # guard on the state stays here: an empty record means the document may
  # never have loaded the modules involved, and there is nothing to ask.
  method UaCheckGraphics {} {
    if {[my state undescribedGraphics] eq {}} {
      return {}
    }
    return [my GraphicsUndescribed "7.1, 7.3"]
  }

  # A Figure or a Formula that says nothing about what it holds.
  #
  # [UaCheckGraphics] above asks the other half of the same question and
  # cannot answer this one: its record is filled by [GraphicMark] in
  # image.tcl, so it knows about a picture, a drawing and a form placement
  # and about nothing else. An element the CALLER opened - [$doc structure
  # Figure -script ...] around a hand-drawn diagram, or [$doc text ... -tag
  # Figure] - never passes through that record, and three documents of that
  # shape were written with a PDF/UA claim and rejected by veraPDF
  # (measured 2026-08-25: clause 7.3 test 1 and clause 7.7 test 1). That is
  # the expensive kind of defect: the file says it is accessible, and the
  # recipient's validator is the first thing that disagrees.
  #
  # WHAT COUNTS AS A DESCRIPTION is /Alt or /ActualText, which is veraPDF's
  # test expression verbatim - "(Alt != null && Alt != '') || ActualText !=
  # null" - and is why an EMPTY -alt does not count. It reads as a
  # description and is none, and a document with one is refused by the
  # validator exactly like a document with none.
  #
  # WHICH TYPES, and this is measured rather than reasoned:
  #
  #   Figure   both parts. UA-1 7.3 (Matterhorn 13-004), UA-2 8.2.5.28.2 -
  #            veraPDF fails an undescribed Figure under either profile.
  #   Formula  part 1 only. UA-1 7.7 (Matterhorn 09-004) fails it; veraPDF's
  #            UA-2 profile passes the same document, so demanding it under
  #            part 2 would be this package inventing a rule - the same line
  #            [UaCheckFields] draws around the widget description.
  #
  # Read out of [state structure] rather than through [structureReport],
  # which answers about headings, rows and lists and would have to grow a
  # field for this; the shape of an element record is structure.tcl's, and
  # the two names read here - alt and actualText - are the two the option
  # of the same name fills.
  method UaCheckDescribed {} {
    if {![my tagged]} {
      return {}
    }
    set clauses [dict create Figure [expr {[dict get [my state ua] part] == 2 ?
        {8.2.5.28.2} : {7.3, Matterhorn 13-004}}]]
    if {[dict get [my state ua] part] == 1} {
      dict set clauses Formula "7.7, Matterhorn 09-004"
    }
    set elements [my state structure]
    set problems {}
    set index -1
    foreach element $elements {
      incr index
      set type [dict get $element type]
      if {![dict exists $clauses $type]} {
        continue
      }
      if {[dict get $element alt] ne {} || [dict get $element actualText] ne {}} {
        continue
      }
      set page [my UaElementPage $elements $index]
      lappend problems "[expr {$page eq {} ? {} : "page $page: "}]a $type\
          carries neither a description nor replacement text - PDF/UA needs\
          -alt or -actualText on every one ([dict get $clauses $type]), and\
          an empty -alt is not one; pass it to \[\$doc structure $type\], or\
          to \[\$doc text -tag $type\] where the tag was derived"
    }
    return $problems
  }

  # The page an element first appears on, counted from 1, or {} for an
  # element that has no content of its own anywhere - a placeholder a link
  # points at. Depth first, because a Figure holding only a Caption and an
  # image has its marks one level down.
  #
  # The kid of an element is {element id} or {mark page mcid y} (see
  # [StructureAttach] in structure.tcl); the page in a mark is the index, as
  # everywhere in the state, and becomes a page number here - the number the
  # caller counts pages by is what a message has to name.
  method UaElementPage {elements index} {
    foreach kid [dict get [lindex $elements $index] kids] {
      switch -- [lindex $kid 0] {
        mark {
          return [expr {[lindex $kid 1] + 1}]
        }
        element {
          set page [my UaElementPage $elements [lindex $kid 1]]
          if {$page ne {}} {
            return $page
          }
        }
      }
    }
    return {}
  }

  # A list says how it is numbered, or that it is not (7.6, Matterhorn 16-001):
  # ListNumbering is mandatory on an ordered list, and a label a reader
  # cannot name is a number it cannot read out. Two directions, because the
  # attribute and the Lbl elements have to agree - a list numbered Decimal
  # whose items carry no Lbl claims numbers that are not there, and items
  # with a Lbl under a list that says nothing leave the reader guessing what
  # the labels are.
  #
  # The facts come from [structureReport], one entry per L; judged here.
  method UaCheckLists {} {
    if {![my tagged]} {
      return {}
    }
    set problems {}
    set index 0
    foreach list [dict get [my structureReport] lists] {
      incr index
      dict with list {}
      if {$numbering ni {{} None} && $labelled < $items} {
        lappend problems "list $index is numbered $numbering but\
            [expr {$items - $labelled}] of its $items items\
            [expr {$items - $labelled == 1 ? {carries} : {carry}}] no Lbl -\
            put the number in \[\$doc structure Lbl\] inside each LI (7.6)"
      } elseif {$numbering eq {} && $labelled} {
        lappend problems "list $index: its items carry a Lbl but the list\
            says no -numbering - name it (Decimal, Disc, ...) or None on\
            \[\$doc structure L\] (7.6, Matterhorn 16-001)"
      }
    }
    return $problems
  }

  # A link has to say where it goes in words (7.18.5) - "link" and nothing
  # else is what a reader announces otherwise. The fact comes from link.tcl;
  # the document may have no links at all, and then the module was never
  # loaded and there is nothing to ask.
  #
  # Asked of [state links], the record link.tcl keeps of the links it made,
  # and not of [state annots], which holds an indirect reference per
  # annotation of every kind - a note, a stamp, a widget, a signature. A
  # document whose only annotation is a note has no links, and this used to
  # walk into the two questions all the same; what came back depended on
  # whether the note's own text happened to contain the words "/Subtype
  # /Link". See [LinkRecord] in link.tcl.
  method UaCheckLinks {} {
    if {[my state links] eq {}} {
      return {}
    }
    set problems {}
    set missing [my linksWithoutContents]
    if {[llength $missing]} {
      lappend problems "[llength $missing] link annotation[expr {[llength $missing] == 1 ?
          {} : {s}}] without a description, on page [join [lsort -unique -integer \
          $missing] {, }] - PDF/UA needs Contents on every one (7.18.5); pass\
          -tooltip to \[\$doc link\]"
    }
    # And inside a Link element (UA-1 7.18.5, Matterhorn 28-011: veraPDF
    # fails a link annotation that is not), which is where the description
    # is read from as well; UA-2 (8.2.5.20) lets a Reference do too. The fact
    # comes from link.tcl again; a link drawn outside any element, or inside
    # a P, is in neither.
    set two [expr {[dict get [my state ua] part] == 2}]
    set outside [expr {[my tagged] ?
        [my linksWithoutElement [expr {$two ? {Link Reference} : {Link}}]] : {}}]
    if {[llength $outside]} {
      lappend problems "[llength $outside] link annotation[expr {[llength $outside] == 1 ?
          { is} : {s are}}] not inside a Link structure element, on page\
          [join [lsort -unique -integer $outside] {, }] - PDF/UA wants every\
          one nested in a Link[expr {$two ? { or a Reference} : {}}]\
          ([expr {$two ? {8.2.5.20} : {7.18.5}}]); draw the text and the\
          link inside \[\$doc structure Link -script ...\]"
    }
    return $problems
  }

  # The form. Three rules, and all three are about the same thing: a widget
  # annotation is a control someone operates without seeing it, so it has to
  # say what it is and it has to sit somewhere in the reading order.
  #
  # The facts come from field.tcl, which owns the field table; what is UA's
  # own is the objection. A form with no description at all is perfectly
  # legal in a document that makes no claim, which is why none of this is
  # refused at [$doc field ...].
  #
  # There is no check for the Form structure element itself beyond the third
  # one: the core makes one per widget for every field of a tagged document
  # (see [FieldStructure] in field.tcl), so the only way a widget ends up
  # outside the tree is a field declared before [$doc tagged 1].
  method UaCheckFields {} {
    if {[my state fields] eq {}} {
      return {}
    }
    set problems {}
    # /TU, the accessible name of the field. ISO 32000-2, 14.9.3: an
    # alternative name "shall be used in place of the actual field name" and
    # "shall be specified using the TU entry"; ISO 14289-1, 7.18.1 makes an
    # alternative description mandatory for every annotation that has no
    # Contents. Refused rather than filled in with the field name, which is
    # the one thing 14.9.3 says the alternative name replaces - and a form
    # whose fields announce themselves as "iban" and "plz2" is the reason
    # the standard has the entry at all.
    set missing [my fieldsWithoutDescription]
    if {[llength $missing]} {
      lappend problems "[join $missing {, }] [expr {[llength $missing] > 1 ?
          {are form fields} : {is a form field}}] without a description -\
          PDF/UA reads /TU as the field's accessible name (7.18.1 with ISO\
          32000-2, 14.9.3), and the field name is not it; pass -tooltip to\
          \[\$doc field\]"
    }
    # /Contents or a Lbl per WIDGET, and PART 2 ONLY. ISO 14289-2, 8.10.2.3
    # asks for it of every widget; ISO 14289-1 has no such clause and is
    # content with the field's /TU (7.18.1), which is measured and not
    # assumed - veraPDF 1.30 passes a UA-1 form whose widgets carry neither.
    # Demanding it under part 1 as well would be this package inventing a
    # rule, which is the one thing a conformance check may not do.
    if {[dict get [my state ua] part] == 2} {
      set widgets [my fieldWidgetsWithoutDescription]
      if {[llength $widgets]} {
        set named [lmap entry $widgets {
          expr {[lindex $entry 1] eq {} ? [lindex $entry 0] :
              [format "%s widget %d" [lindex $entry 0] \
                  [expr {[lindex $entry 1] + 1}]]}
        }]
        lappend problems "[join $named {, }] [expr {[llength $named] > 1 ?
            {have} : {has}}] neither a label nor a description - PDF/UA-2\
            wants one or the other on every widget annotation (8.10.2.3), and\
            the field's /TU is not it (8.10.2.4). Pass -label {script} to draw\
            the label into the widget's own Form element, or -contents to\
            describe it; the buttons of \[\$doc field radio\] take theirs\
            inside their own entry of -buttons, as the third word or as\
            -contents, and their label as that entry's -label"
      }
    }
    # And in the tree. A widget outside it is invisible to a reader that
    # follows the structure, and veraPDF says so: ISO 14289-1, 7.18.4 test 1,
    # "A Widget annotation shall be nested within a Form tag".
    set outside [my fieldsOutsideStructure]
    if {[llength $outside]} {
      lappend problems "[join $outside {, }] [expr {[llength $outside] > 1 ?
          {are form fields} : {is a form field}}] whose widgets are outside\
          the structure tree - every one is enclosed by a Form structure\
          element (7.18.4; ISO 14289-2, 8.10.1), and the package makes it at\
          the call that declares the field. A field declared before \[\$doc\
          tagged 1\] misses it; move the switch up, right after \[tclpdf new\]"
    }
    return $problems
  }

  # UA-2 only: every file specification needs a Desc (8.2.5.11). UA-1 does
  # not ask, so an attachment without one stays legal there - and a ZUGFeRD
  # invoice, which is UA-1 at most, is not caught by this.
  method UaCheckAttachments {} {
    if {[dict get [my state ua] part] != 2 || [my state attachments] eq {}} {
      return {}
    }
    set missing [my attachmentsWithoutDescription]
    if {![llength $missing]} {
      return {}
    }
    return [list "[join $missing {, }] [expr {[llength $missing] > 1 ?
        {are attachments} : {is an attachment}}] without a description -\
        PDF/UA-2 needs Desc on every file specification (8.2.5.11); pass\
        -description to \[\$doc attach\]"]
  }

  # The two rules that need the whole tree. Read through [structureReport],
  # which answers with facts and judges nothing - the judging is here, because
  # it is UA that objects and not the tree.
  method UaCheckStructure {} {
    if {![my tagged]} {
      return {}
    }
    set report [my structureReport]
    set problems {}
    set previous 0
    foreach level [dict get $report headings] {
      if {$previous == 0 && $level != 1} {
        lappend problems "the first heading is an H$level - PDF/UA wants an\
            H1 first (7.4.2)"
      } elseif {$level > $previous + 1} {
        lappend problems "a heading jumps from H$previous to H$level - no\
            level may be skipped (7.4.2)"
      }
      set previous $level
    }
    # H means "a heading at whatever level the nesting implies". 2.0 dropped
    # it because the nesting rarely says what the author meant - H1 to Hn are
    # unambiguous - so part 2 refuses it outright. Part 1 keeps it, but not
    # beside the numbered ones: a document is either weakly structured (H
    # throughout, the nesting speaks) or strongly structured (H1 to Hn), and
    # in a mixture the two answers can disagree. Measured 2026-08-18 with
    # veraPDF: ua1 fails the mixture with two checks under 7.4.4 (Matterhorn
    # 14-006) and passes a tree of H alone.
    if {"H" in [dict get $report types]} {
      if {[dict get [my state ua] part] == 2} {
        lappend problems "the tree uses the generic H - PDF/UA-2 wants a\
            numbered heading, H1 to Hn (8.2.5.20)"
      } elseif {[llength [dict get $report headings]]} {
        lappend problems "the tree mixes the generic H with numbered\
            headings - a document is either weakly structured (H throughout)\
            or strongly structured (H1 to Hn), never both (7.4.4, Matterhorn\
            14-006)"
      }
    }
    # UA-2 as well: Note is a 1.7-only type, and 8.2.5.14 wants it gone
    # unless a role map says what it is - FENote is what 2.0 calls it.
    if {[dict get [my state ua] part] == 2 && "Note" in [dict get $report types]} {
      lappend problems "the tree uses Note - PDF/UA-2 wants FENote, the 2.0\
          name for it (8.2.5.14)"
    }
    # The width of a row is the number of COLUMNS it covers, spans counted
    # (Matterhorn 15-003, UA-2 8.2.5.26): a cell with -colSpan 2 is two of
    # them, and a cell spanning down from the row above is one the row
    # below does not draw. [structureReport] does that arithmetic; a table
    # whose rows still differ is one no reader can lay out as a grid.
    set index 0
    foreach widths [dict get $report rows] {
      incr index
      if {[llength [lsort -unique $widths]] > 1} {
        lappend problems "table $index has rows of [join [lsort -unique \
            $widths] { and }] columns - PDF/UA needs every row to cover the\
            same number, spans counted (7.5, Matterhorn 15-003). Fill the\
            short rows, or draw it as separate tables"
      }
    }
    return $problems
  }

}

package provide tclpdf::ua 1.6