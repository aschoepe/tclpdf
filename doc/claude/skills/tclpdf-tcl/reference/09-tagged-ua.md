# Tagged PDF and PDF/UA

## Switch it on before anything is drawn

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc tagged 1                       ;# refused once a page has content
$doc info Title "Reference: tagged PDF"     ;# UA insists on a title ...
$doc language en-GB                         ;# ... and a language
$doc page add
$doc font embed body $ttf                   ;# ... and every face embedded - the standard 14 are out
$doc font embed bodyBold $ttfBold
$doc font -family body -size 10 -color black
```

The drawing does not change; a second, invisible tree beside it says what the marks **are** (nothing to do with `layer`, which is optional content - `07-patterns-forms.md`). `text` becomes a `P`, `table` a `Table` with `TR`/`TH`/`TD` (fills and rules artifacts), `image`/`svg`/`form place` a `Figure` with `-alt` or an artifact without. `structure` is for the grouping a writer cannot infer.

## Headings, sections, what a text is

```tcl
# What no writer can infer: whether a line is a heading. -tag says so.
$doc text "Accessible report" -at {20 20} -tag H1 -family bodyBold -size 16

$doc structure Sect -script {
    $doc text "Scope" -at {20 32} -tag H2 -family bodyBold -size 12
    # Text inside an open Sect becomes a P WITHIN it - one call, one element,
    # however many lines it breaks into.
    $doc text "One call is one paragraph. A Sect groups and holds no content of\
        its own; the paragraph is its child." -at {20 38} -width 170 -anchor top

    # Three calls, one paragraph: open the P yourself. -expansion makes a Span
    # carrying the expanded form of an abbreviation (PDF/UA 7.20).
    $doc structure P -script {
        set lead "This document claims "
        $doc text $lead -at {20 52}
        $doc text "PDF/UA" -at [list [expr {20 + [$doc textWidth $lead]}] 52] \
            -expansion "PDF Universal Accessibility, ISO 14289"
        $doc text "-1 conformance." -at [list [expr {20 + [$doc textWidth "${lead}PDF/UA"]}] 52]
    }
}
```

Headings are one of two forms: `H1`..`Hn` state the level (strongly structured), or the generic `H` inside nested `Sect`s takes it from the depth (weakly structured). One tree, one form - the mixture is refused under `ua`. `-tag P` is the default; a grouping type (`Table`, `L`, `Sect`) on `-tag` is refused - open it with `structure`. Inside an open leaf, `-tag Span` names a child.

## Lists say how they are numbered

```tcl
# -numbering on the L (None Disc Circle Square Decimal UpperRoman LowerRoman
# UpperAlpha LowerAlpha; 2.0 adds Unordered Description Ordered): PDF/UA makes it
# mandatory for an ordered list, and the label is drawn text - nobody can derive it.
$doc structure L -numbering Decimal -script {
    set y 66
    foreach {label body} {"1." "File the objection in writing." "2." "Await the acknowledgement." "3." "Ask for the file if needed."} {
        $doc structure LI -script {
            $doc structure Lbl -script { $doc text $label -at [list 20 $y] }
            $doc structure LBody -script { $doc text $body -at [list 28 $y] -width 160 }
        }
        incr y 6
    }
}
# A list without labels: -numbering None, and the text in the LI is its LBody.
$doc structure L -numbering None -script {
    set y 86
    foreach body {"Hall 2" "Hall 3" "Store"} {
        $doc structure LI -script { $doc text $body -at [list 20 $y] }
        incr y 6
    }
}
```

## Pictures, drawings, forms: described or declared decoration

```tcl
# -alt: a Figure carrying the description. -artifact 1: decoration, said so.
# Neither: an artifact nobody judged - PDF/UA refuses that at the write.
$doc image draw $png -at {20 108} -width 25 -alt "The company mark"
set ornament {<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><circle cx="10" cy="10" r="9" fill="#dde3ee"/></svg>}
$doc svg -data $ornament -at {50 108} -width 25 -artifact 1
$doc form create seal -size {20 20} -script { $doc circle -at {10 10} -radius 9 -fill {0.15 0.35 0.6} }
$doc form place seal -at {80 108} -alt "The seal of the workshop"

