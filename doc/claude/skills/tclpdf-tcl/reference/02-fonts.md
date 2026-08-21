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

### A fallback chain

```tcl
# -fallback names the faces that may set what -family cannot. Every character
# the family has no glyph for is taken from the FIRST face in the list that
# has it; the line falls into segments, one per face, each with its own font
# resource and its own ToUnicode map, so the text extracts whole and in order.
$doc font -family cff -size 10 -fallback {body}
$doc text "Nimbus Sans has no \u2714 - the chain sets that one glyph from DejaVu" -at {20 160}
$doc font -fallback {}                      ;# state like -size: clear it deliberately

# A character NO face in the chain has is refused exactly as before, and the
# message names every face that was asked.
if {[catch {$doc textWidth "\u4e2d" -family cff -fallback {body}} message]} {
    puts "chain exhausted: $message"
}
# -fallback and -direction rtl do not go together: a face change inside a
# right-to-left line would reorder only its own piece.
if {[catch {$doc text "\u05e9\u05dc\u05d5\u05dd" -at {190 166} -family body -direction rtl \
        -fallback {cff}} message]} {
    puts "rtl: $message"
}
```

Every face named has to be embedded already - a misspelt alias is refused at the call that wrote the option, not by whichever line first needs it. The option reaches everything the state reaches: a paragraph, a table cell, `textPath`, `leader`, `pageNumbers`.

### Rendering modes

```tcl
# What showing the text does to the outlines (the Tr operator). A word, not a
# number: fill (default), stroke, fillStroke, invisible. -stroke and
# -strokeWidth are read only in a mode that strokes.
$doc font -family body -size 20
$doc text "filled" -at {20 178}
$doc text "outlined" -at {55 178} -render stroke -stroke {0.15 0.25 0.55} -strokeWidth 0.3
$doc text "both" -at {105 178} -render fillStroke -color {0.95 0.85 0.4} \
    -stroke {0.3 0.2 0} -strokeWidth 0.25
$doc text "under the scan" -at {140 178} -render invisible    ;# positioned, extractable, painted nowhere
$doc font -render fill
```

`-strokeWidth` is a **line** width in the document unit, read in user space: 0.3 mm is 0.3 mm at every size - a rule round the letters, not a font weight. All three are font state like `-size`: set in `font` they stay, given per call they apply to that call.

## Kerning, ligatures, shaping

```tcl
$doc font -family body -size 11
$doc text "AVATAR office" -at {20 110}                       ;# kerning and liga on by default
$doc text "AVATAR office" -at {80 110} -kerning 0 -ligatures 0   ;# as an earlier release set it
$doc text "L E T T E R S P A C E D" -at {20 118} -spacing 1.5 -ligatures 0
```

`-kerning` reads GPOS, else the `kern` table, and writes the amounts into the stream - `textWidth`, the breaker and the table all measure with it. `-spacing` opens gaps between **glyphs**, so switch ligatures off for letterspacing.

### Combining marks

```tcl
# Text that arrives DECOMPOSED - U+0055 U+0308 where a composed Ü would be one
# character - is set from the face's own mark anchors (GPOS mark, mkmk, abvm,
# blwm). Both spellings come out the same and measure the same.
set composed "\u00dcbermut"
set decomposed "U\u0308bermut"
$doc font -family body -size 14
$doc text $composed -at {20 195}
$doc text $decomposed -at {60 195}
puts "composed [format %.3f [$doc textWidth $composed]] mm,\
    decomposed [format %.3f [$doc textWidth $decomposed]] mm"

# Marks stack on marks, and a combination Unicode has no composed form for is
# no different from one it has: a macron over an acute, a dot under a letter.
$doc text "\u0061\u0323\u0301 \u006f\u0304\u0301" -at {110 195}
```

A mark needs a face that carries the attachment lookups - an embedded one, in practice. The standard fourteen have none and refuse `U+0308` before the question arises, since it is outside WinAnsi. `textPath` places marks as well: a base and its marks are one cluster, turned once by the tangent, and the path steps by the width of the base. `-spacing` is the one option that counts glyphs rather than clusters, so the decomposed spelling opens one gap per mark that the composed one does not - `textWidth` counts the same gaps, which is why `-align` stays exact either way. What normalising to NFC still buys is a shorter string and one glyph instead of two, not a better result.

## Right-to-left and the writing systems

