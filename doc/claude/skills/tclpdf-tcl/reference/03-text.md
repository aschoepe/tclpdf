# Text: lines, paragraphs, flow, leaders, text on a path, page numbers

## One line

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add
$doc font embed body $ttf
$doc font embed bodyBold $ttfBold
$doc font -family body -size 10 -color black

# Without -width the string is ONE line; a line feed in it is refused.
$doc text "left on the point" -at {20 20}
$doc text "centred on the point" -at {105 20} -align center
$doc text "ends on the point" -at {190 20} -align right

# -anchor: what y means. baseline (default) or top.
$doc text "hanging from y = 26" -at {20 26} -anchor top

# Turned about -at; font options per call leave the state alone.
$doc text "turned" -at {150 40} -rotate 30 -family bodyBold -size 14 -color steelblue

# Measuring: the width in the document unit, with the options the drawing takes.
puts "width: [$doc textWidth "ends on the point" -size 10] mm"
```

The call without `-width` returns nothing. `-align` refers to the point; `centre` is accepted for `center`.



## A paragraph

```tcl
set body "A paragraph is asked for with -width. The line breaks at spaces and\
    at the break points UAX #14 allows; a no-break space (U+00A0) is glue and\
    keeps 12\u00a0€ together; a soft hyphen (U+00AD) in a word - Donau\u00addampf\u00adschiff -\
    is honoured where the breaker takes the offer and invisible everywhere else.\
    Justification stretches the U+0020 gaps only.\n\nA line feed separates paragraphs\
    inside one call, and -paragraphSpacing adds room between them."

# Returns the y under the last line - the next block continues there.
set y [$doc text $body -at {20 50} -width 80 -align justify -anchor top \
    -paragraphSpacing 2 -firstIndent 5]
puts "the paragraph ends at y = [format %.1f $y]"

# Indents narrow the column; a NEGATIVE first indent hangs the opening line out -
# how a numbered clause is set.
set y [$doc text "1.  The clause begins at the margin and its continuation lines\
    are indented under the text, not under the number." \
    -at [list 20 [expr {$y + 4}]] -width 80 -indent 8 -firstIndent -8]

# -indentRight narrows the column from the OTHER side - a quotation set in
# from both margins, without the block having to be measured and re-placed.
set y [$doc text "A quotation is set in from both margins, which is one option\
    on each side rather than a narrower -width at a moved -at." \
    -at [list 20 [expr {$y + 4}]] -width 80 -indent 6 -indentRight 6 -align justify]

# textHeight and textLines take it too, so a block is measured the way it
# will be set.
puts "indented both sides: [llength [$doc textLines $body -width 80 -indent 6 -indentRight 6]] lines,\
    plain: [llength [$doc textLines $body -width 80]]"

# What a paragraph would take, and how it would break, without drawing.
puts "height: [format %.1f [$doc textHeight $body -width 80 -paragraphSpacing 2 -firstIndent 5]] mm"
puts "lines:  [llength [$doc textLines $body -width 80]]"
```

Where a line breaks: at ASCII white space, U+2000..U+200A, U+3000, U+200B (zero width space, drawn by every face) and the rest of UAX #14's BA class; **never** at U+00A0, U+2007, U+202F. A tab or a stray CR is set as a space. U+FEFF is dropped. Extracting a line that took a soft-hyphen offer yields the hyphen too.

## Runs inside a paragraph: tags, Markdown, and the list

```tcl
# A bold word, an italic date, a link in the middle of flowing text: runs. The
# breaker runs over all of them and measures every piece in its own face.
# Helvetica here because a standard family brings its bold and oblique; an
# embedded face needs [font family] first - further down.
$doc page add

# -markup tags: <b> <i> <u> <s> <em> <strong> <a href="..."> <h1>..<h3> <p> -
# and nothing else between angle brackets is a tag. A "<" in front of a space,
# a digit or the end is text; in front of a letter it has to open a known tag,
# so a literal one is written &lt;. Braces rather than quotes: [text](url) in
# a double-quoted string is a command substitution.
set tagged {<h2>Payment</h2><p>The <b>amount</b> is due by <i>31 October</i>;\
    the price of <s>980.00 EUR</s> no longer applies and the <u>surcharge</u>\
    becomes due. Terms: <a href="https://fossil.sowaswie.de/tclpdf">project page</a>.</p>\
    A &lt;b> is text here, and so is a < 5 %.}