# Inside an open Figure the picture is its content and needs no -alt of its own;
# -bbox is what the reading tools rely on. Caption is a child.
$doc structure Figure -alt "A photograph of the press after maintenance" -bbox {110 108 40 30} -script {
    $doc image draw $jpeg -at {110 108} -width 40
    $doc text "Fig. 1: the press" -at {110 142} -tag Caption -size 8
}

# The band under this line means nothing: -tag Artifact takes it out. Running
# heads and feet name their kind: {Artifact Pagination Header} / Footer.
$doc line -from {20 150} -to {190 150} -width 0.4 -stroke {0.4 0.4 0.4}
$doc text "Report 2026 - reference" -at {20 287} -size 7 -tag {Artifact Pagination Footer}
$doc pageNumbers -at {190 287} -align right -format "page %n of %m" -family body -size 7
```

`pageNumbers` marks itself (`Pagination Header` above the middle of the page, `Footer` below). Nothing inside a form or a pattern is marked; the invocation carries the marking. Text inside an SVG file resolves its `font-family` against the embedded aliases and ends at Helvetica otherwise - which `ua` and `pdfa` then refuse at the write: embed the face under the name the file asks for (`font embed "DejaVu Sans" $ttf`).

## Links, tables, structure destinations

```tcl
# Under PDF/UA every link has a description (-tooltip) and sits inside a Link element.
$doc structure Link -script {
    $doc text "The regulation, full text" -at {20 160} -color {0.1 0.2 0.6}
    $doc link -at {20 156} -size {60 6} -url https://www.example.org/regulation \
        -tooltip "The regulation, full text at example.org"
}
$doc font -color black

# A table tags itself: Table, TR, TH (head row, scope Column), TD - nothing to add.
$doc table -at {20 170} -width 100 -theme grid \
    -head {{Item Sum}} -body {{parts 18.20} {labour 45.00}} \
    -columns {{} {align decimal}} -style {family body size 9}

# A named element is what link -structure / bookmark -structure point at - a
# target that stays right after the content above it has moved. -name itself
# is taken in any tagged document; POINTING at it needs a tagged 2.0 file
# (ua -part 2 gives both). There is no silent fall back to -page: in a 1.7
# file link -structure and bookmark -structure are refused outright, and the
# way on is the page destination, written as such.
$doc structure Sect -name appendix -script {
    $doc text "Appendix" -at {20 200} -tag H2 -family bodyBold -size 12
}
if {[catch {$doc bookmark "Appendix" -structure appendix} message options]} {
    puts "structure destination in a 1.7 file: [dict get $options -errorcode]"
} else {
    puts "structure destination in a 1.7 file: NOT REFUSED"
}
$doc bookmark "Appendix" -page 0 -at {20 200}
```

## Attributes, ids, the rest of `structure`

`-scope Row|Column|Both` belongs on a `TH`; `-bbox` on `Figure`, `Formula`, `Table`; `-colSpan`/`-rowSpan` on a cell (the table writes them itself); `-lang` a language tag for one element; `-actualText`, `-title`; `-id` an element identifier for the `IDTree` (a `Note` gets one by itself); `-ref` names another element - by the `-name` it was opened with - as the thing this one points at, which is the `Ref` entry of ISO 32000-2, Table 355 and therefore needs a 2.0 file (`TCLPDF STRUCTURE VERSION ref` below it). Part 2 asks for `-ref` in two places, and both are shown at the end of this file. Each is refused where the standard does not allow it. `-script` may be empty but not missing. Types beyond 1.7 (`Title`, `Aside`, `Em`, `Strong`, `Sub`, `FENote`, `H7`..`H10`) need a 2.0 file. Inline types (`Span`, `Em`, `Strong`, `Quote`, `Sub`) need a text-holding parent; a `P` inside a `P` is refused (Annex L).

## Coming back to an element: `structureResume`

```tcl
# A caller that draws in several passes - a second column, a later page, the
# cells of a table row that continues - hangs further children on an element
# that is already in the tree by resuming it under the -name (or -id) it was
# opened with. Only the OPENING is repeated: type, attributes and page stay
# what they were, and what is drawn inside is judged as it would have been on
# the first pass - a child the element may not hold is refused now as then.
$doc structureResume appendix -script {
    $doc text "Added on a second pass, and a child of the same Sect." \
        -at {20 206} -family body -size 10
}
# A LEAF cannot be resumed: what a P or a heading holds is text, and more text
# for it is a further mark on the same element - the road text -paginate takes
# by itself - not a further child.
$doc structure P -name closing -script {$doc text "A paragraph." -at {20 214}}
if {[catch {$doc structureResume closing -script {$doc text "more" -at {20 220}}} message options]} {
    puts "resuming a leaf: [dict get $options -errorcode]"
} else {
    puts "resuming a leaf: NOT REFUSED"
}
```

## Declaring PDF/UA

```tcl
# Off by default and explicit - a legally meaningful claim. Part 1 (ISO 14289-1)
# lifts the file to 1.7; "ua -part 2" is a PDF 2.0 format. Checked at the WRITE,
# all findings at once, each naming the call to change; no file is left behind.
$doc ua 1
puts "ua: [$doc ua state]"                ;# part revision wtpdf registered

