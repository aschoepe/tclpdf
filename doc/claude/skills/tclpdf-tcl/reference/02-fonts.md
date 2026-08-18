# Fonts: the standard fourteen, embedding, the font state

## The font state

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add

# The state stays in force until changed. -size is ALWAYS in points, whatever the unit.
$doc font -family helvetica -style bold -size 14 -color {0.20 0.30 0.45}
$doc text "The state" -at {20 20}
$doc font -style {} -size 10 -color black          ;# -style {} clears bold/italic

# Without arguments: the state as a dictionary, resolved font name included.
puts [$doc font]

# The rest of the state: glyph spacing, word spacing, horizontal scaling in
# percent, line spacing, baseline shift.
$doc font -spacing 0.5 -wordSpacing 1 -stretch 95 -leading 14 -rise 0
$doc text "spaced, stretched, on a 14 pt leading" -at {20 30}
$doc font -spacing 0 -wordSpacing 0 -stretch 100 -leading {}   ;# {} restores 1.2 x size
$doc text "H" -at {20 40}
$doc text "2" -at {24 40} -rise -2 -size 7                     ;# subscript, per call
$doc text "O" -at {27 40}
```

Every option is checked where it is written: a `-size` or `-stretch` of 0 or less, a `-leading` that is not a number above zero, an unknown `-color` are refused at the call - not at the next piece of text.

## The fourteen standard faces

```tcl
set y 44
foreach family {helvetica times courier} {
    $doc font -family $family -style {} -size 10
    $doc text "$family regular" -at [list 20 [incr y 6]]     ;# braces would not substitute: [list ...]
    $doc font -style bold
    $doc text "$family bold" -at [list 80 $y]
    $doc font -style italic
    $doc text "$family italic" -at [list 140 $y]
}
# symbol and zapfdingbats: no -style. arial is another name for helvetica.
$doc font -family symbol -style {} -size 12
$doc text "abgd" -at {20 70}
$doc font -family zapfdingbats
$doc text "3456" -at {40 70}

# An exact PostScript name names the FACE itself, so a -style in force does not apply to it.
$doc font -family Times-BoldItalic -size 10
$doc text "Times-BoldItalic by its PostScript name" -at {20 78}
```

The standard faces reach the 224 positions of WinAnsiEncoding and nothing else: `€`, `Ü`, `–` are fine, `Ł`, `Č`, `→` are refused as characters the face has no glyph for. `oblique` is read as `italic`; any other style word is refused. Under PDF/A and PDF/UA the standard faces are not allowed at all - see `10-pdfa-zugferd.md` for what stands in for them.

## Embedding

```tcl
# TrueType: subset to the glyphs used, kerning and ligatures from its tables. (PDF 1.2)
$doc font embed body $ttf
$doc font embed bodyBold $ttfBold

# OpenType/CFF: goes in whole as FontFile3, no subset, no subset prefix. (PDF 1.6)
$doc font embed cff $otf

# Type 1 (.pfb/.pfa/.t1): whole, addressed through WinAnsi, and its AFM has to be
# beside it - -metrics names it where it sits elsewhere.
$doc font embed t1 $type1
# $doc font embed t1 $type1 -metrics /somewhere/else/NimbusSans-Regular.afm

# A variable font: each point on the axes is its own embedded instance.
$doc font embed narrow $variable -axes {wght 300}
$doc font embed heavy  $variable -instance "Black"          ;# a name from the font's own table
# -instance and -axes combine: the instance is the starting point, -axes overrides single axes.

$doc font -family body -style {} -size 10 -color black
$doc text "Ł ó d ź, İstanbul, Москва - characters outside WinAnsi need an embedded face" -at {20 90}
$doc font -family narrow
$doc text "wght 300" -at {20 98}
$doc font -family heavy
$doc text "Black" -at {50 98}
```

The alias is what `-family` takes from then on. `-subset 0` embeds every glyph (still as the instance for a variable face). The file says what it is; the extension is not consulted.

### What the face can and cannot do

```tcl
puts "embedded: [$doc font names]"
puts [$doc font info body]        ;# family postScript glyphs unitsPerEm characters fsType permission

# A character the face has no glyph for is an ERROR, not a blank. Test before
# trusting a font viewer: viewers substitute silently, a PDF cannot.
if {[catch {$doc textWidth "Łódź" -family helvetica} message]} {
    puts "refused, as it should be: $message"        ;# WinAnsi has no Ł
}
if {[catch {$doc textWidth "中" -family body} message]} {
    puts "refused, as it should be: $message"        ;# DejaVu Sans has no CJK
}
```

The message names the face, the character as `U+XXXX` and its position. (`✔` U+2714 and `😀` U+1F600, by the way, ARE in DejaVu Sans - measure, do not guess.) `text`, `textWidth`, a table cell and text inside an SVG all refuse alike. `fc-list ':charset=2714'` names installed faces that carry a character; `hb-shape font.ttf --unicodes U+2714` answers `.notdef` when a file lacks it.

## Kerning, ligatures, shaping

```tcl
$doc font -family body -size 11
$doc text "AVATAR office" -at {20 110}                       ;# kerning and liga on by default
$doc text "AVATAR office" -at {80 110} -kerning 0 -ligatures 0   ;# as an earlier release set it
$doc text "L E T T E R S P A C E D" -at {20 118} -spacing 1.5 -ligatures 0
```

`-kerning` reads GPOS, else the `kern` table, and writes the amounts into the stream - `textWidth`, the breaker and the table all measure with it. `-spacing` opens gaps between **glyphs**, so switch ligatures off for letterspacing. Text arriving decomposed (U+0055 U+0308 for `Ü`) comes out with displaced accents - normalise to NFC first; GPOS mark attachment is not read.

## Right-to-left and the writing systems

```tcl
# Hebrew, Thaana, Samaritan and the archaic RTL scripts need only ordering:
# -direction rtl turns the run; digits keep their order, brackets mirror.
# It is an option of the LINE, not of the font state.
$doc font embed hebrew $ttf                    ;# DejaVu Sans carries Hebrew and Arabic
$doc text "שלום עולם 4711 (2026)" -at {190 130} -family hebrew -direction rtl   ;# -at is the right edge

# Arabic gets its contextual forms from the face (isol/init/medi/fina, then rlig)
# and needs a face with whole letters; a face that dots its skeleton with GPOS
# marks is refused with the reason.
$doc text "الفاتورة 4711 - 1.234,50 €" -at {190 140} -family hebrew -direction rtl

# A mixed line is refused: set the runs as separate calls, one per direction.
if {[catch {$doc text "Rechnung 4711 שלום" -at {190 150} -family hebrew -direction rtl} message]} {
    puts "mixed line: $message"
}
# -unshaped 1 lifts every refusal and draws isolated glyphs in the order given -
# for the caller who knows; not the answer where -direction rtl is.
```

Refused, deliberately: Hebrew nikud and Arabic harakat (mark placement), Syriac, N'Ko, Mongolian (contextual shaping), Devanagari and the other Indic scripts, Thai, Lao (reordering) - the manual's table under "Writing systems" lists them. `-direction` is taken by `text`, `textWidth`, `textLines`, `textPath`, `leader`, `pageNumbers`, and as a `direction` key of a table cell.

```tcl
$doc write [file join $out ref-02-fonts.pdf]
$doc destroy
```
