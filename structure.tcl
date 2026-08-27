#
# tclpdf - PDF generation for Tcl
#
# structure - the logical tree a reader needs and a page does not show
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc tagged 1
#   $doc structure Sect -script {
#     $doc structure H1 -script { $doc text "Annual report" -at {20 30} }
#     $doc text $paragraph -at {20 45} -width 170       ;# becomes P
#   }
#
# A tagged document carries a second, invisible layer: a tree saying what the
# marks on the page ARE - a heading, a paragraph, a table cell - rather than
# how they look. The drawing is unchanged to the point; nothing here moves a
# glyph.
#
# Who needs it: reading software, which without the tree follows the order the
# content stream happens to have - across both columns of a two column page.
# From that follow PDF/UA and PDF/A level A, and with them the accessibility
# rules public bodies increasingly have to meet.
#
# The mechanics are two halves that meet by number (ISO 32000-1 14.7):
#
#   - in the content stream, every piece of marked content is bracketed
#     "/P <</MCID 0>> BDC ... EMC". The number is unique PER CONTENT STREAM,
#     not per document.
#   - in the catalogue, StructTreeRoot holds the tree, and its leaves point
#     back at those numbers. A page carries StructParents, an index into the
#     ParentTree, whose entry is an array indexed BY MCID.
#
# Which is why the counter lives per page here, and why the tree is built as
# the document is drawn but turned into objects at write time - the same
# reasoning outline.tcl gives for bookmarks.
#
# What is derived and what has to be said: a table knows it is a table, and a
# paragraph knows it is a paragraph, so those tag themselves. A single line of
# text does not know whether it is a heading - that is what -tag is for. A
# guessed tree is worse than none, because reading software follows it without
# question.
#
# This module builds the tree while the document is drawn - and only that.
# Three neighbours hold what is a topic of its own: structureWrite.tcl turns
# the tree into objects at write time, structureReport.tcl gives an account of
# the finished tree for the UA checks, and structureDest.tcl builds the GoTo
# action a link or a bookmark uses to point at an element. The type tables
# below are shared with them under ::tclpdf::structure.
#
# EVERY REFUSAL CARRIES A CODE, and all four files share one space: a caller
# traps "TCLPDF STRUCTURE ..." whichever of them refused. The message is prose
# and no contract - the code is. Seven classes, cut by what the caller has to
# DO about them:
#
#   TYPE       the word naming the type cannot be used here. The third word
#              is the vocabulary it was measured against: structure (14.8.4
#              and Annex M), artifact or subtype (Tables 330 and 331), tag
#              (what -tag accepts on a drawing call).
#   PLACE      a type the standard knows, in a place it does not allow. The
#              third word is the rule that refused it: parent, child, inline,
#              block, leaf, root, nested, label, duplicate, caption,
#              sequence.
#   ATTRIBUTE  an option's value is wrong, or the option belongs on another
#              type. The third word is the option without its dash: lang,
#              scope, numbering, bbox, colSpan, rowSpan, expansion, ref.
#   VERSION    what was asked for needs a newer PDF version than the document
#              has, and raising it is the whole remedy. The third word is
#              what needs it: type, attribute, destination, ref.
#   NAME       an identifier. The third word is what is wrong with it,
#              duplicate or unknown; the word after it names the namespace -
#              name, this package's handle for destinations, or id, the /ID
#              of 14.7.2.
#   STATE      the document's state refuses the call, not its arguments: not
#              tagged, tagged too late, closed out of order, opened inside a
#              form, resumed while open. The third word is the call at issue:
#              tagged, element, expansion, destination, suspend, resume.
#   ARGUMENT   the call itself is malformed - a missing -script, a [tagged]
#              that got no boolean. The third word is the argument at fault:
#              tagged, script.
#
# WITHIN A CLASS THE THIRD WORD MEANS ONE THING, never two: a trap reading
# [lindex $code 3] gets a placement rule from PLACE and an option name from
# ATTRIBUTE, and nothing that is sometimes a standard's word and sometimes a
# name the caller chose. That mixture is what the font modules were caught
# with, and it makes the code no better than the message.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::structure {
  # The standard structure types of ISO 32000-1 14.8.4, which is the whole of
  # them: this package invents none, and a document using only these needs no
  # RoleMap (TS 32005 5.2).
  #
  # Checked at the call, not to restrict what can be expressed but to catch a
  # typo where it happens - "H7" or "Paragraph" would otherwise travel into
  # the file and surface in a validator hours later, with nothing pointing
  # back at the line that wrote it.
  variable types {
    Document Part Art Sect Div BlockQuote Caption TOC TOCI Index NonStruct
    Private P H H1 H2 H3 H4 H5 H6 L LI Lbl LBody Table TR TH TD THead TBody
    TFoot Span Quote Note Reference BibEntry Code Link Annot Ruby RB RT RP
    Warichu WT WP Figure Formula Form
  }

  # What ISO 32000-2 adds (Annex M). Accepted alongside the list above rather
  # than instead of it, because the two namespaces coexist in one 2.0 tree.
  #
  # DocumentFragment, Aside, Title, Sub, FENote, Em and Strong are the new
  # names; H7 and beyond are new because 2.0 lifted the limit of six. Artifact
  # became a structure type in 2.0 and is deliberately NOT here: in tclpdf an
  # artifact is the statement that something is outside the tree, and letting
  # it into the tree as a type would make one word mean both.
  variable types20 {
    DocumentFragment Aside Title Sub FENote Em Strong
    H7 H8 H9 H10
  }

  # The structure namespace of PDF 2.0 (ISO 32000-2 14.8.6.1), named on every
  # element that lives in it - see [StructureNamespace] in structureWrite.tcl
  # for when a tree names it at all.
  variable namespace20 "http://iso.org/pdf2/ssn"

  # The twelve types that exist ONLY in the 1.7 namespace (TS 32005 Tab. 2/3).
  # In a 2.0 tree they are still usable, but they stay in the default - which
  # IS the 1.7 namespace - while everything else moves to the 2.0 one. So
  # these are exactly the elements that get no /NS. The generic H is one of
  # them: the 2.0 namespace knows only the numbered Hn.
  variable only17 {
    Art BlockQuote TOC TOCI Index Private Quote Note Reference BibEntry Code H
  }

  # What an artifact may call itself (ISO 32000-1 Table 330), and the subtypes
  # a Pagination artifact may add (Table 331). Only Pagination has subtypes;
  # a Layout artifact with one would carry a key no reader knows. Checked at
  # the call, because a misspelt kind is written as a name and validates as
  # an artifact of a type that does not exist.
  variable artifactTypes {Pagination Layout Page Background}
  variable artifactSubtypes {Header Footer Watermark}

  # Types that group other elements instead of holding content of their own.
  # The distinction decides where a mark goes: drawing inside an open Sect
  # must make a P INSIDE it, while drawing inside an open H1 belongs to the
  # H1 itself.
  #
  # NonStruct is one of them, and it was missing until 2026-08-26. It is a
  # grouping element like Div - "a grouping element with no inherent
  # meaning" (ISO 32000-2 Table 364) - so it holds elements and no content
  # of its own; veraPDF says so of the tree that came of it, reporting
  # "Document shall not contain content items" (ISO/TS 32005 Table 5) for a
  # [text ... -tag NonStruct] at the top level. Now the tag is refused where
  # every other grouping type is, and the text becomes a P inside an open
  # NonStruct as it does inside a Div.
  variable containers {
    Document Part Art Sect Div NonStruct TOC TOCI Index L LI Table TR THead
    TBody TFoot
  }

  # Which children a type accepts, for the types where Annex L is strict.
  # Anything not named here takes any child - the point is not to police the
  # whole standard but to catch the four structures that are actually
  # constrained, because a tree that breaks them renders perfectly and fails
  # validation at the recipient.
  #
  # Annex L is formally a 2.0 annex; the Best Practice Guide names it as what
  # the tools check 1.7 files against as well, which is why it applies here.
  #
  # Two of these are enforced by tclpdf itself and would be hard to get wrong
  # - a table builds its own TR and TD. The other two are what a caller
  # assembles by hand, and a list is the one people get wrong: the label goes
  # in Lbl, the text in LBody, and both go in an LI, not next to it.
  variable childrenOf {
    Table {TR THead TBody TFoot Caption}
    THead {TR}
    TBody {TR}
    TFoot {TR}
    TR    {TH TD}
    L     {LI Caption}
    LI    {Lbl LBody}
    Ruby  {RB RT RP}
    Warichu {WP WT}
  }

  # The two types whose content is a fixed SEQUENCE, not a set (ISO 32000-2
  # Table 369): what a Ruby or a Warichu may hold in which order. Membership
  # is checked by childrenOf above when a part is opened; the order and the
  # completeness only when the parent closes, in [StructureCheckSequence] -
  # halfway through the bracket the sequence is legitimately incomplete.
  variable sequenceOf {
    Ruby    {{RB RT} {RB RP RT RP}}
    Warichu {{WP WT WP}}
  }

  # Types that hold text and nothing structural. Annex L forbids a block
  # element inside them - a P inside a P is the standing example, and it is
  # what a nested [structure P] produces without anyone noticing.
  variable leafOnly {
    P H H1 H2 H3 H4 H5 H6 Lbl Span Quote Note Reference BibEntry Code
  }

  # The inline-level types, which a leafOnly element MAY hold after all.
  #
  # The rule above was written as "holds text, not structure" and enforced as
  # such - but Annex L forbids only BLOCK elements there, and the comment on
  # it said so from the start. An emphasised word inside a paragraph is a
  # Strong inside a P and cannot be anything else; refusing it left no way to
  # mark up emphasis at all, and putting the Strong beside the P instead
  # produced a tree veraPDF rejects: "Document shall not contain Strong".
  #
  # Found by the 5.8 example, not by a test - nothing before it had marked up
  # a word rather than a paragraph.
  variable inline {
    Span Quote Note Reference BibEntry Code Link Annot Ruby RB RT RP
    Warichu WT WP Figure Formula Form Em Strong Sub FENote
  }

  # The inline types that are NOTHING BUT inline: inline markup marks up
  # something, and straight under Document or a Sect there is nothing it
  # could be inside of. A Strong at the top level is what veraPDF reports as
  # "Document shall not contain Strong" (ISO 32005 Table 5), and a Span in a
  # Sect as "Sect-Span". Refused where it is opened, like the other parent
  # rules: it needs an ancestor that holds text - a P, a heading, a cell, a
  # Figure - and Div, Part and NonStruct are looked through on the way up,
  # as the validator looks through them (transparent). The grouping types
  # that are no home for it are the containers plus the three below, which
  # hold marks in this package but no inline element in Table 5.
  #
  # Measured against veraPDF ua2 rather than read from the table: Figure,
  # Formula, Form, Link, Annot, Code, Note and FENote pass at the top level
  # and are left out; the parts of a Ruby or a Warichu are held to their
  # parent by parentOf below, to their membership by childrenOf, and to
  # their order by sequenceOf - parentOf alone never checked what a Ruby
  # holds, only where an RB may stand. Reference is the odd one - refused
  # under Document and
  # nowhere else that matters (a TOCI holds one, and 5.5 draws it so), so
  # it is refused at the top level only.
  variable inlineOnly {
    Span Quote BibEntry Ruby Warichu Em Strong Sub
  }
  variable transparent {Div Part NonStruct}
  variable noInlineHome {DocumentFragment Aside BlockQuote}
  variable notAtTop {Reference}

  # THE INLINE-LEVEL TYPES OF ISO 32000-2 14.8.4.5, and the block-level ones
  # of 14.8.4.4: inline markup marks up a run of text, so it holds text,
  # other inline markup and an illustration - never a block. A Table inside
  # a Link is what veraPDF reports as "Link-Table" against ISO/TS 32005
  # Table 5, and it was written without a word until 2026-08-26.
  #
  # This is NOT the [inline] list above, which answers the other question -
  # what a leaf MAY hold. Figure, Formula and Form are inline there because
  # they may sit in a paragraph; they are ILLUSTRATION elements, not inline
  # markup, and a Figure holding a Table is a diagram with a table in it,
  # which veraPDF passes. So they are left out here, and the rule below
  # applies to the inline-level types alone.
  #
  # The leafOnly rule above already refuses a block inside Span, Quote,
  # Note, Reference, BibEntry, Code and Lbl - they hold text. What was open
  # is the rest: Link, Annot, Em, Strong, Sub and the parts of a Ruby or a
  # Warichu, none of which is a leaf and none of which may hold a paragraph.
  #
  # A type that names its own parents (parentOf) is not judged here: a Lbl
  # inside a Note is the footnote's number, not a paragraph in a footnote,
  # and the parent rule has already had its say about it.
  variable inlineLevel {
    Span Quote Note Reference BibEntry Code Link Annot Ruby RB RT RP
    Warichu WT WP Em Strong Sub
  }
  variable blockLevel {
    P H H1 H2 H3 H4 H5 H6 H7 H8 H9 H10 L LI Lbl LBody Table TR TH TD
    THead TBody TFoot Caption
  }

  # Types that may not stand inside themselves, at any depth. An Art is a
  # complete piece of writing (ISO 32000-1 14.8.4.3.2, ISO/TS 32005 Table 5
  # gives Art no Art among its children): one inside another says both are
  # complete, and veraPDF reports "Art-Art" against a tree that does it.
  # Checked against the ANCESTORS, not the parent - an Art in a Sect in an
  # Art is the same claim with a step in between.
  variable notInSelf {Art}

  # Where a derived P is not allowed but the right answer is obvious. Text
  # drawn in an open LI IS the list item's body; demanding an explicit LBody
  # for it would be correct and useless - the caller has already said this is
  # a list item, and there is nothing else it could be.
  #
  # Only LI qualifies. Text drawn straight into an L or a Table is a genuine
  # mistake with no single right reading, and stays an error.
  variable contentChildOf {
    LI LBody
  }

  # THE BRACKET IS A TRANSACTION, and these are the keys it saves and puts
  # back. A [structure ... -script] whose body fails leaves the tree as it
  # was - the element, the children the body managed to open, the names and
  # the ids they claimed - so that a refusal the caller traps costs the
  # document nothing.
  #
  # THE COMMIT BOUNDARY IS THE CONTENT STREAM, and it is not a choice: what
  # a page already carries cannot be taken back. A mark is two halves that
  # meet by number (ISO 32000-1 14.7) - "/P <</MCID 3>> BDC" in the stream
  # and a kid in the tree - and dropping the tree half alone would leave a
  # number in the page that the ParentTree does not answer: content a reader
  # neither finds in the tree nor knows to skip (ISO 14289-1 7.1). An OBJR
  # is the same bargain one step further out - the annotation carries a
  # /StructParent naming an entry that would be gone (14.7.5.4). So:
  #
  #   nothing reached the stream, no annotation joined  ->  undo it all
  #   anything did                                      ->  keep it all
  #
  # and the second half is said out loud in the manual: an element whose
  # body drew something before it failed stays, with what it drew.
  #
  # Measured from the state rather than by walking the subtree, because the
  # three facts ARE the three payments: a mark is a number claimed from the
  # per-page counter (structureMcid), an annotation is an entry in
  # structureAnnots, and a structure destination is a reservation the write
  # resolves against the names (structureDestinations) - a name dropped
  # under it would fail the write with "no structure element named".
  variable transactionKeys {
    structure structureStack structureNames structureIds structureAnnots
    structureMcid structureExpansionSpan structureInArtifact
    structureDestinations
  }
  variable commitKeys {structureMcid structureAnnots structureDestinations}

  # Attributes an element can carry, as option name -> {owner key kind}.
  #
  # An attribute is not a key of the element dictionary but lives in an
  # attribute object under /A, labelled with the OWNER it belongs to - a
  # standard-attribute class, of which three matter here (14.8.5). The owner
  # is not decoration: two owners may use the same name for different things,
  # and a reader that finds Scope without one cannot tell which it is.
  #
  # All five are here because PDF/UA asks for them, and each is a value the
  # writer either knows or cannot guess:
  #
  #   scope      TH only, and formally a "should" (UA-1 7.4.5) that the tools
  #              read strictly. The table sets it: a head row is a column
  #              header, which is the one case that is certain.
  #   numbering  mandatory on an ordered list (UA-1 7.6), and never derivable
  #              - the label is drawn text, and "1." and "-" look the same to
  #              a writer.
  #   bbox       Figure, Formula, Table. Not required by the letter of the
  #              standard, named by the Best Practice Guide as what the tools
  #              rely on.
  #   colSpan    written by the table when a cell spans, so that a reader can
  #   rowSpan    rebuild the grid without measuring anything.
  variable attributes {
    scope     {Table Scope name}
    numbering {List ListNumbering name}
    bbox      {Layout BBox rectangle}
    colSpan   {Table ColSpan number}
    rowSpan   {Table RowSpan number}
  }

  # The values the two name attributes accept. A misspelling here is the
  # quiet kind of mistake: the file stays valid and the reader ignores the
  # attribute, so a list reads as unordered forever.
  #
  # The numbering styles are those of ISO 32000-1 Table 347. ISO 32000-2
  # (Table 369) added three, and those are kept apart below: written into a
  # 1.7 file they would be a value no 1.7 reader knows, silently ignored -
  # the same quiet mistake as a misspelling, in a file that validates.
  variable attributeValues {
    scope     {Row Column Both}
    numbering {None Disc Circle Square Decimal
               UpperRoman LowerRoman UpperAlpha LowerAlpha}
  }
  variable attributeValues20 {
    numbering {Unordered Description Ordered}
  }

  # Which types an attribute is allowed on. Checked because the attribute is
  # silently ignored otherwise - a Scope on a TD is not an error anywhere,
  # it simply does nothing.
  variable attributeOn {
    scope     {TH}
    numbering {L}
    bbox      {Figure Formula Table}
    colSpan   {TH TD}
    rowSpan   {TH TD}
  }

  # The other direction: types that exist only inside one particular parent.
  # Without this a lone LI or a TD outside any table passes, because the
  # child rule above only ever asks what a parent MAY hold - never whether
  # this child had any business being there.
  #
  # A Lbl is at home in a list item, but a Note carries one as well - the
  # footnote number (ISO 32000-1 14.8.4.3.3) - and so does its 2.0 successor
  # FENote (ISO 32000-2 Table 368). The FORM is not in the list and belongs
  # in it just as much - ISO 14289-2, 8.10.2.2 puts a widget's label inside
  # the widget's own Form element, and a group's label beside it - but that
  # rule cannot be written as a list of parent types, because a Form sits in
  # almost anything and so therefore does a group's label. It is
  # [StructureLabelHome] instead, and it covers the Form as well: naming it
  # here too would be the same rule in two places.
  #
  # A Caption has four homes and no more (ISO/TS 32005 Table 5): the table
  # or the list it names, and the illustration it explains. Outside them it
  # captions nothing - veraPDF reports a [text ... -tag Caption] at the top
  # level as "Document-Caption" - and the place it takes INSIDE a Table or
  # an L is a second rule, kept where a bracket can be looked at whole:
  # [StructureCheckCaption].
  variable parentOf {
    LI    {L}
    Lbl   {LI Note FENote}
    LBody {LI}
    Caption {Table L Figure Formula}
    TR    {Table THead TBody TFoot}
    TH    {TR}
    TD    {TR}
    THead {Table}
    TBody {Table}
    TFoot {Table}
    RB    {Ruby}
    RT    {Ruby}
    RP    {Ruby}
    WT    {Warichu}
    WP    {Warichu}
  }
}

