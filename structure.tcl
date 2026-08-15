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
  variable attributeValues {
    scope     {Row Column Both}
    numbering {None Unordered Description Disc Circle Square Decimal
               UpperRoman LowerRoman UpperAlpha LowerAlpha}
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
      scope {} numbering {} bbox {} colSpan {} rowSpan {}
    } $args "structure"]
    set script [dict get $options script]
    if {$script eq {}} {
      return -code error "tclpdf: structure needs -script"
    }
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
    # A name makes the element referable - see [structureDestination].
    if {[dict exists $options name] && [dict get $options name] ne {}} {
      set named [my state structureNames]
      if {[dict exists $named [dict get $options name]]} {
        return -code error "tclpdf: a structure element named\
            \"[dict get $options name]\" already exists - a name has to be\
            unique, or a link would not know which one it means"
      }
      dict set named [dict get $options name] [llength [my state structure]]
      my state structureNames $named
    }
    foreach key [list alt lang title actualText expansion \
        {*}[dict keys $attributes]] {
      if {![dict exists $options $key]} {
        dict set options $key {}
      }
    }
    if {[dict get $options expansion] ne {}} {
      my StructureExpansionGuard
    }
    set elements [my state structure]
    set stack [my state structureStack]
    set id [llength $elements]
    set parent [expr {[llength $stack] ? [lindex $stack end] : {}}]
    lappend elements [dict create type $type parent $parent kids {} \
        alt [dict get $options alt] lang [dict get $options lang] \
        title [dict get $options title] \
        actualText [dict get $options actualText] \
        expansion [dict get $options expansion] \
        attributes [my StructureAttributes $type $options]]
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
          if {$value ni $values} {
            return -code error "tclpdf: -$option must be one of\
                [join $values {, }] - not \"$value\""
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

  method StructureClose {id} {
    set stack [my state structureStack]
    if {[lindex $stack end] ne $id} {
      return -code error "tclpdf: structure elements closed out of order"
    }
    my state structureStack [lrange $stack 0 end-1]
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
  # Returns the pair {mcid type} to hand to [StructureBegin], or {} when
  # nothing is to be bracketed.
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
    return [list $mcid [dict get $entry type]]
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

  # --- writing ------------------------------------------------------------
  #
  # Runs on the beforeWrite event, so on EVERY write - the numbers therefore
  # come from [reservation] and survive a rebuild, which is the contract
  # documented in event.tcl.

  method StructureWrite {} {
    if {![my tagged]} {
      return
    }
    set writer [my writer]
    set elements [my state structure]
    set rootNumber [my reservation structure.root]
    # Exactly one Document element below the root - TS 32005 Table 5 gives it
    # occurrence 1, not 0..n. Creating it here rather than asking for it means
    # a document that only ever derived its tags still gets a well formed
    # tree.
    set documentNumber [my reservation structure.document]
    set treeNumber [my reservation structure.parenttree]

    set index 0
    foreach element $elements {
      dict set element number [my reservation structure.$index]
      lset elements $index $element
      incr index
    }

    # Page -> array of element references, indexed by MCID. Only the elements
    # know which marks they own, so it is collected by walking them.
    set parents {}
    foreach element $elements {
      foreach kid [dict get $element kids] {
        if {[lindex $kid 0] ne "mark"} {
          continue
        }
        lassign $kid . page mcid
        set entry [expr {[dict exists $parents $page] ?
            [dict get $parents $page] : {}}]
        while {[llength $entry] <= $mcid} {
          lappend entry {}
        }
        lset entry $mcid [$writer ref [dict get $element number]]
        dict set parents $page $entry
      }
    }

    # {} unless a 2.0 claim put one there - see the NS key below.
    set namespace [my state uaNamespace]
    variable ::tclpdf::structure::only17

    set index 0
    set topLevel {}
    foreach element $elements {
      set parent [dict get $element parent]
      if {$parent eq {}} {
        lappend topLevel $index
      }
      set kids {}
      foreach kid [dict get $element kids] {
        switch -- [lindex $kid 0] {
          element {
            lappend kids [$writer ref \
                [dict get [lindex $elements [lindex $kid 1]] number]]
          }
          mark {
            lappend kids [::tclpdf::pdfObj num [lindex $kid 2]]
          }
          objr {
            # Pg is written on EVERY object reference rather than only where
            # the element's own Pg differs: always naming it is unambiguous
            # and permitted, and it spares a reader the comparison.
            lassign $kid . number page
            lappend kids [::tclpdf::pdfObj dictionary [list \
                Type /OBJR Obj [$writer ref $number] \
                Pg [$writer ref [dict get [my Page $page] number]]]]
          }
        }
      }
      set pairs [list Type /StructElem S /[dict get $element type] \
          P [expr {$parent eq {} ? [$writer ref $documentNumber] :
              [$writer ref [dict get [lindex $elements $parent] number]]}]]
      # The namespace an element's type is read in. Empty on the 1.7 path,
      # where the default namespace IS the 1.7 one and naming it would be
      # noise; set by ua.tcl for part 2, where relying on the default is no
      # longer allowed (UA-2 8.2.5.2).
      #
      # The twelve 1.7-only types are the exception and keep the default:
      # naming the 2.0 namespace on a type that does not exist in it would
      # be a claim about nothing.
      if {$namespace ne {} && [dict get $element type] ni $only17} {
        lappend pairs NS $namespace
      }
      # Pg names the page the MCIDs are counted in. Required as soon as the
      # element owns marks - without it a reader cannot resolve them.
      set page [my StructurePage $element]
      if {$page ne {}} {
        lappend pairs Pg [$writer ref [dict get [my Page $page] number]]
      }
      if {[llength $kids] == 1} {
        lappend pairs K [lindex $kids 0]
      } elseif {[llength $kids]} {
        lappend pairs K [::tclpdf::pdfObj arr $kids]
      }
      # E is the expanded form of an abbreviation (14.9.5, Table 323) - a text
      # string like Alt, so it is written the same way.
      foreach {key option} {Alt alt Lang lang T title ActualText actualText
          E expansion} {
        if {[dict get $element $option] ne {}} {
          lappend pairs $key [::tclpdf::pdfObj str [dict get $element $option]]
        }
      }
      # One owner gives a single dictionary, several give an array of them
      # (14.8.5). Written inline rather than as an indirect object: an
      # attribute dictionary is small, and one per cell as its own object
      # would double the object count of a table for nothing.
      set attributes {}
      dict for {owner values} [dict get $element attributes] {
        lappend attributes [::tclpdf::pdfObj dictionary [list O /$owner {*}$values]]
      }
      if {[llength $attributes] == 1} {
        lappend pairs A [lindex $attributes 0]
      } elseif {[llength $attributes]} {
        lappend pairs A [::tclpdf::pdfObj arr $attributes]
      }
      $writer put [dict get $element number] [::tclpdf::pdfObj dictionary $pairs]
      incr index
    }

    set documentKids {}
    foreach top $topLevel {
      lappend documentKids [$writer ref \
          [dict get [lindex $elements $top] number]]
    }
    set documentPairs [list Type /StructElem S /Document \
        P [$writer ref $rootNumber] K [::tclpdf::pdfObj arr $documentKids]]
    if {$namespace ne {}} {
      lappend documentPairs NS $namespace
    }
    $writer put $documentNumber [::tclpdf::pdfObj dictionary $documentPairs]

    # The ParentTree is a number tree (7.9.7): Nums pairs each key with its
    # value, in ascending key order.
    #
    # Two kinds of entry share it. A page's key holds an ARRAY, indexed by
    # MCID; an annotation's key holds the element itself, with no array
    # around it. Annotation keys are counted on past the pages, so both fit
    # in one ascending sequence.
    set annotations [my state structureAnnots]
    # The pages start where the annotations end - see [StructureAnnotation]
    # for why it is that way round and not the obvious one.
    set offset [llength $annotations]
    set entries {}
    foreach page [dict keys $parents] {
      dict set entries [expr {$offset + $page}] [::tclpdf::pdfObj arr \
          [lmap ref [dict get $parents $page] {
            expr {$ref eq {} ? "null" : $ref}
          }]]
    }
    foreach annotation $annotations {
      lassign $annotation element . key
      dict set entries $key [$writer ref \
          [dict get [lindex $elements $element] number]]
    }
    set nums {}
    foreach key [lsort -integer [dict keys $entries]] {
      lappend nums [::tclpdf::pdfObj num $key]
      lappend nums [dict get $entries $key]
    }
    $writer put $treeNumber [::tclpdf::pdfObj dictionary [list \
        Nums [::tclpdf::pdfObj arr $nums]]]

    set rootPairs [list Type /StructTreeRoot \
        K [$writer ref $documentNumber] \
        ParentTree [$writer ref $treeNumber] \
        ParentTreeNextKey [expr {[my page count] + [llength $annotations]}]]
    if {$namespace ne {}} {
      lappend rootPairs Namespaces [::tclpdf::pdfObj arr [list $namespace]]
    }
    $writer put $rootNumber [::tclpdf::pdfObj dictionary $rootPairs]

    # The destination objects, now that every element has its number. A
    # structure destination is the element itself where a page destination
    # would name a page (12.3.2.3) - a reader then scrolls to the CONTENT
    # rather than to a coordinate that may have moved.
    #
    # Two objects per name, because the action that carries them (see
    # [structureDestination]) names both: /SD, the element, and /D, a page
    # destination to where the element BEGINS, for a reader that does not
    # understand structure destinations (12.3.2.3 recommends the pair). /XYZ
    # with the top of the first content and no zoom, when the mark recorded
    # a position; /Fit on that page when it did not - a position that is not
    # known is not invented.
    dict for {name numbers} [my state structureDestinations] {
      if {![dict exists [my state structureNames] $name]} {
        return -code error "tclpdf: no structure element is named \"$name\" -\
            a link or a bookmark points at it. Name one with\
            \[\$doc structure <type> -name $name ...\]"
      }
      set target [dict get [my state structureNames] $name]
      $writer put [dict get $numbers sd] [::tclpdf::pdfObj arr [list \
          [$writer ref [dict get [lindex $elements $target] number]] /Fit]]
      lassign [my StructureFirstPosition $elements $target] page y
      if {$page eq {}} {
        set page 0
      }
      set pageRef [$writer ref [dict get [my Page $page] number]]
      $writer put [dict get $numbers d] [::tclpdf::pdfObj arr [expr {$y eq {} ?
          [list $pageRef /Fit] :
          [list $pageRef /XYZ null [::tclpdf::pdfObj num $y] null]}]]
    }

    my catalogEntry StructTreeRoot [$writer ref $rootNumber]
    # Marked says the file follows 14.7; Suspects false says nobody has
    # flagged the tree as doubtful. UA-1 clause 7.1 wants both.
    my catalogEntry MarkInfo [::tclpdf::pdfObj dictionary \
        [list Marked true Suspects false]]
    # The page carries its index into the ParentTree. Handed over through the
    # scratch state, the way link annotations already reach WritePage, so
    # output.tcl stays free of this topic.
    set structParents {}
    foreach page [dict keys $parents] {
      dict set structParents $page [expr {$offset + $page}]
    }
    my state structParents $structParents
    return
  }

  # The action that takes a reader to the named element, for the /A entry of
  # a link annotation or an outline item:
  #
  #   << /S /GoTo /SD <structure destination> /D <page destination> >>
  #
  # An action rather than a bare /Dest, because a GoTo is the one place that
  # holds BOTH targets (ISO 32000-2 Table 202): /SD names the element, /D the
  # page it begins on. A reader that knows 2.0 follows /SD to the content; an
  # older one skips the key it does not know and still lands on the right
  # page through /D. That pairing is what 12.3.2.3 recommends and what
  # PDF/UA-2 rests on.
  #
  # Both destinations are reserved now and filled at write time, and that
  # indirection is what makes this work at all: an annotation is written the
  # moment the link is drawn, while the element it points at gets its object
  # number - and its first page is settled - only when the tree is built. A
  # destination may be an indirect object (12.3.2), so the action can carry
  # references to objects that do not exist yet.
  #
  # The name does not have to be declared yet either - a link may point
  # forwards, at a section further down the document. It is checked when the
  # tree is written, where a mistyped one can still be named. Asking twice
  # for one name gets the same objects, so a caller may ask early and again
  # when it writes.
  method structureDestination {name} {
    set wanted [my state structureDestinations]
    if {![dict exists $wanted $name]} {
      dict set wanted $name [dict create \
          sd [my reservation structure.dest.$name] \
          d [my reservation structure.pagedest.$name]]
      my state structureDestinations $wanted
    }
    set numbers [dict get $wanted $name]
    return [::tclpdf::pdfObj dictionary [list S /GoTo \
        D [[my writer] ref [dict get $numbers d]] \
        SD [[my writer] ref [dict get $numbers sd]]]]
  }

  # The refusal both takers of a structure destination - link and bookmark -
  # have to make, kept once, beside the method it protects. caller names the
  # call for the message.
  #
  # Without a tree the destination would point at nothing. And it needs a 2.0
  # file: before ISO 32000-2 the first entry of a destination array has to be
  # a page object (ISO 32000-1, Table 151) - written anyway it would point a
  # validator and every reader at an object that is not a page. Both checked
  # where the caller is: left alone, the write failed later with "reserved
  # but never written" and no word about which call was at fault.
  method StructureDestinationGuard {caller} {
    if {[my state tagged] ne "1"} {
      return -code error "tclpdf: $caller needs a tagged document - a\
          structure destination points at an element of the tree. Call\
          \[\$doc tagged 1\] first"
    }
    if {[package vcompare [[my writer] version] 2.0] < 0} {
      return -code error "tclpdf: a structure destination is a syntax of\
          ISO 32000-2 (12.3.2.3) and this document is PDF\
          [[my writer] version] - raise the version, or use\
          \[\$doc ua -part 2\], which does it"
    }
    return
  }

  # What the tree looks like, for a checker that has to judge it as a whole.
  #
  # Two questions cannot be answered while the tree is being built, because
  # both need what comes after: whether the headings descend without a gap,
  # and whether every row of a table has the same number of cells. Both are
  # PDF/UA rules, and both would be wrong to enforce here - a document that
  # is not claiming UA may have a lone H3 for good reasons.
  #
  # So this answers with facts and judges nothing:
  #
  #   headings   the H1..H10 types in document order
  #   rows       per table element, the cell count of each of its rows
  #   lists      per L element: its ListNumbering (empty when unset), how
  #              many LI it holds and how many of those carry a Lbl
  #   types      every type used, once
  #
  # Returned rather than read out of the state by the caller: the shape of an
  # element is this module's business, and a checker that walked it would
  # break the next time a field is added.
  method structureReport {} {
    set elements [my state structure]
    set headings {}
    set types {}
    set rows {}
    set lists {}
    foreach element $elements {
      set type [dict get $element type]
      if {$type ni $types} {
        lappend types $type
      }
      if {[regexp {^H(10|[1-9])$} $type -> level]} {
        lappend headings $level
      }
    }
    set index 0
    foreach element $elements {
      switch -- [dict get $element type] {
        Table {
          lappend rows [my StructureRowWidths $elements $index]
        }
        L {
          lappend lists [my StructureListShape $elements $index]
        }
      }
      incr index
    }
    return [dict create headings $headings rows $rows lists $lists types $types]
  }

  # One list as three facts: what it says it is numbered, how many items it
  # has, and how many of them carry a label. Attributes are stored owner ->
  # pairs with the value a name object ({List {ListNumbering /Decimal}}), so
  # the slash comes off here.
  method StructureListShape {elements index} {
    set element [lindex $elements $index]
    set numbering {}
    set attributes [dict get $element attributes]
    if {[dict exists $attributes List ListNumbering]} {
      set numbering [string range [dict get $attributes List ListNumbering] 1 end]
    }
    set items 0
    set labelled 0
    foreach kid [dict get $element kids] {
      if {[lindex $kid 0] ne "element"} {
        continue
      }
      set item [lindex $elements [lindex $kid 1]]
      if {[dict get $item type] ne "LI"} {
        continue
      }
      incr items
      foreach grandchild [dict get $item kids] {
        if {[lindex $grandchild 0] eq "element"
            && [dict get [lindex $elements [lindex $grandchild 1]] type] eq "Lbl"} {
          incr labelled
          break
        }
      }
    }
    return [dict create numbering $numbering items $items labelled $labelled]
  }

  # The cell count of every row below one table, section groups included: a
  # THead and a TBody hold rows of the same table and their widths have to be
  # compared with each other, not each within its own group.
  method StructureRowWidths {elements index} {
    set widths {}
    foreach kid [dict get [lindex $elements $index] kids] {
      if {[lindex $kid 0] ne "element"} {
        continue
      }
      set child [lindex $elements [lindex $kid 1]]
      switch -- [dict get $child type] {
        TR {
          set cells 0
          foreach cell [dict get $child kids] {
            if {[lindex $cell 0] eq "element"
                && [dict get [lindex $elements [lindex $cell 1]] type] in {TH TD}} {
              incr cells
            }
          }
          lappend widths $cells
        }
        THead - TBody - TFoot {
          lappend widths {*}[my StructureRowWidths $elements [lindex $kid 1]]
        }
      }
    }
    return $widths
  }

  # The page an element's marks sit on, or {} when it owns none or they span
  # several. The norm allows leaving Pg out then, because each mark's page is
  # reachable through the ParentTree anyway.
  method StructurePage {element} {
    set pages {}
    foreach kid [dict get $element kids] {
      if {[lindex $kid 0] eq "mark"} {
        lappend pages [lindex $kid 1]
      }
    }
    set pages [lsort -unique -integer $pages]
    if {[llength $pages] == 1} {
      return [lindex $pages 0]
    }
    return {}
  }

  # Where an element BEGINS, as {page y} - the place the /D half of a
  # structure destination sends a reader. y is the top of the first content
  # in PDF space, or {} when the mark that begins the element recorded no
  # position. Not [StructurePage]: that answers "the one page all marks sit
  # on" and says nothing for an element that spans two, while here the FIRST
  # place is wanted, and every element has one.
  #
  # The kids are walked in document order: the first mark or annotation (an
  # OBJR carries its page and no position) decides, and a child element that
  # owns neither is asked the same question in turn - a Sect that holds only
  # a P begins where the P begins. An element with no content anywhere below
  # it has no place of its own; page 0 is the answer then, because a
  # destination has to name SOME page and the first is the one a reader can
  # least be misled by.
  method StructureFirstPosition {elements index} {
    foreach kid [dict get [lindex $elements $index] kids] {
      switch -- [lindex $kid 0] {
        mark {
          return [list [lindex $kid 1] [lindex $kid 3]]
        }
        objr {
          return [list [lindex $kid 2] {}]
        }
        element {
          set found [my StructureFirstPosition $elements [lindex $kid 1]]
          if {$found ne {}} {
            return $found
          }
        }
      }
    }
    return {}
  }

}

package provide tclpdf::structure 1.1