# -revision is the year of the edition claimed, four digits, and goes into
# the metadata as pdfuaid:rev for part 2 (ISO 14289-2, Table 1); the default
# is 2024, the year part 2 was published. Anything that is not a four-digit
# year is refused at the call.
if {[catch {$doc ua -part 1 -revision 24} message]} {
    puts "refused, as it should be: $message"
} else {
    puts "ua -revision 24: NOT REFUSED"
}
$doc ua -part 1 -revision 2024
puts "ua after the revision: [$doc ua state]"
```

What it insists on: title, language, every font embedded, headings from `H1` with no level skipped and of one kind, tables whose rows cover the same number of columns (spans counted), a description on every link and every link annotation inside a `Link`, every picture/drawing/form either `-alt` or `-artifact 1`, lists whose numbering and labels agree, `DisplayDocTitle` still on. Part 2 (`ua -part 2 -wtpdf {reuse accessibility}`) adds a `Desc` on every attachment, forbids the generic `H` and `Note` (use `FENote`), and cannot be combined with `pdfa -part 3` - an accessible ZUGFeRD invoice is `ua 1` plus `pdfa -part 3`. Four more rules of part 2 are checked at the write and are shown below: every `TOCI` says what it points at (`-ref`, 8.2.5.8), a `FENote` and the content citing it name each other (8.2.5.14.1), no destination inside the document is a page destination (8.8 - so `link -page`, `bookmark -page` and `initialView -page` are refused and `-structure` is the way on), and one `Link` element holds one target (8.2.5.20). And `-numbering None` is not among the values a list may take where its items carry a `Lbl` (8.2.5.25): name the scheme the markers come closest to. `ua 0` withdraws the claim. Check with `verapdf --flavour ua1 file.pdf` (part 2: `ua2`) and read the tree with `pdfinfo -struct-text file.pdf`.

```tcl
$doc write [file join $out ref-09-tagged-ua.pdf]
$doc destroy
```

## Part 2, and the entry `-ref`

```tcl
# A document of its own, because ua -part 2 is a PDF 2.0 format and part 1 is
# not: the claim raises the file, and -ref, FENote and the 2.0 types come with
# it. Everything above holds here unchanged - a tree written for part 1 needs
# no redrawing, it needs -part 2.
set ua2 [tclpdf new -unit mm]
$ua2 tagged 1
$ua2 info Title "Reference: PDF/UA-2"
$ua2 language en-GB
$ua2 ua -part 2                      ;# raises the file to 2.0, so -ref may be used
$ua2 page add
$ua2 font embed body $ttf
$ua2 font embed bodyBold $ttfBold
$ua2 font -family bodyBold -size 15
$ua2 text "Part 2 and the entry -ref" -at {20 20} -tag H1

# A FOOTNOTE AND ITS CITATION POINT AT EACH OTHER (ISO 14289-2, 8.2.5.14.1):
# the content that cites the note names it, and the note names the citation.
# -name is this package's handle for an element and -ref names another element
# by that handle; the write turns the pair into the two /Ref arrays. Without
# both, [ua -part 2] refuses the claim - a footnote nobody cites is a footnote
# to nothing, and a marker naming no note leaves a reader nowhere to go.
$ua2 font -family body -size 10
set sentence "The marker after this sentence is the citation."
$ua2 structure P -script {
    $ua2 text $sentence -at {20 32}
    $ua2 structure Sub -name citation1 -ref footnote1 -script {
        $ua2 font -size 6
        $ua2 text "1" -at [list [expr {20 + [$ua2 textWidth $sentence -size 10]}] 30]
    }
}
$ua2 font -size 9
$ua2 structure FENote -name footnote1 -ref citation1 -script {
    $ua2 text "1) FENote is the 2.0 type for a footnote; the 1.7 type Note is\
        one of the two part 2 forbids, the generic H being the other." \
        -at {20 40} -width 170
}