set y [$doc text $tagged -at {20 20} -width 80 -anchor top -markup tags -family helvetica]

# -markup markdown: **strong** *em* ***both*** ~~struck~~ [text](url), and
# "# ", "## ", "### " after a line feed open a heading that ends at the next.
# No underline - Markdown has no spelling for it - and "_" is always text.
set markdown {## Payment
The **amount** is due by *31 October*; the price of ~~980.00 EUR~~ no longer\
    applies and the surcharge becomes due. Terms: [project page](https://fossil.sowaswie.de/tclpdf).
A snake_case name is text here, and so is 5 * 3.}
set y [$doc text $markdown -at [list 20 [expr {$y + 6}]] -width 80 -anchor top \
    -markup markdown -family helvetica]

# -runs 1: the list both notations translate into, written by hand - what a
# program assembling a paragraph from data writes. Pairs {text options}:
# style bold|italic|{bold italic}, underline 1, strike 1, url address,
# heading 1|2|3 (a paragraph of its own). A run without options is {}.
set runs {
    "Payment" {heading 2}
    "The " {} "amount" {style bold} " is due by " {} "31 October" {style italic}
    "; the price of " {} "980.00 EUR" {strike 1} " no longer applies and the " {}
    "surcharge" {underline 1} " becomes due. Terms: " {}
    "project page" {url https://fossil.sowaswie.de/tclpdf} "." {}
}
set y [$doc text $runs -at [list 20 [expr {$y + 6}]] -width 80 -anchor top \
    -runs 1 -family helvetica]

# An embedded alias is ONE face: a bold run in "body" is refused rather than
# set regular in silence. [font family] ties embedded faces under one name -
# -regular is required, -bold, -italic, -boldItalic as far as the faces exist -
# and from then on -style bold, <b>, ** and {style bold} reach the bold face.
$doc font family dejavu -regular body -bold bodyBold
puts "family dejavu: [$doc font family dejavu]"     ;# without options: the registration
$doc text "Set in DejaVu Sans Bold through the family." \
    -at [list 20 [expr {$y + 6}]] -family dejavu -style bold -anchor top
set y [$doc text {The <b>amount</b> is bold, the rest regular - both embedded.} \
    -at [list 20 [expr {$y + 12}]] -width 80 -anchor top -markup tags -family dejavu]

# Refused by name: a style the family has no face for, and a run left open in
# either notation. Both read strictly: no fallback to plain text because one
# "*" was forgotten.
foreach {label script} [list \
        "italic in a family without one" \
            [list $doc text {"set " {} "slanted" {style italic}} -at {20 200} \
                -width 80 -runs 1 -family dejavu] \
        "a tag left open" \
            [list $doc text {an <b>open tag} -at {20 200} -width 80 \
                -markup tags -family helvetica] \
        "a Markdown run left open" \
            [list $doc text {an **open run} -at {20 200} -width 80 \
                -markup markdown -family helvetica]] {
    try {
        {*}$script
        puts "$label: went through, which it should not have"
    } on error {message options} {
        puts "$label -> [dict get $options -errorcode]"
    }
}

# textLines and textHeight take -markup and -runs as well, and every line comes
# back as a list of {text options} pairs - drawable again with -runs 1. ** is
# <strong>, not <b>: set alike, told apart only in a tagged document.
set fromTags [$doc textLines $tagged -width 80 -markup tags -family helvetica]
set fromMarkdown [$doc textLines $markdown -width 80 -markup markdown -family helvetica]
puts "line 2, tags:     [lindex $fromTags 1]"
puts "line 2, Markdown: [lindex $fromMarkdown 1]"
puts "height of the tagged block: [format %.1f [$doc textHeight $tagged -width 80 \
    -markup tags -family helvetica]] mm"
```

A run changes the face and what is drawn over or under it - never the size, the colour or the spacing, which belong to the paragraph and keep every line one height. A heading is a paragraph of its own at 1.6, 1.3 and 1.15 times the block's size, bold, and never the last line of a page or column. Runs and `-markup` need `-width` (`TCLPDF TEXT RUNS`), and `-markup` excludes `-runs 1`. Kerning ends at a run boundary. The *rest* of a height-limited block comes back as a list of runs, to be set again with `-runs 1`.

## Hyphenation: the patterns come from the caller

```tcl
package require tclpdf::hyphenate      ;# a package command, so it is required here

# tclpdf ships NO pattern files, and that is a licence decision: every
# published set carries terms of its own (LGPL, LPPL, BSD-style) and this
# package is MIT. The caller loads the file from wherever the machine keeps
# it - /usr/share/hyphen/ on most Linux systems, a LibreOffice dictionary
# extension on macOS and Windows - and the licence stays with the file.
# $hyphenPatterns is a libhyphen .dic; assets.tcl says where it points.
if {[info exists hyphenPatterns] && [file exists $hyphenPatterns]} {
    # -left/-right are how many letters must stay on either side of a break.
    # PASS -left 2 -right 2 FOR GERMAN: the file states neither, and the TeX
    # default of 3 on the right refuses the two-letter endings German breaks
    # off every day. -exceptions are written with - at the breaks and are
    # looked up before the patterns.
    # -min is the shortest word broken at all, 5 unless said otherwise.
    ::tclpdf::hyphenate load de $hyphenPatterns -left 2 -right 2 -min 5 \
        -exceptions {Wachs-tu-be Ur-in-stinkt}
    puts "loaded: [::tclpdf::hyphenate languages]"
    puts [::tclpdf::hyphenate languages de]        ;# tag patterns exceptions left right min

    # Where a word may break, as the pieces it falls into - for checking a
    # pattern file, and the same answer the line breaker uses. A word that may
    # not be broken comes back whole, which is also the answer for "no break
    # was found": neither is a failure.
    puts "word:      [::tclpdf::hyphenate word de Silbentrennung]"
    puts "exception: [::tclpdf::hyphenate word de Wachstube]"
    puts "left as it is: [::tclpdf::hyphenate word de www.example.org]"

    # -hyphenate 1 uses the language the DOCUMENT declares - so declare it.
    # Anything that is not the literal 0 or 1 is a language tag: "de-AT", and
    # "no" is Norwegian rather than a false value.
    $doc language de
    set german "Die Silbentrennung eines Flie\u00dftextes in einer schmalen Spalte ist der\
        Unterschied zwischen einer Absatzgestaltung und einem Flickenteppich aus\
        Wortzwischenr\u00e4umen."
    $doc font -family body -size 9
    $doc text $german -at {110 200} -width 38 -align justify -anchor top
    $doc text $german -at {152 200} -width 38 -align justify -anchor top -hyphenate 1
    puts "without: [llength [$doc textLines $german -width 38]] lines,\
        with: [llength [$doc textLines $german -width 38 -hyphenate 1]] lines"

    # A language that is not loaded is REFUSED by name, rather than set
    # unhyphenated in silence.
    if {[catch {$doc textLines $german -width 38 -hyphenate fr} message]} {
        puts "not loaded: $message"
    } else {
        puts "a language that was never loaded: NOT REFUSED"
    }
} else {
    puts "no pattern file here - point \$hyphenPatterns at one in assets.tcl"
}
```

What hyphenation buys is the word spaces of a narrow justified column, not usually a line. Soft hyphens the text already carries **win outright** over the patterns - it is one source or the other, never both. The hyphen that appears at a break is a real U+002D; in a tagged document it sits in a `Span` with an empty `ActualText`, so extracting the line gives the word back whole. `-hyphenate` is taken by `textLines` and `textHeight` as well, so a block is measured the way it will be set.

## Flowing around shapes

```tcl
# -avoid: the text is narrowed by whatever reaches into a line; a circle is
# followed by its outline. The shapes are NOT drawn - draw them yourself.
$doc rect -at {110 50} -size {30 20} -fill {0.9 0.92 0.96}
$doc circle -at {170 75} -radius 10 -fill {0.9 0.92 0.96}
set y [$doc text [string repeat "$body " 2] -at {110 50} -width 80 -anchor top \
    -align justify -avoidMargin 2 \
    -avoid {{rect {110 50} {30 20}} {circle {170 75} 10 4}}]   ;# a 4th element: a margin of its own
```

A line whose free segment is narrower than the widest character is left empty and the text goes on below the shape. `-avoid` with `textHeight` needs `-at`, because the shapes are page positions.

## A block with a height limit, and the rest

```tcl
$doc page add
lassign [$doc page typeArea] x0 y0 x1 y1
set width [expr {$x1 - $x0}]
set long [join [lrepeat 12 $body] "\n"]

# -height h: what fits is drawn, the answer is a dict {y rest}. rest is the tail
# of the string AS GIVEN - soft hyphens still soft, paragraph breaks where they were.
set result [$doc text $long -at [list $x0 $y0] -width $width -anchor top -height 60]
puts "60 mm took [expr {[string length $long] - [string length [dict get $result rest]]}] characters"

# -height max: down to the bottom of the type area of THIS page. Nothing is
# drawn under it; the caller keeps the loop.
set result [$doc text [dict get $result rest] -at [list $x0 [expr {[dict get $result y] + 6}]] \
    -width $width -anchor top -align justify -height max]
puts "page [expr {[$doc page current] + 1}] full at y = [format %.1f [dict get $result y]],\
    [string length [dict get $result rest]] characters left"
```

Without `-height` a paragraph knows nothing about the page: it runs on below it and only the returned y says so. `-height max` cannot be combined with `-rotate`.

## Pagination and columns: the package keeps the loop

```tcl
# -paginate 1: what fits goes here, a page is added with the document defaults,
# the text goes on from the top of the type area - as often as it takes.
# pageAdded fires on every page it adds. Needs -width; refuses -rotate and a
# numeric -height. Answer: {y rest page column}, rest always empty.
$doc page add
lassign [$doc page typeArea] x0 y0 x1 y1
set result [$doc text $long -at [list $x0 $y0] -width $width -anchor top \
    -align justify -firstIndent 5 -paginate 1]
puts "ended on page [expr {[dict get $result page] + 1}] at y = [format %.1f [dict get $result y]]"

# -columns n inside -width, -gutter apart, each filled to the bottom before the
# next; -balance 1 evens the last page. Wants -height max or -paginate.
$doc page add
lassign [$doc page typeArea] x0 y0 x1 y1
set result [$doc text $long -at [list $x0 $y0] -width $width -anchor top \
    -align justify -paginate 1 -columns 3 -gutter 6 -balance 1]
puts "ended in column [expr {[dict get $result column] + 1}] of 3,\
    [$doc page count] pages so far"
```

A picture between the columns: place it, then hand its rectangle to `-avoid` - every column of that page flows round it. `-avoid` holds on the first page of a paginated run only and not together with `-balance`. In a tagged document a paginated run stays **one** paragraph.

## Leader rows: contents, price lists, totals

```tcl
$doc page add
$doc font -family body -size 10
set y 30
set y [$doc leader "1. Introduction" "3" -at [list 20 $y] -width 120]
set y [$doc leader "2. Embedding fonts" "24" -at [list 20 $y] -width 120]
set y [$doc leader "Total" "1.234,50 €" -at [list 20 $y] -width 120 -fill ""]   ;# no fill: a sum under a rule
set y [$doc leader "Subtotal" "980,00" -at [list 20 $y] -width 120 -fill "- " -gap 2]
```

Both ends are one line each and never wrap; the remainder stays in front of the right hand end so figures line up. Returns the y one line down. In a tagged document the row is one element and the fill an artifact; `-tag Artifact` (or `-tag {Artifact Pagination Header}`) takes the whole row out of the tree.

## Text on a path

```tcl
# The segments are the ones "path" takes; the path itself is not drawn.
set arc {{move 30 120} {curve 30 90 90 90 90 120}}
$doc path -segments $arc -stroke {0.85 0.85 0.9} -width 0.3        ;# drawn here to show it
set length [$doc textPath "along the curve" -segments $arc -align center -offset 1 \
    -family bodyBold -size 10 -color steelblue]
puts "path length: [format %.1f $length] mm"
```

Glyphs that run past the end are dropped rather than piled up - measure the string against the returned length first. `-offset` positive lifts the baseline off the path, negative puts it below. `-direction rtl` runs the glyphs backwards and mirrors `-align`.

## Page numbers - drawn at write time

```tcl
# The only moment the total is known is the write, so the call may come first.
$doc font -family body -size 8 -color {0.35 0.35 0.4}
$doc pageNumbers -at {190 287} -align right -format "page %n of %m"
$doc pageNumbers -at {105 287} -align center -format "vol. 1" -family bodyBold -size 7
# -from leaves leading pages unnumbered, -total states a total of a larger set:
# $doc pageNumbers -at {20 287} -from 2 -total 12 -format "sheet %n of %m"
```

Each call is independent and takes the font options on its own. `%n` is the number, `%m` the total. Above the middle of the page it becomes a `Pagination Header` artifact, below a `Footer`. Printed numbers and page labels have to agree - see `08-navigation-metadata.md`.

```tcl
$doc write [file join $out ref-03-text.pdf]
$doc destroy
```

## The four anchors, and fitting a line into a box

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add
$doc font -family helvetica -size 16

# -anchor says what y MEANS, and all four measure the FACE's line box - its
# ascender above the baseline and its descender below - not the ink the string
# happens to carry. That is what makes "Text" and "Type" line up.
#
#   baseline  the default
#   top       the ascender sits at y
#   middle    the line's box is centred on y
#   bottom    the descender sits at y
set x 20
foreach anchor {baseline top middle bottom} {
    $doc text "Typo" -at [list $x 40] -anchor $anchor
    set x [expr {$x + 42}]
}

# -fit puts ONE line into a box: the letters are squeezed first, up to
# -shrinkLimit (85 per cent by default), and only what is still missing comes
# out of the size. A face narrowed a few per cent is barely visible in one
# line; a smaller size is visible at once beside its neighbours.
$doc font -size 20
$doc text "Rechnungsnummer 2026-0815" -at {20 60} -fit {60 8}

# -shrinkLimit 100 forbids narrowing and takes all of it out of the size,
# which is what a caller setting text beside other text at one width wants.
$doc text "Rechnungsnummer 2026-0815" -at {20 75} -fit {60 8} -shrinkLimit 100

# The height is answered first and separately: a box too low brings the size
# down, and the width is then worked out against the new size.
$doc text "Rechnungsnummer 2026-0815" -at {20 90} -fit {100 3}
```

`-fit` and `-width` are refused together (`TCLPDF TEXT FIT WIDTH`): one puts a single line into a rectangle, the other breaks a paragraph into as many lines as it takes. There is no `-align`/`-valign` here — on a line `-align` already means the typographic alignment. An anchor that is none of the four is refused with `TCLPDF TEXT ANCHOR` rather than read as `baseline`.

## The break of last resort

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add
$doc font -family helvetica -size 10

# A word longer than the column is broken by CHARACTER rather than let run
# past the edge. -emergencyHyphen marks that break - OFF by default, because
# the words that reach this fallback are as often a part number, a file path
# or a URL as a long word, and a hyphen inside one of those is a character the
# reader copies and a wrong value.
set word "Donaudampfschifffahrtsgesellschaftskapitaen"
$doc text $word -at {20 20} -width 32
$doc text $word -at {80 20} -width 32 -emergencyHyphen 1

# The hyphen is measured WITH the piece rather than hung on after it, so the
# marked lines carry one character fewer and the line stays inside the column.
puts [$doc textLines $word -width 32 -emergencyHyphen 1]

# -hyphens 1 reports which lines carry one, so a caller drawing them himself
# can say so with [text -breakHyphen].
foreach line [$doc textLines $word -width 32 -emergencyHyphen 1 -hyphens 1] {
    puts "[dict get $line text] (break hyphen: [dict get $line hyphen])"
}
```

A column too narrow to hold one letter *and* a hyphen drops the hyphen rather than the letter.
