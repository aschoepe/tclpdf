# Tables

## The basic table

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add
$doc font embed body $ttf
$doc font embed bodyBold $ttfBold

# A row is a list of cells; a cell is a string or a dictionary. Returns the y below.
set y [$doc table -at {20 20} -width 170 -theme striped \
    -head {{Item Qty "Unit price" Total}} \
    -body {
        {"Kiln shelf 40 x 40" 4 18.20 72.80}
        {"Batt wash, 1 kg" 2 6.50 13.00}
        {"Cones 06, box of 50" 1 24.90 24.90}
    } \
    -foot {{{text "Total" colSpan 3 align right} 110.70}} \
    -columns {{} {width 16 align right} {width 28 align decimal} {width 28 align decimal}} \
    -style {family body size 9} -headStyle {family bodyBold}]
puts "the table ends at y = [format %.1f $y]"
puts "themes: [$doc table themes]"
```

Without `-width` the table takes the page width less twice the larger of its left edge and 10. Column widths resolve fixed (`width`), weighted (`weight`), then automatic; there is no percent - `weight` is the share. Fixed widths that overrun the table, or use it up while a column has none, are refused.

## Cells: strings, dictionaries, spans, alignment

```tcl
# A cell is read as a dictionary when its FIRST word is a cell key (text colSpan
# rowSpan align valign direction style) and the word count is even. A plain string
# that happens to start with one of those - write it as {text "..."}.
set y [$doc table -at [list 20 [expr {$y + 8}]] -width 170 -theme grid \
    -head {{{text "Region" rowSpan 2} {text "Sales" colSpan 2} {text "Notes" rowSpan 2}} {{"2025" "2026"}}} \
    -body {
        {"North" 120 134 {text "text starts this sentence" }}
        {"South" 98 101 {text "" valign middle}}
        {{text "All regions" colSpan 1 align right style {fontStyle bold}} 218 235 {text "n/a" align center}}
    } \
    -columns {{width 30} {align decimal} {align decimal} {}} \
    -style {family body size 9 padding 2} -headStyle {family bodyBold fill {0.90 0.92 0.96}}]
```

Rows tied by a `rowSpan` never split across a page. Unknown keys and out-of-range values are errors - in a cell, a style, a column description and among the options.

## Styles and themes

Style keys, read at every level - `-style`, `-headStyle`/`-bodyStyle`/`-footStyle`, a column, a cell's `style` - the most specific wins: `family fontStyle size leading padding fill color align valign direction hyphenate border lineColor lineWidth`. A theme (`plain`, `striped`, `grid`) is a set of these.

```tcl
set y [$doc table -at [list 20 [expr {$y + 8}]] -width 80 -theme plain \
    -head {{Item Sum}} -body {{parts 18.20} {labour 45.00}} -foot {{total 63.20}} \
    -style {family body size 9 border outer lineWidth 0.3 leading 1.4} \
    -headStyle {fill {0.20 0.30 0.45} color white fontStyle bold} \
    -footStyle {fill {0.90 0.92 0.96} fontStyle bold} \
    -alternateFill {0.97 0.97 0.98} -minRowHeight 7 \
    -columns {{} {align decimal}}]

# -decimal picks the separator (default "."): a German column of amounts.
$doc table -at [list 110 [expr {$y - 22}]] -width 40 -theme plain -decimal , \
    -head {{Betrag}} -body {{1.234,50} {98,00} {7,25} {100}} \
    -columns {{align decimal}} -style {family body size 9}
```

`border` takes `none all horizontal vertical outer`; `outer` frames the block once per page. The theme greys are DeviceGray and pass every PDF/A intent; the blue head of `striped` is RGB - under a CMYK intent override it with `-headStyle {fill {cmyk …}}`. `-align decimal`: a cell without the separator lines up with the integer parts, a non-number sits there too.

## Right-to-left cells

```tcl
$doc font embed hebrew $ttf
$doc table -at [list 20 [expr {$y + 8}]] -width 120 -theme grid \
    -body {{{text "שלום עולם" direction rtl} {text "4711" align right}}} \
    -style {family hebrew size 10}