# AND EVERY TOCI SAYS WHAT IT POINTS AT (8.2.5.8) - on the entry itself or on
# one of its children. The link inside it is a structure destination, which is
# what part 2 asks of every destination that stays inside the document (8.8):
# link -page, bookmark -page and initialView -page are refused under -part 2.
$ua2 font -family bodyBold -size 12
$ua2 text "Contents" -at {20 55} -tag H2
$ua2 font -family body -size 10
$ua2 structure TOC -script {
    $ua2 structure TOCI -ref appendix -script {
        $ua2 structure Reference -script {
            $ua2 text "Appendix" -at {20 63}
            $ua2 link -at {20 59.5} -size {30 5} -structure appendix \
                -tooltip "To the appendix"
        }
    }
}
$ua2 font -family bodyBold -size 12
$ua2 structure Sect -name appendix -script {
    $ua2 text "Appendix" -at {20 80} -tag H2
    $ua2 font -family body -size 10
    $ua2 text "The named element the entry above points at. A structure\
        destination survives the content moving; a page destination does not,\
        which is the whole of 8.8." -at {20 87} -width 170
}
$ua2 write [file join $out ref-09-ua2.pdf]
$ua2 destroy
```

The four part 2 rules that are checked when the file is written, each in a document of its own so that the code that answers is the one being shown:

```tcl
proc ua2Document {name} {
    upvar 1 $name doc ttf ttf
    set doc [tclpdf new -unit mm]
    $doc tagged 1
    $doc info Title "Refused"
    $doc language en-GB
    $doc ua -part 2
    $doc page add
    $doc font embed body $ttf
    $doc font -family body -size 10
    $doc text "Head" -at {20 20} -tag H1
}

# 1. A list numbered None whose items carry a Lbl (8.2.5.25). Part 1 allows
#    it - arbitrary markers - part 2 does not: name the scheme they come
#    closest to, or the 2.0 word Unordered.
ua2Document doc
$doc structure L -numbering None -script {
    $doc structure LI -script {
        $doc structure Lbl -script { $doc text "-" -at {20 30} }
        $doc structure LBody -script { $doc text "an item" -at {26 30} }
    }
}
# 2. A page destination inside the document (8.8).
ua2Document pages
$pages bookmark "Head" -page 0 -at {20 20}
# 3. A FENote nothing cites (8.2.5.14.1).
ua2Document note
$note structure FENote -name orphan -script { $note text "1) nobody cites this" -at {20 40} }
# 4. A TOCI that says nothing about what it points at (8.2.5.8).
ua2Document toc
$toc structure TOC -script { $toc structure TOCI -script { $toc text "Head" -at {20 40} } }

foreach {label handle} [list "None with a Lbl" $doc "a page destination" $pages \
        "a FENote nothing cites" $note "a TOCI with no -ref" $toc] {
    if {[catch {$handle write [file join $out ref-09-ua2-refused.pdf]} message options]} {
        puts "[format %-24s $label] [dict get $options -errorcode]"
    } else {
        puts "[format %-24s $label] NOT REFUSED"
    }
    $handle destroy
}
puts "file left behind: [file exists [file join $out ref-09-ua2-refused.pdf]]"

# The fifth rule falls at the CALL, because the element is open and the second
# link is right there: one Link element holds one target (8.2.5.20). Several
# annotations may share it as long as they all go to the same place - an icon
# and the word beside it - but two different targets need two elements.
ua2Document two
if {[catch {
    $two structure Link -script {
        $two text "one" -at {20 40}
        $two link -at {20 37} -size {10 5} -url https://a.example -tooltip one
        $two link -at {40 37} -size {10 5} -url https://b.example -tooltip two
    }
} message options]} {
    puts "two targets in one Link: [dict get $options -errorcode]"
} else {
    puts "two targets in one Link: NOT REFUSED"
}
$two destroy
```