oo::define ::tclpdf::document::document {

  # $doc tagged ?0|1?  -> whether the document writes a structure tree
  #
  # Off by default, and deliberately: the brackets change EVERY content
  # stream, so switching it on by default would make every document come out
  # different from the release before. That happened once with kerning, as a
  # conscious decision; here there is nothing to gain from it.
  method tagged {args} {
    if {![llength $args]} {
      set value [my state tagged]
      return [expr {$value eq {} ? 0 : $value}]
    }
    if {[llength $args] > 1} {
      return -code error -errorcode [list TCLPDF STRUCTURE ARGUMENT tagged] \
          "tclpdf: tagged takes at most one value"
    }
    set value [lindex $args 0]
    if {![string is boolean -strict $value]} {
      return -code error -errorcode [list TCLPDF STRUCTURE ARGUMENT tagged] \
          "tclpdf: tagged takes a boolean, not \"$value\""
    }
    set value [expr {$value ? 1 : 0}]
    if {$value && [my state tagged] ne "1"} {
      # Before anything is drawn, and refused otherwise: the brackets go into
      # the content stream as it is written, so whatever a page already
      # holds would stay unmarked in a file whose MarkInfo says the opposite
      # - content a reader neither finds in the tree nor knows to skip. A
      # page that exists but holds nothing yet is fine.
      for {set index 0} {$index < [my page count]} {incr index} {
        if {[my page content $index] ne {}} {
          return -code error -errorcode [list TCLPDF STRUCTURE STATE tagged] \
              "tclpdf: tagged 1 has to come before anything is\
              drawn - page [expr {$index + 1}] already has content, and\
              content drawn before the switch would stay outside the tree.\
              Call \[\$doc tagged 1\] right after \[tclpdf new\]"
        }
      }
      # Tagged PDF - MarkInfo, StructTreeRoot, BDC with an MCID - is PDF 1.4
      # (Reference 1.7, 10.6 and Table 3.25).
      my RequireVersion 1.4 "tagged"
      # beforeWrite, not catalog: the pages are written BEFORE the catalogue
      # event fires, and each of them needs the StructParents index this
      # produces. Subscribing to catalog like outline.tcl does left every page
      # without it - measured, not foreseen.
      my onSelf beforeWrite StructureWrite
    }
    my state tagged $value
    return $value
  }

  # $doc structure <type> ?-alt text? ?-lang tag? ?-title text?
  #                       ?-actualText text? ?-expansion text? ?-ref names?
  #                       -script body
  #
  # Opens an element, runs the body with it open, and closes it again -
  # whatever the body does. The bracket form is the one [form create] and
  # [pattern create] already use, and it is the reason a half open tree
  # cannot reach the file: an error inside the body still closes the element
  # before it travels on.
  method structure {type args} {
    set options [::tclpdf::option parse {
      alt {} lang {} title {} actualText {} expansion {} script {} name {}
      id {} ref {} scope {} numbering {} bbox {} colSpan {} rowSpan {}
    } $args "structure"]
    # Missing, not empty: an element with nothing in it is a legitimate thing
    # to ask for - a placeholder a link points at, an L that is filled later
    # - and [option parse] cannot tell an empty -script from an absent one,
    # so the arguments themselves are asked, the way [configure] asks them
    # about -orientation.
    if {"script" ni [lmap {option value} $args {string trimleft $option -}]} {
      return -code error -errorcode [list TCLPDF STRUCTURE ARGUMENT script] \
          "tclpdf: structure needs -script"
    }
    # NOTHING INSIDE A FORM IS MARKED, and an element that can hold no mark
    # is no element. [form create], [pattern create] and the page-number
    # XObject draw into a content stream of their own, where an MCID would
    # be a number the page does not have - so [StructureMark] returns
    # nothing there, by design (see the suspend clause there). What was
    # missing is the other half: [structure] itself did not ask, so the
    # element WAS created, landed in the tree with no kids, and a validator
    # counted it. An empty H1 opened inside a form satisfied the PDF/UA
    # rule that a document begins with an H1 - measured with veraPDF, which
    # called the file conformant.
    #
    # Refused rather than quietly passed through: an element opened here is
    # a caller's decision that cannot come true, and the manual has said so
    # since it was written - "nothing inside a form, a pattern or a
    # page-number XObject is marked at all". The remedy is one line up: mark
    # the PLACEMENT, which is what -alt and -artifact on [form place] and
    # [image place] are for.
    if {[my state structureSuspend] eq "1"} {
      return -code error -errorcode [list TCLPDF STRUCTURE STATE suspend] \
          "tclpdf: a structure element cannot be opened inside\
          a form, a pattern or a page-number XObject - nothing drawn there\
          is marked, so the element would stay empty. Describe the\
          PLACEMENT instead (\[\$doc form place ... -alt\] or -artifact 1),\
          or draw the content on the page"
    }
    set script [dict get $options script]
    # Taken BEFORE the element is opened, so that the undo reaches the
    # element itself and not only what the body did with it - see
    # [StructureRollback] and the transaction comment beside transactionKeys.
    set snapshot [my StructureSnapshot]
    set id [my StructureOpen $type $options]
    set code [catch {uplevel 1 $script} result outcome]
    my StructureClose $id
    if {$code} {
      my StructureRollback $snapshot
      return -options $outcome $result
    }
    # Judged once the body is through and only then: an error from inside
    # has already said what went wrong, and a caption complaint on top of it
    # would hide the cause.
    my StructureCheckCaption $id
    my StructureCheckSequence $id
    # The BODY's result, not the element id: this wraps calls that return
    # something the caller needs - [table] answers with the y coordinate
    # below the table, and swallowing it would break every table in a tagged
    # document.
    return $result
  }

  # $doc structureResume <name> -script body
  #
  # Makes an element that is ALREADY in the tree current again, so that a
  # caller drawing in several passes can hang further children on it.
  #
  # Why it exists: a table broken across columns (-horizontalBreak) draws
  # every row of the first column group, then every row of the second - so
  # the cells of the second group belong to rows that were closed pages ago.
  # Without this the tree came out as twice as many rows, half as wide, with
  # a second heading row in the middle: a shape no reader can lay out, and
  # ISO 32000-1 14.8.4.3.4 says a TR holds the cells of THAT row. The same
  # need turns up wherever content that belongs together is drawn in two
  # passes.
  #
  # THE BRACKET IS THE SAME PROMISE [structure] makes: what is opened here
  # is closed again, whatever the body does. Nothing else is repeated - the
  # element keeps the type, the attributes and the page it was opened with,
  # and its place in the tree was judged when it was created. What IS judged
  # again is everything drawn inside: a child opened now goes through
  # [StructureCheckNesting] exactly as it would have on the first pass.
  #
  # The children keep their own pages. An element whose kids sit on several
  # pages is what [text -paginate] already produces, and structureWrite.tcl
  # writes it: no /Pg on the element, each mark as a marked-content
  # reference naming its page (14.7.4.2), each child element carrying its
  # own. So a row with cells on two pages needs nothing further here.
  #
  # The handle is the -name of the element, or its /ID from -id - the two
  # handles this package already has. A module that made the element itself
  # holds the id [StructureOpen] answered and calls [StructureResume] with
  # it, which is the same bracket without the lookup.
  method structureResume {handle args} {
    set options [::tclpdf::option parse {script {}} $args "structureResume"]
    # Missing, not empty, the way [structure] asks it: resuming an element
    # to draw nothing is a call with no purpose, but an empty -script is a
    # legitimate one to write.
    if {"script" ni [lmap {option value} $args {string trimleft $option -}]} {
      return -code error -errorcode [list TCLPDF STRUCTURE ARGUMENT script] \
          "tclpdf: structureResume needs -script"
    }
    set named [my state structureNames]
    if {[dict exists $named $handle]} {
      set id [dict get $named $handle]
    } elseif {[dict exists [my state structureIds] $handle]} {
      set id [dict get [my state structureIds] $handle]
    } else {
      return -code error -errorcode \
          [list TCLPDF STRUCTURE NAME unknown name] \
          "tclpdf: no structure element is named \"$handle\" -\
          structureResume takes the -name an element was opened with, or\
          its -id. Name one with \[\$doc structure <type> -name $handle\
          ...\]"
    }
    # TAILCALL, so that the body runs in the caller's scope. [uplevel 1] in
    # the worker would otherwise reach this method's frame rather than the
    # one that wrote the script - and the bracket has to behave like
    # [structure]'s, which evaluates the body where it was written. The
    # alternative was the same five lines of bracket in two places.
    tailcall my StructureResume $id [dict get $options script]
  }

  # The bracket itself, on the id [StructureOpen] answered - what a module
  # that made the element calls, and what [structureResume] tailcalls into.
  method StructureResume {id script} {
    set elements [my state structure]
    if {![string is integer -strict $id] || $id < 0
        || $id >= [llength $elements]} {
      return -code error -errorcode [list TCLPDF STRUCTURE STATE resume] \
          "tclpdf: no structure element \"$id\" - the id is\
          the one \[StructureOpen\] answered with, and this document has\
          [llength $elements]"
    }
    # Nothing inside a form, a pattern or a page-number XObject is marked,
    # so an element resumed there would gather nothing - the refusal
    # [structure] makes for the same reason, in the same words.
    if {[my state structureSuspend] eq "1"} {
      return -code error -errorcode [list TCLPDF STRUCTURE STATE suspend] \
          "tclpdf: a structure element cannot be resumed inside\
          a form, a pattern or a page-number XObject - nothing drawn there\
          is marked, so nothing would reach the element. Describe the\
          PLACEMENT instead (\[\$doc form place ... -alt\] or -artifact 1),\
          or draw the content on the page"
    }
    # An element that is open cannot be opened a second time: the stack is
    # what says which element a mark belongs to, and one that stood on it
    # twice would be closed once and stay behind on it - every mark from
    # there on would join an element the caller thinks is finished.
    if {$id in [my state structureStack]} {
      return -code error -errorcode [list TCLPDF STRUCTURE STATE resume] \
          "tclpdf: this [dict get [lindex $elements $id] type] is open\
          already - an element is resumed after it was closed, not inside\
          itself"
    }
    # A LEAF GETS A FURTHER MARK, NOT A FURTHER CHILD. What a P, a heading
    # or a Lbl holds is text, and text drawn for an element that already
    # exists is [StructureMarkAgain]'s road - the one a paragraph carried
    # over a page break by [text -paginate] takes, which keeps ONE element
    # with a mark on each page. Resuming a leaf would open a second way to
    # the same place, and the two would not agree about what the mark
    # belongs to.
    variable ::tclpdf::structure::leafOnly
    set type [dict get [lindex $elements $id] type]
    if {$type in $leafOnly} {
      return -code error -errorcode [list TCLPDF STRUCTURE PLACE leaf] \
          "tclpdf: a $type holds text, and further text for an\
          element that exists is a further mark on it, not a further child -\
          \[\$doc text -paginate 1\] does that for a paragraph carried over\
          a page break. Resume a grouping element instead"
    }
    # The resumed pass is a transaction of its own, on the same commit
    # boundary [structure]'s bracket keeps: the element was there before and
    # stays, but the children this pass opened and the names they claimed go
    # again when the pass gathered no mark, no OBJR and no destination.
    set snapshot [my StructureSnapshot]
    my state structureStack [linsert [my state structureStack] end $id]
    set code [catch {uplevel 1 $script} result outcome]
    my StructureClose $id
    if {$code} {
      my StructureRollback $snapshot
      return -options $outcome $result
    }
    # Judged with everything the element holds NOW, which is why it runs
    # again on every resume rather than once: a Caption appended on the
    # second pass is a Caption in the wrong place, and only this pass can
    # see it.
    my StructureCheckCaption $id
    my StructureCheckSequence $id
    return $result
  }

  # Open an element and make it the current one. Returns its id.
  method StructureOpen {type {options {}}} {
    variable ::tclpdf::structure::types
    variable ::tclpdf::structure::types20
    if {$type ni $types && $type ni $types20} {
      return -code error -errorcode [list TCLPDF STRUCTURE TYPE structure] \
          "tclpdf: unknown structure type \"$type\" - the\
          standard types of ISO 32000-1 14.8.4 are: [join [lsort $types] {, }];\
          ISO 32000-2 adds [join [lsort $types20] {, }]"
    }
    # A 2.0-only type in a file that is not 2.0 would be written, validate as
    # a non-standard type without a role map, and mean nothing to a reader.
    if {$type in $types20 && $type ni $types} {
      if {[package vcompare [[my writer] version] 2.0] < 0} {
        return -code error -errorcode [list TCLPDF STRUCTURE VERSION type] \
            "tclpdf: \"$type\" is a structure type of ISO\
            32000-2 and this document is PDF [[my writer] version] - raise\
            the version, or use \[\$doc ua -part 2\], which does it"
      }
      # Accepted - so the floor is pinned with the writer: a later
      # [configure -version 1.7] is refused naming the type, instead of
      # writing a 1.7 file that carries it after all.
      my RequireVersion 2.0 "the structure type $type"
    }
    my StructureCheckNesting $type
    variable ::tclpdf::structure::attributes
    foreach key [list alt lang title actualText expansion id name ref \
        {*}[dict keys $attributes]] {
      if {![dict exists $options $key]} {
        dict set options $key {}
      }
    }
    # Every check first, every registration last: a refused call must leave
    # the state as if it had never happened. Until 2026-08-18 the name was
    # claimed before the id was checked, and a call refused for a duplicate
    # id left its name behind, pointing at whatever element came next.
    #
    # A name makes the element referable - see [structureDestination].
    set name [dict get $options name]
    if {$name ne {}} {
      set named [my state structureNames]
      if {[dict exists $named $name]} {
        return -code error -errorcode \
            [list TCLPDF STRUCTURE NAME duplicate name] \
            "tclpdf: a structure element named\
            \"$name\" already exists - a name has to be\
            unique, or a link would not know which one it means"
      }
    }
    # Lang is a language tag like the document's (14.9.2): the same shape
    # [language] in document.tcl checks, RFC 3066 - "de", "de-DE", "en-GB".
    # Written unchecked it would reach a screen reader as a voice it cannot
    # pick. The expression is the one [language] uses, spelled a second time
    # because document.tcl keeps it inside that method; the two have to move
    # together.
    set lang [dict get $options lang]
    if {$lang ne {} && ![regexp {^[A-Za-z]{1,8}(-[A-Za-z0-9]{1,8})*$} $lang]} {
      return -code error -errorcode [list TCLPDF STRUCTURE ATTRIBUTE lang] \
          "tclpdf: -lang \"$lang\" is not a language tag -\
          expected something like de, de-DE or en-GB (RFC 3066)"
    }
    if {[dict get $options expansion] ne {}} {
      my StructureExpansionGuard
    }
    # WHAT THIS ELEMENT POINTS AT (/Ref, ISO 32000-2 Table 355): one or more
    # OTHER elements, by the -name they were given. The entry that makes a
    # table of contents usable - PDF/UA-2 8.2.5.8 wants every TOCI to say
    # which section it lists, and until 2026-08-26 this package could not
    # write the key at all, so a UA-2 document with a TOC was never
    # conformant. An index entry and a footnote reference take the same
    # road.
    #
    # A LIST, because the key is an array: one TOCI may list two sections,
    # and a Reference may point at several notes.
    #
    # The names are NOT resolved here. A table of contents is written
    # before the sections it names - the forward reference is the ordinary
    # case, not the exception - so the names travel with the element and
    # structureWrite.tcl turns them into object references once every
    # element has its number, refusing a name nobody created the way a
    # structure destination is refused.
    set ref [dict get $options ref]
    if {$ref ne {}} {
      if {[catch {llength $ref}]} {
        return -code error -errorcode [list TCLPDF STRUCTURE ATTRIBUTE ref] \
            "tclpdf: -ref takes the -name of an element, or a\
            list of them - \"$ref\" is not a list"
      }
      foreach target $ref {
        if {$target eq {}} {
          return -code error \
              -errorcode [list TCLPDF STRUCTURE ATTRIBUTE ref] \
              "tclpdf: -ref \"$ref\" holds an empty name - name\
              the target element with \[\$doc structure <type> -name ...\]\
              and pass that name"
        }
      }
      # Ref is an entry of ISO 32000-2 (Table 355) and of no earlier
      # version: written into a 1.7 file it would be a key no reader of that
      # file knows, silently ignored - the quiet mistake this package
      # refuses everywhere, in a file that validates. Same wording as the
      # structure destination's guard, which draws the same line.
      if {[package vcompare [[my writer] version] 2.0] < 0} {
        return -code error -errorcode [list TCLPDF STRUCTURE VERSION ref] \
            "tclpdf: -ref writes the Ref entry of ISO 32000-2\
            (Table 355) and this document is PDF [[my writer] version] -\
            raise the version, or use \[\$doc ua -part 2\], which does it"
      }
      my RequireVersion 2.0 "-ref (the Ref entry of ISO 32000-2 Table 355)"
    }
    set elements [my state structure]
    set stack [my state structureStack]
    set id [llength $elements]
    set parent [expr {[llength $stack] ? [lindex $stack end] : {}}]
    # The element identifier (14.7.2, /ID) - the string a reader looks the
    # element up by in the IDTree; distinct from -name, which is this
    # package's own handle for destinations. -id gives one to any element,
    # and a Note gets one on its own when none was given: PDF/UA-1 asks for
    # it (7.9, "Note tag shall have ID entry"; veraPDF checks) and there is
    # nothing to decide about its value.
    set identifier [dict get $options id]
    if {$identifier eq {} && $type eq "Note"} {
      # COUNTED PAST WHAT IS TAKEN, not derived once and hoped for. The
      # number is the element's position, so "Note7" is a name the CALLER
      # may have written on an unrelated element with -id - and then the
      # Note that happens to land in position 7 was refused for a duplicate
      # nobody could see coming, in a value nobody chose. Measured
      # 2026-08-25: -id Note2 on a paragraph, then a Note, and the Note is
      # turned away. It walks on instead until it finds a free one.
      set known [my state structureIds]
      set serial [expr {$id + 1}]
      while {[dict exists $known "Note$serial"]} {
        incr serial
      }
      set identifier "Note$serial"
    }
    if {$identifier ne {}} {
      set known [my state structureIds]
      if {[dict exists $known $identifier]} {
        return -code error -errorcode \
            [list TCLPDF STRUCTURE NAME duplicate id] \
            "tclpdf: a structure element with the id\
            \"$identifier\" already exists - an id has to be unique in the\
            document (ISO 32000-1 14.7.2)"
      }
    }
    # The attributes are checked as they are turned into objects - the last
    # thing that can refuse.
    set attributeObjects [my StructureAttributes $type $options]

    if {$name ne {}} {
      dict set named $name $id
      my state structureNames $named
    }
    if {$identifier ne {}} {
      dict set known $identifier $id
      my state structureIds $known
    }
    # THE PAGE THE ELEMENT WAS OPENED ON, kept for the one case where it is
    # the only place it has: a container that ends up with no content
    # anywhere below it. A structure destination to such an element used to
    # send a reader to page 0 - not because the element had no place, but
    # because nothing had written the one it did have down. Costs one key.
    lappend elements [dict create type $type parent $parent kids {} \
        page [my page current] \
        alt [dict get $options alt] lang $lang \
        title [dict get $options title] \
        actualText [dict get $options actualText] \
        expansion [dict get $options expansion] id $identifier \
        ref $ref attributes $attributeObjects]
    if {$parent ne {}} {
      set entry [lindex $elements $parent]
      dict lappend entry kids [list element $id]
      lset elements $parent $entry
    }
    my state structure $elements
    my state structureStack [lappend stack $id]
    return $id
  }

  # Turn the attribute options into owner -> pairs, checking each one where
  # the call that set it can still be named. Answers {} when none was given,
  # which is the ordinary case and costs an element nothing.
  method StructureAttributes {type options} {
    variable ::tclpdf::structure::attributes
    variable ::tclpdf::structure::attributeValues
    variable ::tclpdf::structure::attributeValues20
    variable ::tclpdf::structure::attributeOn
    set result {}
    dict for {option definition} $attributes {
      set value [dict get $options $option]
      if {$value eq {}} {
        continue
      }
      lassign $definition owner key kind
      set allowed [dict get $attributeOn $option]
      if {$type ni $allowed} {
        return -code error -errorcode \
            [list TCLPDF STRUCTURE ATTRIBUTE $option] \
            "tclpdf: -$option belongs on [join $allowed { or }],\
            not on a $type - it would be written and then ignored"
      }
      switch -- $kind {
        name {
          set values [dict get $attributeValues $option]
          set values20 [expr {[dict exists $attributeValues20 $option] ?
              [dict get $attributeValues20 $option] : {}}]
          if {$value in $values20
              && [package vcompare [[my writer] version] 2.0] < 0} {
            # Written into a 1.7 file it would be a value no reader of that
            # file knows and ignore - the quiet mistake this check exists
            # for, in a file that validates.
            return -code error -errorcode \
                [list TCLPDF STRUCTURE VERSION attribute] \
                "tclpdf: -$option $value is a value of ISO\
                32000-2 (Table 369) and this document is PDF\
                [[my writer] version] - in a 1.7 file the values are\
                [join $values {, }]; raise the version, or use\
                \[\$doc ua -part 2\], which does it"
          }
          if {$value ni $values && $value ni $values20} {
            return -code error -errorcode \
                [list TCLPDF STRUCTURE ATTRIBUTE $option] \
                "tclpdf: -$option must be one of\
                [join $values {, }] - not \"$value\"[expr {
                [llength $values20] ? "; ISO 32000-2 adds [join $values20 {, }]"
                : {}}]"
          }
          if {$value in $values20 && $value ni $values} {
            # Accepted - so the floor is pinned with the writer: a later
            # [configure -version 1.7] is refused naming the value, instead
            # of writing a 1.7 file that carries it after all.
            my RequireVersion 2.0 "-$option $value (ISO 32000-2 Table 369)"
          }
          set object /$value
        }
        number {
          if {![string is integer -strict $value] || $value < 1} {
            return -code error -errorcode \
                [list TCLPDF STRUCTURE ATTRIBUTE $option] \
                "tclpdf: -$option takes a positive integer,\
                not \"$value\""
          }
          set object [::tclpdf::pdfObj num $value]
        }
        rectangle {
          if {[llength $value] != 4} {
            return -code error -errorcode \
                [list TCLPDF STRUCTURE ATTRIBUTE $option] \
                "tclpdf: -$option takes four numbers\
                {left top width height}, not \"$value\""
          }
          lassign $value left top width height
          # The four have to be numbers before they are added up. Without
          # this the sum below raised Tcl's own "can't use non-numeric string
          # as operand of +", against the promise that every refusal of this
          # package begins with "tclpdf:" and names what is wrong.
          foreach number $value {
            if {![string is double -strict $number]} {
              return -code error -errorcode \
                  [list TCLPDF STRUCTURE ATTRIBUTE $option] \
                  "tclpdf: -$option takes four numbers\
                  {left top width height} - \"$number\" is not a number"
            }
          }
          lassign [my coords $left [expr {$top + $height}]] x0 y0
          lassign [my coords [expr {$left + $width}] $top] x1 y1
          set object [::tclpdf::pdfObj arr [lmap number [list $x0 $y0 $x1 $y1] {
            ::tclpdf::pdfObj num $number
          }]]
        }
      }
      dict lappend result $owner $key $object
    }
    return $result
  }

  # Refuse a child its parent may not have (Annex L). Checked when the element
  # is opened, so the message points at the line that wrote it - a validator
  # would report it hours later against a file, naming an object number.
  #
  # Only the strict types are checked. Everything else is allowed anything,
  # because guessing at the rest of the standard would refuse trees that are
  # perfectly good.
  method StructureCheckNesting {type} {
    variable ::tclpdf::structure::childrenOf
    variable ::tclpdf::structure::leafOnly
    variable ::tclpdf::structure::inline
    variable ::tclpdf::structure::inlineOnly
    variable ::tclpdf::structure::inlineLevel
    variable ::tclpdf::structure::blockLevel
    variable ::tclpdf::structure::notInSelf
    variable ::tclpdf::structure::parentOf
    set elements [my state structure]
    set stack [my state structureStack]
    set parent [my StructureCurrent]
    set parentType [expr {$parent eq {} ? {} :
        [dict get [lindex $elements $parent] type]}]
    # A Document is the top of a tree and stands nowhere else (ISO/TS 32005
    # Table 5 gives it the root): this package writes the root Document
    # itself (structureWrite.tcl), so a caller's Document is a second one
    # beside it - which veraPDF passes - while one INSIDE a Sect is the
    # "Sect-Document" it refuses. Nothing about the second Document can be
    # made right by what follows it, so it is refused where it is opened.
    if {$type eq "Document" && $parent ne {}} {
      return -code error -errorcode [list TCLPDF STRUCTURE PLACE root] \
          "tclpdf: a Document is the top of a structure tree\
          and belongs under the root, not in a $parentType (ISO/TS 32005\
          Table 5) - use a Part or a Sect for a division of this document"
    }
    if {$type in $notInSelf} {
      foreach id [lreverse $stack] {
        if {[dict get [lindex $elements $id] type] ne $type} {
          continue
        }
        return -code error -errorcode [list TCLPDF STRUCTURE PLACE nested] \
            "tclpdf: an $type is a complete piece of writing\
            and may not stand inside another $type (ISO/TS 32005 Table 5) -\
            close the outer one first, or use a Sect for a division of it"
      }
    }
    if {[dict exists $parentOf $type]} {
      set wanted [dict get $parentOf $type]
      if {$parentType ni $wanted
          && ![my StructureLabelHome $type $parentType]} {
        set where "at the top level"
        if {$parentType ne {}} {
          set where "in a $parentType"
        }
        set message "tclpdf: a $type belongs in [join $wanted { or }],\
            not $where (ISO 32000-2 Annex L)"
        if {$type eq "Lbl"} {
          append message ". A Lbl that labels a form field goes where the\
              field's Form element goes - beside it, in a grouping element\
              that holds both (ISO 14289-2, 8.10.2.2) - and a $parentType is\
              not one: put the label and the field in a Sect, a Div inside\
              one, or a table cell. A Div at the TOP level is not enough,\
              measured: a validator reads through it and reports the Lbl\
              against the Document, which may hold none (ISO/TS 32005,\
              Table 5)"
        }
        return -code error -errorcode [list TCLPDF STRUCTURE PLACE parent] \
            $message
      }
    }
    # THE LABEL COMES FIRST. ISO 32000-1 14.8.4.3.3 describes a list item as
    # a Lbl followed by a LBody, and the order of /K IS the reading order -
    # a Lbl opened after the body is read out as "the body, one point", in
    # that order, by every reader that follows the tree. No validator sees
    # it: veraPDF passes both profiles, and [UaCheckLists] counts the label
    # either way.
    #
    # Any kid at all, not only a LBody: text drawn straight into the LI
    # becomes its body (contentChildOf), so the mark that is already there
    # is the body just as much as an element would be.
    if {$type eq "Lbl" && $parentType eq "LI"
        && [llength [dict get [lindex $elements $parent] kids]]} {
      return -code error -errorcode [list TCLPDF STRUCTURE PLACE label] \
          "tclpdf: the Lbl of a list item is its FIRST child -\
          this LI already holds content, and a label after the body is read\
          out after it (ISO 32000-1 14.8.4.3.3). Open the Lbl before the\
          LBody"
    }
    # Inline markup needs something to be inside of - see inlineOnly.
    variable ::tclpdf::structure::notAtTop
    set home [my StructureInlineHome]
    if {($type in $inlineOnly && $home ne "1")
        || ($type in $notAtTop && $home eq "top")} {
      set where "at the top level"
      if {$parentType ne {}} {
        set where "in a $parentType"
      }
      return -code error -errorcode [list TCLPDF STRUCTURE PLACE inline] \
          "tclpdf: a $type is inline markup and belongs inside\
          an element that holds text - a P, a heading, a cell, a Figure -\
          not $where (ISO 32005 Table 5)"
    }
    if {$parent eq {}} {
      return
    }
    if {[dict exists $childrenOf $parentType]} {
      set allowed [dict get $childrenOf $parentType]
      if {$type ni $allowed} {
        return -code error -errorcode [list TCLPDF STRUCTURE PLACE child] \
            "tclpdf: a $parentType may not contain a $type -\
            it takes [join $allowed {, }] (ISO 32000-2 Annex L)"
      }
      # A Table holds at most ONE THead and ONE TFoot (Annex L gives both
      # the cardinality 0..1); the second is refused where it is opened.
      # veraPDF reports the duplicate only against the finished file,
      # naming an object number - here the message still names the call.
      if {$type in {THead TFoot}} {
        foreach kid [dict get [lindex $elements $parent] kids] {
          if {[lindex $kid 0] eq "element" && [dict get [lindex $elements \
              [lindex $kid 1]] type] eq $type} {
            return -code error -errorcode \
                [list TCLPDF STRUCTURE PLACE duplicate] \
                "tclpdf: this Table already has a $type - a\
                table holds at most one (ISO 32000-2 Annex L)"
          }
        }
      }
      return
    }
    # A type that has just been found in one of the parents it is made for
    # is not the block element this rule is after: a Lbl in a Note is the
    # footnote's number, not a paragraph in a paragraph. Nothing else passes
    # by this clause - a P names no parent, so a P in a P is still refused.
    if {$parentType in $leafOnly && $type ni $inline
        && ![dict exists $parentOf $type]} {
      return -code error -errorcode [list TCLPDF STRUCTURE PLACE leaf] \
          "tclpdf: a $parentType holds text and inline markup,\
          not a $type - close it before starting one (ISO 32000-2 Annex L)"
    }
    # INLINE MARKUP HOLDS NO BLOCK. The leaf rule above says it for the
    # inline types that hold TEXT - a Span, a Quote, a Code; this says it
    # for the ones that hold none of their own and were therefore never
    # asked - a Link, an Annot, an Em, a Strong, a Sub, the parts of a Ruby.
    # A Table inside a Link renders and validates nowhere: veraPDF reports
    # "Link-Table" against ISO/TS 32005 Table 5, and until 2026-08-26 the
    # call was taken and the claim written.
    #
    # LAST of the three, so that a type the leaf rule already knows keeps
    # the message it always had: the two rules overlap on every leaf that is
    # also inline markup, and the leaf's wording is the one the tests and
    # the manual quote.
    #
    # Grouping types are NOT refused here. A Sect inside a Link is odd and
    # veraPDF passes it under both profiles - refusing what the validator
    # allows would be this package inventing a rule, which is the line drawn
    # at [childrenOf] as well. Figure, Formula and Form are left out for the
    # same reason from the other side: they are illustration elements, not
    # inline markup, and a Figure holding a Table is a diagram with a table
    # in it.
    #
    # The parentOf exception is the leaf rule's: a Lbl in a Note is the
    # footnote's number, and its own parent rule has already judged it.
    if {$parentType in $inlineLevel && $type in $blockLevel
        && ![dict exists $parentOf $type]} {
      return -code error -errorcode [list TCLPDF STRUCTURE PLACE block] \
          "tclpdf: a $parentType is inline markup and holds\
          text, inline markup and illustrations - not a $type, which is a\
          block of its own (ISO/TS 32005 Table 5). Close the $parentType\
          first, or put the $type around it"
    }
    return
  }

  # THE SECOND HOME OF A Lbl, and it is the form field's. ISO 14289-2,
  # 8.10.2.2: the text that labels a widget annotation "shall be enclosed in
  # one or several Lbl structure elements", and they sit in the same parent
  # element that holds the widget's Form element - for a group of widgets, in
  # the common parent of all their Form elements. So a Lbl goes wherever a
  # Form goes, which is what this answers, and [parentOf] alone would refuse
  # every one of them: it knows the list Lbl had before form fields existed.
  #
  # "Wherever a Form goes" is narrowed by one step: a Form is inline markup
  # and may sit inside a P, a Lbl is a block and may not, so the pair needs a
  # grouping element - a Div, a Sect, a table cell - to share. That is what
  # the refusal above says, because it is the one thing the caller has to
  # change.
  #
  # Nothing else uses the exception: the answer is 0 for every type but Lbl.
  method StructureLabelHome {type parentType} {
    if {$type ne "Lbl"} {
      return 0
    }
    variable ::tclpdf::structure::childrenOf
    variable ::tclpdf::structure::leafOnly
    return [expr {![dict exists $childrenOf $parentType]
        && $parentType ni $leafOnly}]
  }

  # The type a mark or an expansion takes when it is drawn inside an open
  # CONTAINER that has a content child of its own (contentChildOf): text in
  # an open LI is the item's LBody, whatever [text] was going to call it.
  #
  # ONLY WHERE THE ANSWER IS OBVIOUS, which is the whole of the fix of
  # 2026-08-27. The substitution used to be unconditional, so every -tag in
  # an open LI came out as a second LBody - "structure LI -script { text
  # \"1.\" -tag Lbl; text \"body\" }" gave the item two LBody children and no
  # label at all, and a numbered list without a Lbl is what PDF/UA-1 7.6
  # refuses. The manual (:1178) promised the opposite from the start: a type
  # the open element may not hold is refused naming both.
  #
  # So three tags are substituted and no others: the empty one, the P that
  # [text] passes when nothing was said, and the content child itself. Every
  # other tag is opened under its own name and judged by
  # [StructureCheckNesting], which already knows that a Lbl belongs in an LI
  # (parentOf, and the label-comes-first rule) and that an H2 does not
  # (childrenOf).
  method StructureDerivedIn {open derived} {
    variable ::tclpdf::structure::contentChildOf
    if {![dict exists $contentChildOf $open]} {
      return $derived
    }
    set child [dict get $contentChildOf $open]
    if {$derived in [list {} P $child]} {
      return $child
    }
    return $derived
  }

  # Whether an inline element opened now would sit inside something that
  # holds text: 1 when the nearest open element that is not transparent
  # (Div, Part, NonStruct pass the question up, as ISO 32005 does) is
  # neither a container nor one of noInlineHome; 0 inside a bare Sect, Art,
  # Aside or TOC; and "top" when nothing but transparent elements is open,
  # for the rule that looks at the top level alone.
  method StructureInlineHome {} {
    variable ::tclpdf::structure::containers
    variable ::tclpdf::structure::transparent
    variable ::tclpdf::structure::noInlineHome
    set elements [my state structure]
    foreach id [lreverse [my state structureStack]] {
      set type [dict get [lindex $elements $id] type]
      if {$type in $transparent} {
        continue
      }
      return [expr {$type ni $containers && $type ni $noInlineHome}]
    }
    return top
  }

  # The type of the element that is open right now, or {} when none is - the
  # question a module drawing something asks before deciding whose content
  # it becomes ("is a Figure open?"), answered here so that no other module
  # reads the stack.
  method StructureOpenType {} {
    set current [my StructureCurrent]
    if {$current eq {}} {
      return {}
    }
    return [dict get [lindex [my state structure] $current] type]
  }

  # Attach an annotation to the element that is open, and answer the
  # StructParent index it has to carry. {} when nothing is open or the
  # document is not tagged, which is the caller's signal to write no
  # StructParent at all.
  #
  # An annotation enters the tree as an OBJR - an object reference, not a
  # marked content sequence - because it is not part of any content stream
  # (14.7.5.4). And it uses StructParent, singular: a page has StructParents
  # pointing at an ARRAY indexed by MCID, an annotation has StructParent
  # pointing straight at its element. An object carrying both is invalid, and
  # nothing here does.
  #
  # Annotations are numbered from zero and the PAGES move up behind them,
  # rather than the other way round. It has to be this way: the key goes into
  # the annotation dictionary when the link is drawn, and at that moment the
  # document does not know how many pages it will have.
  #
  # Counting from the pages was the first attempt and it collides. Two pages
  # with one link each gave the links keys 1 and 3 - the first computed when
  # only one page existed - and key 1 was already the second page's. Both
  # then claimed the same ParentTree entry. Found by a test, not by a
  # validator: veraPDF reported nothing.
  # The page is the CURRENT one where the caller names none, which is what a
  # link wants - it is drawn on the page it points from. A widget annotation
  # is not: a field names its page (-page, and -widgets names one per widget),
  # so the page a form field's OBJR has to carry is the field's and not
  # whichever page happens to be open when it is declared.
  method StructureAnnotation {number {page {}}} {
    if {![my tagged]} {
      return {}
    }
    set element [my StructureCurrent]
    if {$element eq {}} {
      return {}
    }
    if {$page eq {}} {
      set page [my page current]
    }
    set annotations [my state structureAnnots]
    set key [llength $annotations]
    lappend annotations [list $element $number $key]
    my state structureAnnots $annotations
    # The page travels with the reference: an OBJR has to name the page its
    # annotation sits on whenever the element itself names none or another
    # (ISO 32000-2 14.7.5.3), and only now is it known which page that is.
    set elements [my state structure]
    set entry [lindex $elements $element]
    dict lappend entry kids [list objr $number $page]
    lset elements $element $entry
    my state structure $elements
    return $key
  }

  # The element an annotation was attached to by [StructureAnnotation], as
  # {id type}, or {} when it was attached to none - drawn outside any
  # element, or before the document was tagged.
  #
  # The ID is wanted beside the type because two questions are asked of the
  # same fact: link.tcl asks WHAT an annotation joined, for the UA rule that
  # a link annotation sits inside a Link, and WHICH element it joined, for
  # the UA-2 rule that one Link element holds one target (8.2.5.20). One
  # walk answers both.
  method StructureAnnotationElement {number} {
    foreach annotation [my state structureAnnots] {
      lassign $annotation element owner
      if {$owner == $number} {
        return [list $element \
            [dict get [lindex [my state structure] $element] type]]
      }
    }
    return {}
  }

  # The type alone, which is what the older of the two questions wants.
  method StructureAnnotationOwner {number} {
    return [lindex [my StructureAnnotationElement $number] 1]
  }

  # THE STATE OF THE TREE, whole, as one value - what a bracket saves before
  # it opens its element. Nine keys, listed once in transactionKeys beside
  # the reasoning; a tenth added later has to be added there and nowhere
  # else.
  #
  # Public in the sense the rest of this package is: a module that opens an
  # element with [StructureOpen] and runs a caller's script around it -
  # table.tcl for a row, field.tcl for a label - takes a snapshot the same
  # way and hands it back to [StructureRollback].
  method StructureSnapshot {} {
    variable ::tclpdf::structure::transactionKeys
    set snapshot {}
    foreach key $transactionKeys {
      dict set snapshot $key [my state $key]
    }
    return $snapshot
  }

  # Put the tree back the way [StructureSnapshot] found it - unless the
  # bracket has been paid for in the content stream. Answers 1 when it undid
  # the work and 0 when it left it standing, so a caller can say which
  # happened.
  #
  # The three keys that decide are commitKeys, and the comment beside them
  # says why those three and no others: an MCID claimed, an OBJR attached or
  # a structure destination reserved is a promise something ELSE in the file
  # already carries, and a tree without its half of it is worse than a tree
  # with an element too many.
  method StructureRollback {snapshot} {
    variable ::tclpdf::structure::transactionKeys
    variable ::tclpdf::structure::commitKeys
    foreach key $commitKeys {
      if {[my state $key] ne [dict get $snapshot $key]} {
        return 0
      }
    }
    foreach key $transactionKeys {
      my state $key [dict get $snapshot $key]
    }
    return 1
  }

  method StructureClose {id} {
    set stack [my state structureStack]
    if {[lindex $stack end] ne $id} {
      return -code error -errorcode [list TCLPDF STRUCTURE STATE element] \
          "tclpdf: structure elements closed out of order"
    }
    my state structureStack [lrange $stack 0 end-1]
    if {$id eq [my state structureExpansionSpan]} {
      my state structureExpansionSpan {}
    }
    return
  }

  # A Caption has a place and a number, not just a parent. ISO 32000-2 Table
  # 372: "The Caption shall be the first or the last structure element inside
  # its parent structure element. The number of captions cannot exceed 1" -
  # and the descriptions of L and Table (14.8.4.8) say the same of those two
  # in their own words. Checked when the element's bracket closes, because
  # only then is it known what else it holds - and still at the call, where
  # the message can name the position rather than an object number. No
  # caption, no complaint.
  #
  # EVERY HOME OF A CAPTION, not two of them. The rule used to read "Table
  # or L", so a Figure or a Formula - the other two parents parentOf gives a
  # Caption, and the ones Table 372 names first - took a caption in the
  # middle and took a second one: measured 2026-08-27, a Figure with two
  # captions passed under ua1 and was failed by veraPDF ua2 (ISO/TS 32005
  # Table 5, "Figure-Caption"). The four homes are read from parentOf, so
  # the two rules cannot drift apart.
  #
  # WHERE "LAST" IS ALLOWED, and it is not one answer for the four. ISO
  # 32000-1 Annex L puts the caption of a Table or an L FIRST, and this
  # package applies Annex L to 1.7 files deliberately (see childrenOf); ISO
  # 32000-2 lets those two stand last as well (14.8.4.8, the L and Table
  # descriptions). Figure and Formula are governed by Table 372 alone, which
  # says "first or the last" and has no earlier rule to contradict - and a
  # caption UNDER a picture is the ordinary shape of one. So the two types
  # Annex L speaks about keep the stricter rule in a 1.7 file, and the two it
  # does not take Table 372's in every file.
  #
  # THE COUNT is not version-dependent at all: "The number of captions cannot
  # exceed 1" (Table 372), and ISO/TS 32005 Table 5 gives all four a Caption
  # 0..1. Asked of every file.
  method StructureCheckCaption {id} {
    variable ::tclpdf::structure::parentOf
    set elements [my state structure]
    set element [lindex $elements $id]
    set type [dict get $element type]
    if {$type ni [dict get $parentOf Caption]} {
      return
    }
    set kids [dict get $element kids]
    set last [expr {$type in {Figure Formula}
        || [package vcompare [[my writer] version] 2.0] >= 0}]
    set where [expr {$last ? "first or last" : "first or, in a 2.0 file, last"}]
    set position 0
    set seen 0
    foreach kid $kids {
      incr position
      if {[lindex $kid 0] ne "element"
          || [dict get [lindex $elements [lindex $kid 1]] type] ne "Caption"} {
        continue
      }
      if {[incr seen] > 1} {
        return -code error -errorcode [list TCLPDF STRUCTURE PLACE caption] \
            "tclpdf: this $type holds $seen Caption elements -\
            a structure element carries at most one, and a second says the\
            first was not the caption after all (ISO 32000-2 Table 372).\
            Put the two texts in one Caption"
      }
      if {$position == 1 || ($last && $position == [llength $kids])} {
        continue
      }
      return -code error -errorcode [list TCLPDF STRUCTURE PLACE caption] \
          "tclpdf: the Caption of a $type has to be its $where\
          child, not child $position of [llength $kids] (ISO 32000-2 Table\
          372)"
    }
    return
  }

  # Ruby and Warichu hold a fixed SEQUENCE, not a set (ISO 32000-2 Table
  # 369, kept in sequenceOf): checked like the Caption's place when the
  # element's bracket closes, because only then is the whole sequence known
  # - and still at the call, where the message can name the position rather
  # than an object number. Only element kids count; a mark drawn straight
  # into a Ruby has no place in Table 369 either, and the mismatch names it.
  # veraPDF ua1 never looks at this - only ua2 does - so a tree that breaks
  # it validates today and fails at the first UA-2 recipient.
  method StructureCheckSequence {id} {
    variable ::tclpdf::structure::sequenceOf
    set elements [my state structure]
    set element [lindex $elements $id]
    set type [dict get $element type]
    if {![dict exists $sequenceOf $type]} {
      return
    }
    set sequence [lmap kid [dict get $element kids] {
      if {[lindex $kid 0] ne "element"} {
        continue
      }
      dict get [lindex $elements [lindex $kid 1]] type
    }]
    set wanted [dict get $sequenceOf $type]
    if {$sequence in $wanted} {
      return
    }
    return -code error -errorcode [list TCLPDF STRUCTURE PLACE sequence] \
        "tclpdf: a $type holds exactly\
        [join [lmap variant $wanted {join $variant +}] { or }]\
        (ISO 32000-2 Table 369) - this one holds [expr {
        [llength $sequence] ? [join $sequence +] : {nothing}}]"
  }

  # The graphics that became artifacts because nobody said otherwise, worded
  # for a refusal: an artifact carries content past a reader entirely, and a
  # picture, drawing or form placed without -alt and without -artifact 1 was
  # never judged either way. Two claims stand on that judgement - PDF/UA
  # (ua.tcl, 7.1/7.3) and PDF/A level A (pdfa.tcl, ISO 19005 6.7.3) - and
  # the question lives HERE, with the marks, because the two topics may not
  # require each other and both already depend on this module: each claim
  # demands a tagged document, [tagged] lives here, and the record read
  # below is only ever filled in a tagged one. The facts come from
  # [undescribedGraphics] in image.tcl, which fills the key for a drawing
  # and a form placement as well; clause is the caller's citation, the one
  # word the two claims do not share.
  method GraphicsUndescribed {clause} {
    set nouns {image "an image" svg "a drawing" form "a form"}
    return [lmap entry [my undescribedGraphics] {
      string cat "page [dict get $entry page]: [dict get $nouns [dict get \
          $entry kind]] was placed without -alt and without -artifact 1 -\
          describe it, or say it is decoration; an artifact may carry nothing\
          a reader needs ($clause)"
    }]
  }

  # The element a mark belongs to right now, or {} when nothing is open.
  method StructureCurrent {} {
    return [lindex [my state structureStack] end]
  }

  # Claim the next MCID on the current page and record which element owns it.
  # Returns {mcid type element} - the first two to hand to [StructureBegin],
  # the element for [StructureMarkAgain] - or {} when nothing is to be
  # bracketed.
  #
  # The type travels WITH the number rather than being looked up again later:
  # a derived tag closes its element immediately, so by the time the operator
  # is written there may be nothing open to ask.
  #
  # Nothing open and no derived type means the mark is an ARTIFACT - what is
  # not in the tree is artifact by definition (14.8.2.2), and a caller who
  # wanted it in the tree said so.
  # The second argument says WHICH kind of artifact, as {type ?subtype?} -
  # Pagination for a running head or a page number, Layout for a rule or a
  # cell fill, Page and Background for the two that nothing here produces.
  #
  # It matters from UA-2 on, where a bare BMC bracket is no longer enough and
  # every artifact has to name its type. Under 1.7 it is allowed and ignored,
  # so it is written either way rather than made to depend on the claim - a
  # document that is upgraded to UA-2 should not have to be redrawn.
  #
  # The third argument is where the content BEGINS: the top edge, in the
  # document unit, counted from the top of the page as -at is. It is kept
  # with the mark, in PDF space, so that a structure destination can carry a
  # page position (/XYZ) beside the element - the writer of the tree knows
  # the page and the number of an element, but only the caller that drew the
  # content knows where on the page it went. {} when the caller has no
  # position to give; the destination then falls back to /Fit.
  method StructureMark {{derived {}} {artifact Layout} {top {}}} {
    if {![my tagged]} {
      return {}
    }
    # A caller may write the whole thing as one word list - "Artifact
    # Pagination Header" - which is what -tag on [text] passes through. There
    # is no ambiguity to resolve: a structure type is a single word, so
    # anything longer is an artifact with its kind spelled out. That is not
    # the same as guessing at a value's shape, which this package has been
    # bitten by; the two vocabularies do not overlap.
    if {[llength $derived] > 1} {
      # Only an artifact carries a kind. "-tag {P Pagination}" reads as if
      # the paragraph were pagination, and the second word used to be taken
      # and then dropped without a word, because the kind is read at the
      # bracket and only an artifact has one there. Refused instead: the
      # caller means either a P or a Pagination artifact, and nothing here
      # can tell which.
      if {[lindex $derived 0] ne "Artifact"} {
        return -code error -errorcode [list TCLPDF STRUCTURE TYPE tag] \
            "tclpdf: -tag \"$derived\" - a structure type is\
            one word, and only an artifact takes a kind after it\
            (\"Artifact type ?subtype?\"); write -tag [lindex $derived 0] or\
            -tag {Artifact [lrange $derived 1 end]}"
      }
      set artifact [lrange $derived 1 end]
      set derived [lindex $derived 0]
    }
    if {$derived eq "Artifact"} {
      my StructureArtifactKind $artifact
    }
    # Suspended while drawing into a content stream of its own - a form
    # XObject. MCIDs are unique per STREAM, and this counter is per page, so
    # anything marked in there would carry a number the page does not have.
    # Whoever suspends is responsible for bracketing the [Do] instead.
    if {[my state structureSuspend] eq "1"} {
      return {}
    }
    # Inside an artifact nothing is marked again. Artifacts do not nest, and
    # tagged content inside one is a UA-1 defect in its own right ("Tagged
    # content shall not be present inside content marked as Artifact") - found
    # with veraPDF, not foreseen: a table cell declares its fill an artifact
    # and then draws a rectangle, and the rectangle asked which element was
    # open. It found the TH the cell is drawn in and claimed the fill as its
    # content.
    if {[my state structureInArtifact] eq "1"} {
      return {}
    }
    # Artifact is not a structure type and never enters the tree: it is the
    # explicit statement that something on the page carries no meaning - a
    # running head, a page number, a rule. UA-1 needs it, because there
    # everything must be either tagged or declared artifact; a validator
    # counts unmarked content as a defect.
    if {$derived eq "Artifact"} {
      my state structureInArtifact 1
      return [list artifact $artifact]
    }
    # "auto" is what the drawing primitives ask for: put this in whatever
    # element is open, and if none is, call it an artifact. A rule under a
    # heading means nothing and is decoration; the same rectangle inside an
    # open Figure is part of a diagram and belongs to it. Neither the shape
    # nor this module can tell those apart - the open element can.
    if {$derived eq "auto"} {
      variable ::tclpdf::structure::containers
      set open [my StructureCurrent]
      if {$open eq {}
          || [dict get [lindex [my state structure] $open] type] in $containers} {
        my state structureInArtifact 1
        return [list artifact $artifact]
      }
      set derived {}
    }
    variable ::tclpdf::structure::containers
    # A grouping type holds elements, not a mark: "-tag Table" on a line of
    # text would make a Table whose one kid is a marked-content sequence,
    # which no reader can make anything of. The structure call is the way to
    # open one, and the text drawn inside it becomes its P. Refused before
    # anything is claimed - no element, no MCID.
    if {$derived in $containers} {
      return -code error -errorcode [list TCLPDF STRUCTURE TYPE tag] \
          "tclpdf: -tag $derived names a grouping type, which\
          holds elements and no text of its own - open it with \[\$doc\
          structure $derived -script ...\] and draw inside it"
    }
    # THE THREE TYPES THAT STAND FOR AN ANNOTATION. A Link, an Annot and a
    # Form are an association between a piece of content and an annotation
    # (ISO 32000-1 Tables 338 and 340: a Form "shall have only one child,
    # an object reference"); the object reference is written when the
    # annotation is drawn INSIDE the open element, and a derived tag closes
    # its element again before the next call can put anything in it. So
    # "-tag Link" made an element that promises a link and holds none - a
    # reader announces it and there is nothing to follow. veraPDF measures
    # the Form case (7.18.4-2 under UA-1) and lets the other two pass; all
    # three are the same empty promise, and all three have the same remedy.
    if {$derived in {Link Annot Form}} {
      return -code error -errorcode [list TCLPDF STRUCTURE TYPE tag] \
          "tclpdf: -tag $derived names an element that stands\
          for an annotation and holds a reference to it, not text (ISO\
          32000-1 Table [expr {$derived eq "Form" ? 340 : 338}]) - open it\
          with \[\$doc structure $derived -script ...\] and draw the\
          annotation inside it"
    }
    set element [my StructureCurrent]
    if {$element ne {}} {
      set open [dict get [lindex [my state structure] $element] type]
      if {$open in $containers} {
        # An open container cannot hold the mark itself, so the derived type
        # becomes a child of it: text drawn in a Sect is a P in that Sect.
        # Without a derived type there is nothing to make, and the mark falls
        # through to being an artifact.
        set element {}
        if {$derived ne {}} {
          set derived [my StructureDerivedIn $open $derived]
        }
      } elseif {$derived ni [list {} P $open]
          && $element ne [my state structureExpansionSpan]} {
        # An open leaf and a tag that names something else: the tag says
        # what the text IS, so it becomes a child - a Span in the open P, a
        # Caption in the open Figure - or is refused by the nesting rules,
        # naming both types, where an H1 inside a P is asked for. Until
        # 2026-08-18 the tag was dropped and the text marked as the open
        # element, without a word.
        #
        # P is the exception because it is what [text] passes when nothing
        # was said: text drawn in an open H1 IS the heading, not a paragraph
        # in it - which is also why an explicit -tag P in an open leaf reads
        # as "this is that element's text" rather than as a P inside it.
        # And the Span that [StructureExpansion] opened for this very mark
        # is the other: the tag went into the element around that Span,
        # and the mark belongs in it whatever the tag said.
        set element {}
      }
    }
    if {$element eq {} && $derived eq {}} {
      # AN EMPTY TAG IS REFUSED, like every other tag this module cannot
      # use. It is what "-tag $tag" writes when the variable is empty, and it
      # was the one unusable value that fell through in silence: no element,
      # no artifact, no bracket - the text went onto the page and the tree
      # never heard of it. That is the failure this package is built against,
      # because nothing shows it: qpdf is content, and veraPDF counted 764
      # checks and 0 failures over a paragraph no screen reader reaches.
      #
      # Refused rather than read as "take the default", because that is how
      # the other unusable values are answered - "NoSuchType", a grouping
      # type, "{Artifact NoSuch}" are each named and refused - and because a
      # caller who wants the default writes no -tag at all, which is P. An
      # empty variable is a mistake at the call, and the call is where it is
      # worth hearing about.
      #
      # Only here, where nothing would come of it. Drawn inside an open leaf
      # an empty tag means what no tag means, "this is that element's text",
      # and the mark landed on the open element above long before this.
      return -code error -errorcode [list TCLPDF STRUCTURE TYPE tag] \
          "tclpdf: -tag is empty and no element is open to\
          hold the content - name a structure type, or \"Artifact\" for\
          content that carries no meaning; without -tag the type is P"
    }
    if {$element eq {}} {
      # Created here, holds this one mark and is closed again - a paragraph
      # in no section is still a paragraph, and one in a section is a
      # paragraph in it.
      set element [my StructureOpen $derived]
      my StructureClose $element
    }
    return [my StructureAttach $element $top]
  }

  # A further mark for an element that already has one - on another page.
  # A paragraph that [text -paginate] carries over a page break stays ONE
  # element with a mark on each page (the same shape a table breaking over
  # pages has: one Table, kids on every page); a fresh P per page would read
  # as two paragraphs. The element is the third word of what [StructureMark]
  # answered for the first page. Nothing is checked about what is open now:
  # the element was chosen when the paragraph began, and a page break in the
  # middle of it changes nothing about where it belongs.
  method StructureMarkAgain {element {top {}}} {
    if {![my tagged] || $element eq {}} {
      return {}
    }
    return [my StructureAttach $element $top]
  }

  # Claim the next MCID on the current page for an element and record it as
  # a kid. Answers {mcid type element}: the first two for [StructureBegin],
  # the element for [StructureMarkAgain].
  method StructureAttach {element top} {
    set page [my page current]
    set counters [my state structureMcid]
    set mcid [expr {[dict exists $counters $page] ?
        [dict get $counters $page] : 0}]
    dict set counters $page [expr {$mcid + 1}]
    my state structureMcid $counters

    # The position goes into PDF space NOW, while the page it belongs to is
    # the current one - the mirror axis is the page height, and the tree is
    # written when a different page is current.
    set y {}
    if {$top ne {}} {
      lassign [my coords 0 $top] . y
    }
    set elements [my state structure]
    set entry [lindex $elements $element]
    dict lappend entry kids [list mark $page $mcid $y]
    lset elements $element $entry
    my state structure $elements
    return [list $mcid [dict get $entry type] $element]
  }

  # An expansion (14.9.5) is read from the tree and from nowhere else - in an
  # untagged document it would be recorded and never written, and the
  # abbreviation would stay unexplained without a word about why. Said at the
  # call, like [StructureDestinationGuard] says it; one guard for both roads,
  # [structure -expansion] and [text -expansion].
  method StructureExpansionGuard {} {
    if {[my state tagged] ne "1"} {
      return -code error -errorcode [list TCLPDF STRUCTURE STATE expansion] \
          "tclpdf: -expansion needs a tagged document - the\
          expanded form of an abbreviation is read from the structure tree.\
          Call \[\$doc tagged 1\] first"
    }
    return
  }

  # The Span an abbreviation is read from (14.9.5), for [text -expansion]:
  # opened here, and the mark that follows lands in it. Answers the ids to
  # close after the mark, innermost last - so the caller closes them in
  # reverse. Empty when nothing is to be opened, for the same reasons
  # [StructureMark] gives nothing: no tree, or a suspended stream, or an
  # artifact - an expansion inside a page number would be a Span with no
  # content, which is worse than none.
  #
  # A Span is inline and needs a leaf to sit in. Drawn inside an open P it
  # goes right in; drawn outside any element, or in a container, the derived
  # element is opened first - the P a bare [text] would have made - because
  # a Span straight under a Sect is exactly the tree Annex L forbids.
  method StructureExpansion {derived expansion} {
    if {[lindex $derived 0] eq "Artifact"} {
      return -code error -errorcode \
          [list TCLPDF STRUCTURE ATTRIBUTE expansion] \
          "tclpdf: -expansion on an artifact - what is outside\
          the tree cannot carry an expanded form; drop -tag Artifact or\
          -expansion"
    }
    my StructureExpansionGuard
    if {[my state structureSuspend] eq "1"
        || [my state structureInArtifact] eq "1"} {
      return {}
    }
    variable ::tclpdf::structure::containers
    set opened {}
    set current [my StructureCurrent]
    if {$current ne {}} {
      set open [dict get [lindex [my state structure] $current] type]
      if {$open in $containers} {
        set derived [my StructureDerivedIn $open $derived]
        set current {}
      }
    }
    if {$current eq {}} {
      lappend opened [my StructureOpen $derived]
    }
    lappend opened [my StructureOpen Span [dict create expansion $expansion]]
    # Remembered for the mark that follows: [text] hands its -tag to
    # [StructureMark] as well, and the mark has to land in this Span, not
    # become a child of it named after the tag - see there.
    my state structureExpansionSpan [lindex $opened end]
    return $opened
  }

  # The operators around a piece of marked content, or "" when untagged. The
  # stream names a tag of its own; a reader takes the meaning from the tree,
  # but the two must not disagree, so it is the element's own type.
  method StructureBegin {mark} {
    if {![llength $mark]} {
      return ""
    }
    if {[lindex $mark 0] eq "artifact"} {
      # BDC with a property list rather than a bare BMC. An artifact has no
      # MCID - nothing in the tree points at it - but it does say what kind
      # it is, which UA-2 requires and 1.7 permits.
      lassign [lindex $mark 1] type subtype
      set pairs "/Type /$type"
      if {$subtype ne {}} {
        append pairs " /Subtype /$subtype"
      }
      return "/Artifact <<$pairs>> BDC\n"
    }
    lassign $mark mcid type
    return "/$type <</MCID $mcid>> BDC\n"
  }

  method StructureEnd {mark} {
    if {![llength $mark]} {
      return ""
    }
    if {[lindex $mark 0] eq "artifact"} {
      my state structureInArtifact 0
    }
    return "EMC\n"
  }

  # Refuse an artifact kind the standard does not know, in the words of the
  # refusal for an unknown structure type: the caller wrote "-tag {Artifact
  # Foo}" and gets told what the choices are.
  method StructureArtifactKind {kind} {
    variable ::tclpdf::structure::artifactTypes
    variable ::tclpdf::structure::artifactSubtypes
    if {[llength $kind] > 2} {
      return -code error -errorcode [list TCLPDF STRUCTURE TYPE artifact] \
          "tclpdf: an artifact is \"Artifact type ?subtype?\",\
          not \"Artifact $kind\""
    }
    lassign $kind type subtype
    if {$type ni $artifactTypes} {
      return -code error -errorcode [list TCLPDF STRUCTURE TYPE artifact] \
          "tclpdf: unknown artifact type \"$type\" - the\
          types of ISO 32000-1 Table 330 are: [join $artifactTypes {, }]"
    }
    if {$subtype ne {}} {
      if {$type ne "Pagination"} {
        return -code error -errorcode [list TCLPDF STRUCTURE TYPE subtype] \
            "tclpdf: only a Pagination artifact has a\
            subtype (ISO 32000-1 Table 331), not a $type"
      }
      if {$subtype ni $artifactSubtypes} {
        return -code error -errorcode [list TCLPDF STRUCTURE TYPE subtype] \
            "tclpdf: unknown artifact subtype \"$subtype\" -\
            the subtypes of ISO 32000-1 Table 331 are:\
            [join $artifactSubtypes {, }]"
      }
    }
    return
  }

}

package provide tclpdf::structure 1.7