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

# What a paragraph would take, and how it would break, without drawing.
puts "height: [format %.1f [$doc textHeight $body -width 80 -paragraphSpacing 2 -firstIndent 5]] mm"
puts "lines:  [llength [$doc textLines $body -width 80]]"
```

Where a line breaks: at ASCII white space, U+2000..U+200A, U+3000, U+200B (zero width space, drawn by every face) and the rest of UAX #14's BA class; **never** at U+00A0, U+2007, U+202F. A tab or a stray CR is set as a space. U+FEFF is dropped. Extracting a line that took a soft-hyphen offer yields the hyphen too.

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
    ::tclpdf::hyphenate load de $hyphenPatterns -left 2 -right 2 \
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
