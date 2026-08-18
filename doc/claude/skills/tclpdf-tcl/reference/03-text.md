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