```

`direction` is a cell key, because an invoice has an RTL description column and an LTR amount column on one row. Under `rtl` the cell's `align` is mirrored (`left` = flush right). A `decimal` column does not mirror.

## Breaking over pages: -top and -bottom, repeated head, hooks

```tcl
$doc page add
set rows {}
for {set i 1} {$i <= 90} {incr i} {
    lappend rows [list $i "Specimen $i" [expr {60 + ($i * 7) % 45}] [format %.2f [expr {$i * 1.75}]]]
}
# -at is where THIS table starts; -top where it resumes on every later page,
# -bottom how far it may run - both default to the type area of each page.
set y [$doc table -at {20 40} -width 170 -theme grid \
    -head {{No. Specimen "Weight (g)" Price}} -body $rows \
    -columns {{width 14 align right} {} {width 30 align right} {width 30 align decimal}} \
    -style {family body size 8} -headStyle {family bodyBold} \
    -top 26 -bottom 275 -repeatHead 1 -repeatFoot 1 \
    -didParseCell {apply {{cell doc} {
        # Before measuring - a change of style still affects the wrap.
        if {[dict get $cell section] eq "body" && [dict get $cell column] == 2
                && [dict get $cell text] > 95} {
            dict set cell style {color {0.70 0.15 0.10} fontStyle bold}
        }
        return $cell                       ;# a returned dictionary replaces the cell
    }}} \
    -willDrawCell {apply {{cell doc} {
        # 0 skips the cell, rules and all.
        expr {[dict get $cell text] ne "Specimen 13"}
    }}} \
    -didDrawCell {apply {{cell doc} {
        # After drawing: overlay something at the cell's own place.
        if {[dict get $cell section] eq "body" && [dict get $cell column] == 0
                && [dict get $cell text] % 30 == 0} {
            $doc line -from [list [dict get $cell x] [dict get $cell y]] \
                -to [list [expr {[dict get $cell x] + [dict get $cell width]}] [dict get $cell y]] \
                -stroke crimson -width 0.5
        }
    }}} \
    -didDrawPage {apply {{payload doc} {
        # Once per page: a running head from page two of the table on.
        $doc font -family helvetica -size 7 -color {0.45 0.45 0.5}
        $doc text "Specimen register, page [expr {[dict get $payload page] + 1}]" -at {20 20}
    }}}]
puts "the register ends on page [expr {[$doc page current] + 1}] at y = [format %.1f $y]"
```

Each hook receives a dictionary and the document. `didParseCell` sees the cell keys plus `row column section`; the draw hooks add `lines width height leading resolved x y spanHeight decimal tail`; `didDrawPage` gets `page` and `y`. A head plus first row that does not fit below `-at` starts on the next page instead of leaving the head alone. `-horizontalBreak 1` deals a too-wide table over further pages, `-repeatColumns n` keeps the leading columns on each.

## Measuring without drawing

```tcl
# Answers widths, height, and per section the measured cells and row heights.
set layout [$doc table layout -width 170 -body $rows -style {family body size 8}]
puts "90 rows would take [format %.1f [dict get $layout height]] mm; columns: [dict get $layout widths]"
puts "body row heights: [lrange [dict get $layout bodyHeights] 0 2] ..."
```

## Cells set as runs, and cells in a notation (1.6)

```tcl
# "runs" is a content key beside "text": the {text options} pairs of [text -runs 1],
# built from data. "markup" is a STYLE key like hyphenate: plain (the default),
# tags or markdown say how the cell's TEXT is read - once for a column, or on a
# cell. The string stays under text; {markup {markdown ...}} as a pair is refused.
# A text the notation finds nothing to mark in stays a plain cell - figures in a
# decimal column under a Markdown table are figures.
$doc font family report -regular body -bold bodyBold
set client "Weber & Sohn"
set y [$doc table -at [list 20 [expr {$y + 8}]] -width 170 -theme striped \
    -head {{Date {text "**Activity**" markup markdown} Hours}} \
    -body [list \
        {"2026-09-01" "**Mueller GmbH** - kick-off, see [ticket](https://example.org)" 3.5} \
        [list "2026-09-04" [list runs [list $client {style bold} " - on-site training" {}]] 4] \
        {"2026-09-05" {text "<b>Schmidt AG</b> - <u>final acceptance</u>" markup tags} 1} \
        {"2026-09-06" {text "the **markers** stay as typed" markup plain} 0.5}] \
    -columns {{width 24} {markup markdown} {width 18 align decimal}} \
    -style {family report size 9}]
# The row is as tall as the bold words make it; the first baseline of a cell of
# runs is the baseline of the plain cell beside it. Hooks see "lines" of such a
# cell as a list of pair lists and the pairs under "runs".
# Refused by name, before a cell is drawn: text AND runs in one cell, an odd list,
# runs beside a markup (CELL markup), a markup other than plain|tags|markdown
# (TCLPDF TABLE STYLE markup),
# runs in a decimal column (a BODY cell - a head or foot cell of runs over such a
# column is set flush right like a plain heading), a heading or list item in a
# cell, an rtl cell, and a notation left open - nothing falls back to plain text
# in silence.
if {[catch {$doc table -at {20 300} -width 60 -theme plain \
        -body {{{runs {"1.50" {style bold}}}}} -columns {{align decimal}}} msg]} {
    puts "refused: $msg"
} else {
    puts "NOT REFUSED: runs in a decimal column went through, which it should not have"
}
# The fallback a caller may want - a lone asterisk in text typed by people - is
# the caller's to write: in -didParseCell, try ::tclpdf::markdown::parse on the
# cell's text yourself and set "markup plain" on the cell where it fails
# (examples/04.05-table-markup.tcl shows it).
```

```tcl
$doc write [file join $out ref-06-tables.pdf]
$doc destroy
```