```tcl
# Hebrew, Thaana, Samaritan and the archaic RTL scripts need only ordering:
# -direction rtl turns the run; digits keep their order, brackets mirror.
# It is an option of the LINE, not of the font state.
$doc font embed hebrew $ttf                    ;# DejaVu Sans carries Hebrew and Arabic
$doc text "שלום עולם 4711 (2026)" -at {190 130} -family hebrew -direction rtl   ;# -at is the right edge

# The points travel with their letters: nikud and harakat are combining marks,
# and marks are placed from the face's anchors. Same width as the bare
# spelling - a mark has no advance.
$doc text "שָׁלוֹם" -at {190 140} -family hebrew -direction rtl

# Arabic gets its contextual forms from the face (isol/init/medi/fina, then rlig)
# and needs a face that carries those three features. How the face draws a
# letter no longer decides it: one that writes an undotted skeleton and hangs
# the dots on by GPOS is set with its dots on their anchors.
$doc text "الفاتورة 4711 - 1.234,50 €" -at {190 150} -family hebrew -direction rtl

# A mixed line is refused: set the runs as separate calls, one per direction.
if {[catch {$doc text "Rechnung 4711 שלום" -at {190 160} -family hebrew -direction rtl} message]} {
    puts "mixed line: $message"
}
# -unshaped 1 lifts every refusal and draws isolated glyphs in the order given -
# for the caller who knows; not the answer where -direction rtl is.
```

Refused, and measured so today: Syriac, N'Ko, Mongolian (contextual shaping), Devanagari and the other Indic scripts, Thai, Lao (reordering), the stacked Tibetan syllables (GSUB substitution) - the manual's table under "Writing systems" lists them, and it is the manual that says what the current release refuses. The refusal names the character and offers `-unshaped 1`. Nikud and harakat are no longer among them: they are combining marks like the Latin ones above, placed from the same anchors by the same lookups - one question, not two. `-direction` is taken by `text`, `textWidth`, `textLines`, `textPath`, `leader`, `pageNumbers`, and as a `direction` key of a table cell.

```tcl
$doc write [file join $out ref-02-fonts.pdf]
$doc destroy
```

## Type 3: a font whose glyphs are drawn

```tcl
# A font with no font program: every glyph is a content stream of this
# document, built from the same calls that draw a page. A document of its own
# here, because a drawn font stands on nothing else.
set marks [tclpdf new -unit mm]
$marks page add

# -ascent is the one number to remember: how far above the baseline the glyph
# frame begins, in glyph units. The default glyph space is 1000 to the em.
$marks font define ballot -ascent 750

# Inside -script the coordinates are GLYPH units, {0 0} is the top left of the
# frame, y grows downwards - a page in miniature. -width is the advance and is
# required. The character is what [text] will be given; the code, the glyph
# name and the ToUnicode entry all follow from it.
$marks font glyph ballot \u2610 -width 900 -color text -bbox {30 20 700 700} -script {
    $marks rect -at {50 50} -size {600 600} -stroke {0 0 0} -width 60
}
# -color own (the default) lets the glyph bring its own colours; -color text
# above writes d1 instead, so the glyph is painted in the colour of the text
# like a letter - and then -bbox is mandatory and binding.
$marks font glyph ballot \u2611 -width 900 -script {
    $marks rect -at {50 50} -size {600 600} -stroke {0.10 0.35 0.15} -width 60
    $marks path -segments {{move 170 380} {line 330 540} {line 640 180}} \
        -stroke {0.10 0.55 0.20} -width 90 -cap round
}
# Even the space is a glyph here: a Type 3 font has exactly the characters it
# was given, and a string with a blank in it is refused without this line.
$marks font glyph ballot " " -width 400 -script {}

# From here the alias is a family like any other.
$marks font -family ballot -size 12
$marks text "\u2611 \u2610 \u2611" -at {20 20}
puts "one ballot box is [format %.2f [$marks textWidth "\u2611" -family ballot -size 12]] mm wide"
if {[catch {$marks text "\u2612" -at {20 30} -family ballot} message]} {
    puts "no such glyph: $message"
}
$marks write [file join $out ref-02-type3.pdf]
$marks destroy
```

At most 255 glyphs, addressed as single bytes, so `-direction rtl` is refused as it is for every face addressed through an encoding. Under PDF/A the question of embedding does not arise - the glyphs **are** the file - and such a document passes B, U and A, PDF/UA included.
