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

The drawing does not change; a second, invisible layer says what the marks **are**. `text` becomes a `P`, `table` a `Table` with `TR`/`TH`/`TD` (fills and rules artifacts), `image`/`svg`/`form place` a `Figure` with `-alt` or an artifact without. `structure` is for the grouping a writer cannot infer.

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
# target that stays right after the content above it has moved. Needs a 2.0
# file (ua -part 2 gives one); in 1.7 the name is accepted and the link uses -page.
$doc structure Sect -name appendix -script {
    $doc text "Appendix" -at {20 200} -tag H2 -family bodyBold -size 12
}
$doc bookmark "Appendix" -page 0 -at {20 200}
```

## Attributes, ids, the rest of `structure`

`-scope Row|Column|Both` belongs on a `TH`; `-bbox` on `Figure`, `Formula`, `Table`; `-colSpan`/`-rowSpan` on a cell (the table writes them itself); `-lang` a language tag for one element; `-actualText`, `-title`; `-id` an element identifier for the `IDTree` (a `Note` gets one by itself). Each is refused where the standard does not allow it. `-script` may be empty but not missing. Types beyond 1.7 (`Title`, `Aside`, `Em`, `Strong`, `Sub`, `FENote`, `H7`..`H10`) need a 2.0 file. Inline types (`Span`, `Em`, `Strong`, `Quote`, `Sub`) need a text-holding parent; a `P` inside a `P` is refused (Annex L).

## Declaring PDF/UA

```tcl
# Off by default and explicit - a legally meaningful claim. Part 1 (ISO 14289-1)
# lifts the file to 1.7; "ua -part 2" is a PDF 2.0 format. Checked at the WRITE,
# all findings at once, each naming the call to change; no file is left behind.
$doc ua 1
puts "ua: [$doc ua state]"                ;# part revision wtpdf registered
```

What it insists on: title, language, every font embedded, headings from `H1` with no level skipped and of one kind, tables whose rows cover the same number of columns (spans counted), a description on every link and every link annotation inside a `Link`, every picture/drawing/form either `-alt` or `-artifact 1`, lists whose numbering and labels agree, `DisplayDocTitle` still on. Part 2 (`ua -part 2 -wtpdf {reuse accessibility}`) adds a `Desc` on every attachment, forbids the generic `H` and `Note`, and cannot be combined with `pdfa -part 3` - an accessible ZUGFeRD invoice is `ua 1` plus `pdfa -part 3`. `ua 0` withdraws the claim. Check with `verapdf --flavour ua1 file.pdf` (part 2: `ua2`) and read the tree with `pdfinfo -struct-text file.pdf`.

```tcl
$doc write [file join $out ref-09-tagged-ua.pdf]
$doc destroy
```
