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
  variable containers {
    Document Part Art Sect Div TOC TOCI Index L LI Table TR THead TBody TFoot
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
  # and are left out; the parts of a Ruby or a Warichu are placed by
  # parentOf below. Reference is the odd one - refused under Document and
  # nowhere else that matters (a TOCI holds one, and 5.5 draws it so), so
  # it is refused at the top level only.
  variable inlineOnly {
    Span Quote BibEntry Ruby Warichu Em Strong Sub
  }
  variable transparent {Div Part NonStruct}
  variable noInlineHome {DocumentFragment Aside BlockQuote}
  variable notAtTop {Reference}

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
  # FENote (ISO 32000-2 Table 368).
  variable parentOf {
    LI    {L}
    Lbl   {LI Note FENote}
    LBody {LI}
    TR    {Table THead TBody TFoot}
    TH    {TR}
    TD    {TR}
    THead {Table}
    TBody {Table}
    TFoot {Table}
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
      return -code error "tclpdf: tagged takes at most one value"
    }
    set value [lindex $args 0]
    if {![string is boolean -strict $value]} {
      return -code error "tclpdf: tagged takes a boolean, not \"$value\""
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
          return -code error "tclpdf: tagged 1 has to come before anything is\
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
  #                       ?-actualText text? ?-expansion text? -script body
  #
  # Opens an element, runs the body with it open, and closes it again -
  # whatever the body does. The bracket form is the one [form create] and
  # [pattern create] already use, and it is the reason a half open tree
  # cannot reach the file: an error inside the body still closes the element
  # before it travels on.
  method structure {type args} {
    set options [::tclpdf::option parse {
      alt {} lang {} title {} actualText {} expansion {} script {} name {}
      id {} scope {} numbering {} bbox {} colSpan {} rowSpan {}
    } $args "structure"]
    # Missing, not empty: an element with nothing in it is a legitimate thing
    # to ask for - a placeholder a link points at, an L that is filled later
    # - and [option parse] cannot tell an empty -script from an absent one,
    # so the arguments themselves are asked, the way [configure] asks them
    # about -orientation.
    if {"script" ni [lmap {option value} $args {string trimleft $option -}]} {
      return -code error "tclpdf: structure needs -script"
    }
    set script [dict get $options script]
    set id [my StructureOpen $type $options]
    set code [catch {uplevel 1 $script} result outcome]
    my StructureClose $id
    if {$code} {
      return -options $outcome $result
    }
    # Judged once the body is through and only then: an error from inside
    # has already said what went wrong, and a caption complaint on top of it
    # would hide the cause.
    my StructureCheckCaption $id
    # The BODY's result, not the element id: this wraps calls that return
    # something the caller needs - [table] answers with the y coordinate
    # below the table, and swallowing it would break every table in a tagged
    # document.
    return $result
  }

  # Open an element and make it the current one. Returns its id.
  method StructureOpen {type {options {}}} {
    variable ::tclpdf::structure::types
    variable ::tclpdf::structure::types20
    if {$type ni $types && $type ni $types20} {
      return -code error "tclpdf: unknown structure type \"$type\" - the\
          standard types of ISO 32000-1 14.8.4 are: [join [lsort $types] {, }];\
          ISO 32000-2 adds [join [lsort $types20] {, }]"
    }
    # A 2.0-only type in a file that is not 2.0 would be written, validate as
    # a non-standard type without a role map, and mean nothing to a reader.
    if {$type in $types20 && $type ni $types
        && [package vcompare [[my writer] version] 2.0] < 0} {
      return -code error "tclpdf: \"$type\" is a structure type of ISO 32000-2\
          and this document is PDF [[my writer] version] - raise the version,\
          or use \[\$doc ua -part 2\], which does it"
    }
    my StructureCheckNesting $type
    variable ::tclpdf::structure::attributes
    foreach key [list alt lang title actualText expansion id name \
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
        return -code error "tclpdf: a structure element named\
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
      return -code error "tclpdf: -lang \"$lang\" is not a language tag -\
          expected something like de, de-DE or en-GB (RFC 3066)"
    }
    if {[dict get $options expansion] ne {}} {
      my StructureExpansionGuard
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
      set identifier "Note[expr {$id + 1}]"
    }
    if {$identifier ne {}} {
      set known [my state structureIds]
      if {[dict exists $known $identifier]} {
        return -code error "tclpdf: a structure element with the id\
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
    lappend elements [dict create type $type parent $parent kids {} \
        alt [dict get $options alt] lang $lang \
        title [dict get $options title] \
        actualText [dict get $options actualText] \
        expansion [dict get $options expansion] id $identifier \
        attributes $attributeObjects]
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
        return -code error "tclpdf: -$option belongs on [join $allowed { or }],\
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
            return -code error "tclpdf: -$option $value is a value of ISO\
                32000-2 (Table 369) and this document is PDF\
                [[my writer] version] - in a 1.7 file the values are\
                [join $values {, }]; raise the version, or use\
                \[\$doc ua -part 2\], which does it"
          }
          if {$value ni $values && $value ni $values20} {
            return -code error "tclpdf: -$option must be one of\
                [join $values {, }] - not \"$value\"[expr {
                [llength $values20] ? "; ISO 32000-2 adds [join $values20 {, }]"
                : {}}]"
          }
          set object /$value
        }
        number {
          if {![string is integer -strict $value] || $value < 1} {
            return -code error "tclpdf: -$option takes a positive integer,\
                not \"$value\""
          }
          set object [::tclpdf::pdfObj num $value]
        }
        rectangle {
          if {[llength $value] != 4} {
            return -code error "tclpdf: -$option takes four numbers\
                {left top width height}, not \"$value\""
          }
          lassign $value left top width height
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
    variable ::tclpdf::structure::parentOf
    set parent [my StructureCurrent]
    set parentType [expr {$parent eq {} ? {} :
        [dict get [lindex [my state structure] $parent] type]}]
    if {[dict exists $parentOf $type]} {
      set wanted [dict get $parentOf $type]
      if {$parentType ni $wanted} {
        set where "at the top level"
        if {$parentType ne {}} {
          set where "in a $parentType"
        }
        return -code error "tclpdf: a $type belongs in [join $wanted { or }],\
            not $where (ISO 32000-2 Annex L)"
      }
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
      return -code error "tclpdf: a $type is inline markup and belongs inside\
          an element that holds text - a P, a heading, a cell, a Figure -\
          not $where (ISO 32005 Table 5)"
    }
    if {$parent eq {}} {
      return
    }
    if {[dict exists $childrenOf $parentType]} {
      set allowed [dict get $childrenOf $parentType]
      if {$type ni $allowed} {
        return -code error "tclpdf: a $parentType may not contain a $type -\
            it takes [join $allowed {, }] (ISO 32000-2 Annex L)"
      }
      return
    }
    # A type that has just been found in one of the parents it is made for
    # is not the block element this rule is after: a Lbl in a Note is the
    # footnote's number, not a paragraph in a paragraph. Nothing else passes
    # by this clause - a P names no parent, so a P in a P is still refused.
    if {$parentType in $leafOnly && $type ni $inline
        && ![dict exists $parentOf $type]} {
      return -code error "tclpdf: a $parentType holds text and inline markup,\
          not a $type - close it before starting one (ISO 32000-2 Annex L)"
    }
    return
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
  method StructureAnnotation {number} {
    if {![my tagged]} {
      return {}
    }
    set element [my StructureCurrent]
    if {$element eq {}} {
      return {}
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
    dict lappend entry kids [list objr $number [my page current]]
    lset elements $element $entry
    my state structure $elements
    return $key
  }

  # The type of the element an annotation was attached to by
  # [StructureAnnotation], or {} when it was attached to none - drawn
  # outside any element, or before the document was tagged. Asked by
  # link.tcl for the UA rule that a link annotation sits inside a Link.
  method StructureAnnotationOwner {number} {
    foreach annotation [my state structureAnnots] {
      lassign $annotation element owner
      if {$owner == $number} {
        return [dict get [lindex [my state structure] $element] type]
      }
    }
    return {}
  }

  method StructureClose {id} {
    set stack [my state structureStack]
    if {[lindex $stack end] ne $id} {
      return -code error "tclpdf: structure elements closed out of order"
    }
    my state structureStack [lrange $stack 0 end-1]
    if {$id eq [my state structureExpansionSpan]} {
      my state structureExpansionSpan {}
    }
    return
  }

  # A Caption has a place, not just a parent: Annex L wants it as the FIRST
  # child of a Table or an L, and ISO 32000-2 lets a table carry it last as
  # well. Checked when the element's bracket closes, because only then is it
  # known what else it holds - and still at the call, where the message can
  # name the position rather than an object number. No caption, no complaint.
  method StructureCheckCaption {id} {
    set elements [my state structure]
    set element [lindex $elements $id]
    set type [dict get $element type]
    if {$type ni {Table L}} {
      return
    }
    set kids [dict get $element kids]
    set position 0
    foreach kid $kids {
      incr position
      if {[lindex $kid 0] ne "element"
          || [dict get [lindex $elements [lindex $kid 1]] type] ne "Caption"} {
        continue
      }
      if {$position == 1} {
        continue
      }
      if {$type eq "Table" && $position == [llength $kids]
          && [package vcompare [[my writer] version] 2.0] >= 0} {
        continue
      }
      set where "first"
      if {$type eq "Table"} {
        set where "first or, in a 2.0 file, last"
      }
      return -code error "tclpdf: the Caption of a $type has to be its $where\
          child, not child $position of [llength $kids] (ISO 32000-2 Annex L)"
    }
    return
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
    variable ::tclpdf::structure::contentChildOf
    # A grouping type holds elements, not a mark: "-tag Table" on a line of
    # text would make a Table whose one kid is a marked-content sequence,
    # which no reader can make anything of. The structure call is the way to
    # open one, and the text drawn inside it becomes its P. Refused before
    # anything is claimed - no element, no MCID.
    if {$derived in $containers} {
      return -code error "tclpdf: -tag $derived names a grouping type, which\
          holds elements and no text of its own - open it with \[\$doc\
          structure $derived -script ...\] and draw inside it"
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
        if {$derived ne {} && [dict exists $contentChildOf $open]} {
          set derived [dict get $contentChildOf $open]
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
      return {}
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
      return -code error "tclpdf: -expansion needs a tagged document - the\
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
      return -code error "tclpdf: -expansion on an artifact - what is outside\
          the tree cannot carry an expanded form; drop -tag Artifact or\
          -expansion"
    }
    my StructureExpansionGuard
    if {[my state structureSuspend] eq "1"
        || [my state structureInArtifact] eq "1"} {
      return {}
    }
    variable ::tclpdf::structure::containers
    variable ::tclpdf::structure::contentChildOf
    set opened {}
    set current [my StructureCurrent]
    if {$current ne {}} {
      set open [dict get [lindex [my state structure] $current] type]
      if {$open in $containers} {
        if {[dict exists $contentChildOf $open]} {
          set derived [dict get $contentChildOf $open]
        }
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
      return -code error "tclpdf: an artifact is \"Artifact type ?subtype?\",\
          not \"Artifact $kind\""
    }
    lassign $kind type subtype
    if {$type ni $artifactTypes} {
      return -code error "tclpdf: unknown artifact type \"$type\" - the\
          types of ISO 32000-1 Table 330 are: [join $artifactTypes {, }]"
    }
    if {$subtype ne {}} {
      if {$type ne "Pagination"} {
        return -code error "tclpdf: only a Pagination artifact has a\
            subtype (ISO 32000-1 Table 331), not a $type"
      }
      if {$subtype ni $artifactSubtypes} {
        return -code error "tclpdf: unknown artifact subtype \"$subtype\" -\
            the subtypes of ISO 32000-1 Table 331 are:\
            [join $artifactSubtypes {, }]"
      }
    }
    return
  }

}

package provide tclpdf::structure 1.3
