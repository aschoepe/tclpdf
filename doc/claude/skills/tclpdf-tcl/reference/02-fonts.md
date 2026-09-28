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
# An embedded alias is ONE face: -style bold reaches nothing until [font family]
# ties the faces of a family under one name - shown in 03-text.md, "Runs".
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
} else {
    puts "Ł in a standard 14 face: NOT REFUSED"
}
if {[catch {$doc textWidth "中" -family body} message]} {
    puts "refused, as it should be: $message"        ;# DejaVu Sans has no CJK
} else {
    puts "CJK in DejaVu Sans: NOT REFUSED"
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
} else {
    puts "a character no face in the chain has: NOT REFUSED"
}
# -fallback and -direction rtl do not go together: a face change inside a
# right-to-left line would reorder only its own piece.
if {[catch {$doc text "\u05e9\u05dc\u05d5\u05dd" -at {190 166} -family body -direction rtl \
        -fallback {cff}} message]} {
    puts "rtl: $message"
} else {
    puts "-fallback with -direction rtl: NOT REFUSED"
}
```

Every alias named has to be embedded already - a misspelt one is refused at the call that wrote the option, not by whichever line first needs it. A standard family may stand in the chain too, and `-style` applies to it exactly as it applies to `-family`. The option reaches everything the state reaches: a paragraph, a table cell, `textPath`, `leader`, `pageNumbers`.

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

`-kerning` reads GPOS, else the `kern` table, and writes the amounts into the stream - `textWidth`, the breaker and the table all measure with it. `-spacing` opens gaps between **glyphs**, so switch ligatures off for letterspacing. `-ligatures` reads **two** features and switches both: `liga` and `clig`, the contextual ligatures - the registry has both on by default and a shaper applies both unasked. `dlig` and `hlig` stay off, which is what the registry says; the required ligatures `rlig` of a cursive script belong to the shaping and are applied under `-direction rtl` whether or not `-ligatures` is on.

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
} else {
    puts "a mixed-direction line: NOT REFUSED"
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
# name and the ToUnicode entry all follow from it. It may also be a whole
# character SEQUENCE - then the glyph stands for all of it, with one advance
# and one character code, and [text] finds it by the longest match.
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

# A glyph may stand for a SEQUENCE rather than for one character: one drawing,
# one advance, one character code, and the whole sequence in /ToUnicode. That
# is what an emoji face needs for a family or a flag, and what [colorFont]
# below builds on. [text] finds it by the LONGEST match, so the pair below is
# one glyph while either box on its own is still its own.
$marks font glyph ballot "\u2611\u2610" -width 1500 -script {
    $marks rect -at {50 50} -size {600 600} -stroke {0.10 0.35 0.15} -width 60
    $marks rect -at {800 50} -size {600 600} -stroke {0 0 0} -width 60
}

# From here the alias is a family like any other.
$marks font -family ballot -size 12
$marks text "\u2611 \u2610 \u2611" -at {20 20}
puts "one ballot box is [format %.2f [$marks textWidth "\u2611" -family ballot -size 12]] mm wide"
puts "the pair is one glyph: [format %.2f [$marks textWidth "\u2611\u2610" \
    -family ballot -size 12]] mm against [format %.2f [expr {
        [$marks textWidth "\u2611" -family ballot -size 12]
            + [$marks textWidth "\u2610" -family ballot -size 12]}]] mm apart"
if {[catch {$marks text "\u2612" -at {20 30} -family ballot} message]} {
    puts "no such glyph: $message"
} else {
    puts "a glyph the Type 3 font was not given: NOT REFUSED"
}
$marks write [file join $out ref-02-type3.pdf]
$marks destroy
```

At most 255 glyphs, addressed as single bytes, so `-direction rtl` is refused as it is for every face addressed through an encoding. A glyph may stand for a **sequence** of characters rather than for one - `font glyph fam "a\u200Db" -width 900 -script {...}` - which is what an emoji face needs and what `colorFont` below builds on: one drawing, one advance, and a `ToUnicode` entry carrying every code point back. Under PDF/A the question of embedding does not arise - the glyphs **are** the file - and such a document passes B, U and A, PDF/UA included.

## A colour font: the colour glyphs of a COLR face, drawn as Type 3

`colorFont` is the other road out of the refusal above. A face whose pictures sit in a `COLR`/`CPAL` table leaves the outline of every character it covers empty, so `font embed` refuses it (`TCLPDF FONT OUTLINES`) rather than write a document that is valid, extractable and blank. `colorFont` reads the layers and their palette colours out of the face and draws each of them into a **Type 3** glyph - the section above, built by the package instead of by hand - and returns the alias, which from then on is a family like any other.

**`-chars` takes text, and the package finds the sequences in it.** An emoji face draws a family, a skin-tone variant and a flag as **one** glyph each, and that glyph has no character of its own: it is a `GSUB` ligature over several, under the face's `ccmp` feature. So `-chars "👨‍👩‍👧👍🏽🇩🇪"` gives **three** glyphs, each one glyph with one width, and `pdftotext` gives the whole sequence back - joiners, modifiers and variation selectors included. Nobody takes the string apart beforehand: which characters belong together is a property of the face. A sequence is offered to a `-fallback` chain as one unit, and the longest *registered* sequence wins over the single characters it is made of - a unit longer than one character is only ever offered to a face that holds that very sequence as a glyph, so a plain family cannot jump the chain by being able to spell a stretch of letters.

```tcl
# Scaffolding, not tclpdf: a COLR version 0 face assembled in memory, because
# NO COLOUR FONT SHIPS WITH THIS PACKAGE (the faces that carry one are emoji
# artwork under a licence of its own) and a caller normally hands the call a
# file that came out of a font editor. Two of the commands below are NOT part
# of the API - [glyfOutline compose] writes the point array of one glyph,
# [subset::Assemble] puts a table directory with checksums round a set of
# tables - because assembling a font is not what this package is for.
package require tclpdf::glyfOutline
package require tclpdf::subset

# One glyph as glyf bytes, from contours of {x y} points; straight lines only.
proc refFaceGlyph {contours} {
    set ends {}
    set flags {}
    set xs {}
    set ys {}
    set count 0
    foreach contour $contours {
        foreach point $contour {
            lassign $point x y
            lappend flags 1                       ;# 1 is ON_CURVE, a corner
            lappend xs $x
            lappend ys $y
            incr count
        }
        lappend ends [expr {$count - 1}]
    }
    return [::tclpdf::glyfOutline compose [dict create type simple \
        ends $ends flags $flags x $xs y $ys instructions {} bounds {0 0 0 0}]]
}

# COLR version 0 (ISO/IEC 14496-22, 5.7.11): a header, one record per base
# glyph saying where its layers begin and how many there are, and the layer
# records - each a glyph number and a palette index, bottom of the stack first.
proc refFaceColr {records layers} {
    set base [llength $records]
    set table [binary format SuSuIuIuSu 0 $base 14 [expr {14 + $base * 6}] \
        [llength $layers]]
    foreach record $records { append table [binary format SuSuSu {*}$record] }
    foreach layer $layers { append table [binary format SuSu {*}$layer] }
    return $table
}

# CPAL (5.7.12): the colours the layers point into. A colour record is FOUR
# BYTES IN THE ORDER blue, green, red, alpha - not red first, which is the
# mistake the format invites.
proc refFaceCpal {colours} {
    set table [binary format SuSuSuSuIu 0 [llength $colours] 1 \
        [llength $colours] 14]
    append table [binary format Su 0]
    foreach colour $colours { append table [binary format cccc {*}$colour] }
    return $table
}

# A cmap, format 12: one group per character.
proc refFaceCmap {map} {
    set groups {}
    set count 0
    foreach code [lsort -integer [dict keys $map]] {
        append groups [binary format IuIuIu $code $code [dict get $map $code]]
        incr count
    }
    set subtable [binary format SuSuIuIuIu 12 0 [expr {16 + $count * 12}] 0 \
        $count]
    return [binary format SuSuSuSuIu 0 1 3 10 12]$subtable$groups
}

# The file round all of it: 1000 units to the em, an ascender of 750, an
# advance of 1000 for every glyph, loca 32-bit, every glyph padded to four.
proc refFaceFile {glyphs map colr cpal} {
    set count [llength $glyphs]
    set head [binary format IuIuIuIu 0x00010000 0x00010000 0 0x5F0F3CF5]
    append head [binary format SuSu 0 1000]
    append head [binary format WuWu 0 0]
    append head [binary format SSSS 0 -200 1000 800]
    append head [binary format SuSuSSS 0 8 2 1 0]
    set hhea [binary format Iu 0x00010000]
    append hhea [binary format SSS 750 -250 0]
    append hhea [binary format Su 1000]
    append hhea [binary format SSS 0 0 1000]
    append hhea [binary format SSS 1 0 0]
    append hhea [binary format SSSS 0 0 0 0]
    append hhea [binary format SSu 0 $count]
    set maxp [binary format Iu 0x00010000]
    append maxp [binary format Su $count]
    append maxp [string repeat \x00 26]
    set hmtx {}
    set glyf {}
    set loca {}
    foreach data $glyphs {
        append hmtx [binary format SuS 1000 0]
        append loca [binary format Iu [string length $glyf]]
        append glyf $data
        while {[string length $glyf] % 4} { append glyf \x00 }
    }
    append loca [binary format Iu [string length $glyf]]
    return [::tclpdf::subset::Assemble [dict create head $head hhea $hhea \
        maxp $maxp hmtx $hmtx loca $loca glyf $glyf cmap [refFaceCmap $map] \
        COLR $colr CPAL $cpal]]
}

# The LAYER glyphs are ordinary outlines and the cmap does not reach them; the
# BASE glyphs - 6 and 7, one per character - are EMPTY, and the COLR records
# say which layers each is made of. That is the whole format, and it is why
# such a face embeds blank.
set refFaceGlyphs [list \
    {} \
    [refFaceGlyph {{{500 715} {900 45} {100 45}}}] \
    [refFaceGlyph {{{455 240} {545 240} {545 570} {455 570}} \
                   {{455 95} {545 95} {545 185} {455 185}}}] \
    [refFaceGlyph {{{823 514} {634 703} {366 703} {177 514} \
                    {177 246} {366 57} {634 57} {823 246}}}] \
    [refFaceGlyph {{{250 390} {400 240} {690 520} {690 640} {400 370} {250 510}}}] \
    [refFaceGlyph {{{868 469} {679 658} {411 658} {222 469} \
                    {222 201} {411 12} {679 12} {868 201}}}] \
    {} {}]
set refFaceRecords {{6 0 2} {7 2 3}}
set refFaceLayers {{1 0} {2 1} {5 3} {3 2} {4 0xFFFF}}
set refFaceColours {{0 178 255 255} {35 35 40 255} {64 140 25 255} {70 60 60 64}}
set refFaceMap [dict create 0x26A0 6 0x2714 7]

set facePath [file join $out ref-02-marks.ttf]
set channel [open $facePath wb]
puts -nonewline $channel [refFaceFile $refFaceGlyphs $refFaceMap \
    [refFaceColr $refFaceRecords $refFaceLayers] [refFaceCpal $refFaceColours]]
close $channel
puts "the scaffolding built a [file size $facePath]-byte colour face"
```

```tcl
# From here on it is the package again. A document of its own, because a
# colour font stands on nothing else.
set symbols [tclpdf new -unit mm]
$symbols page add
$symbols font embed body $ttf              ;# the words: a colour font has none

# THE CALL. The alias comes first and the file after it, the way [image embed]
# takes them; -chars is TEXT and names the characters AND character sequences
# to build glyphs for, -palette the palette to draw the layers through (0 by
# default, and a face may carry several). What comes back is the alias, so it
# can be handed straight on.
set face [$symbols colorFont marks $facePath -chars "⚠✔" -palette 0]
puts [$symbols font info $face]     ;# a Type 3 font: no font program, no fsType

# -data instead of a path, for a face that never was a file - one out of a
# database, one out of an archive. The two roads produce the same font.
set channel [open $facePath rb]
set faceBytes [read $channel]
close $channel
$symbols colorFont fromBytes -data $faceBytes -chars "✔"

$symbols font -family $face -size 24 -color {0.10 0.45 0.20}
$symbols text "⚠✔" -at {20 30}
puts "the warning sign is\
    [format %.2f [$symbols textWidth "⚠" -family $face -size 24]] mm wide"

# A palette index of 0xFFFF is a SENTINEL, not an index: that layer takes the
# colour of the TEXT. The tick is one, so it follows -color while the disc
# behind it stays green - which is what a two-colour logo as a character needs.
set x 20
foreach colour {{0 0 0} {0.75 0.35 0.10} {0.55 0.15 0.55}} {
    $symbols font -family $face -size 24 -color $colour
    $symbols text "✔" -at [list $x 50]
    set x [expr {$x + [$symbols textWidth "✔"] + 4}]
}

# A colour font holds the characters that were asked for and NOTHING else -
# not a letter, not a space - so it stands beside a real face, and -fallback
# is how the two meet. The chain is tried IN ORDER: the face of symbols goes
# FIRST when the marks are to be seen in colour, because DejaVu Sans has a
# warning sign and a tick of its own and would otherwise answer first.
$symbols font -family $face -size 11 -color {0.1 0.1 0.15} -fallback body
$symbols text "⚠ Delivery 2026-0414 is overdue; the goods left the\
    warehouse on the 3rd ✔ and were refused at the door on the 9th." \
    -at {20 70} -width 170
$symbols font -fallback {}
```

```tcl
# The refusals, each naming what the face is and what to do instead.
foreach {label script} [list \
        "an ordinary face"     [list $symbols colorFont plain $ttf -chars "A"] \
        "a character it lacks" [list $symbols colorFont other $facePath -chars "A"] \
        "a palette it lacks"   [list $symbols colorFont other $facePath \
                                    -chars "✔" -palette 3] \
        "embedding it instead" [list $symbols font embed wrong $facePath]] {
    try {
        {*}$script
        puts "$label: went through, which it should not have"
    } on error {message options} {
        puts "$label -> [dict get $options -errorcode]"
    }
}
$symbols write [file join $out ref-02-colour-font.pdf]
$symbols destroy
```

`TCLPDF COLORFONT TABLES` is a face without `COLR` and `CPAL`, `CHAR` a character the face has no glyph for, `EMPTY` a glyph that would draw nothing at all, `PALETTE` a `-palette` the face does not have, `LIMIT` the 256th glyph - a sequence of several characters is one, and a Type 3 font is addressed by single bytes, `COMPOSITE` a shape that is a composite glyph or the `Plus` compositing mode, `FOREGROUND` a gradient stop that names the text colour, `UNBOUNDED` a version 1 glyph with no bounds. What the `COLR` reader itself refuses keeps its own `TCLPDF COLR` codes - `MISSING`, `VERSION`, `EMPTY`, `TRUNCATED`, `LAYERS`, `RECORDS`, `PALETTE`, `ENTRY`, and for the version 1 paint graph `CYCLE`, `DEPTH`, `REUSE`, `PAINT`, `COMPOSITE`, `UNSUPPORTED` (an extend, a clip list or a clip box the reader does not know) - fourteen in all, and they are passed through unchanged, so `trap {TCLPDF COLORFONT}` does **not** catch those.

**COLR version 1 is read too**, and the call does not distinguish: a face may describe some glyphs with the older layer records and some with a version 1 **paint graph** - linear, radial and sweep gradients, clipped shapes, transformations, re-used sub-graphs and 28 compositing modes - and a glyph the table says nothing about is drawn from its own outline in the colour of the text, like a letter. A palette entry may carry an alpha byte, and a translucent layer then costs an `ExtGState` while an opaque one costs nothing; under PDF/A parts 2 and 3 that is admissible, and part 1 forbids transparency and is refused by `pdfa` anyway. What this is for is the two-colour mark that has to behave like a character - a tick in a table column, an amber warning sign in a line of text, a logo in a letterhead: it moves with the line, takes the font size, is measured by `textWidth`, breaks with the paragraph and comes back out of `pdftotext` as the character it stands for.

## A bitmap colour font: an sbix face, and the state machine that forms its sequences

The third kind of colour face keeps a **PNG file per glyph and per size** rather than outlines - Apple Color Emoji is 192 MB of them at nine sizes - and `colorFont` takes it exactly as it takes a `COLR` face: the glyph becomes an image XObject placed by its glyph description, with the alpha channel of the PNG as its soft mask. Two options belong to this road. **`-face n`** names one face of a TrueType **collection** (`.ttc`), which is a directory of faces that share their tables; 0 is the default and is what a file with one face is. **`-strike ppem`** names the pixel size to draw from, and the default is the **largest** the face carries - nothing at build time knows the point size the font will be set at, and of the two ways to be wrong only one is visible. `font info` then reports how many glyphs of the font are pictures under `bitmaps`.

Such a face is never read whole: the package reads its table directory and everything under a megabyte, and takes the pictures it needs out of the file by range. Measured on Apple Color Emoji, 192 123 488 bytes: 0.7 s and 50 MB of memory for a font of 61 emoji, against 13.2 s and 4.3 GB for a naive read.

**Where the sequences come from is not the same question in every face.** An OpenType face forms them with the `ccmp` feature of `GSUB`. An Apple face has no `GSUB` at all - what joins a thumb to a skin tone there is `morx`, a chain of finite state machines - and the package applies it where the face carries one and no `GSUB`. Nothing in the call changes: `-chars` still takes text, and what comes back is still one glyph per sequence with one advance and the whole sequence in its `ToUnicode`.

```tcl
# Apple Color Emoji is part of macOS and is not redistributable, so the
# snippet skips itself where the file is not there - the same rule the
# package follows for a missing validator.
set applePath "/System/Library/Fonts/Apple Color Emoji.ttc"
if {[file exists $applePath]} {
    set bitmaps [tclpdf new -unit mm]
    $bitmaps page add
    $bitmaps font embed body $ttf

    # ONE CALL, and -face 0 is the default: the file is a collection of two
    # faces that share their tables. Four units go in as one string and four
    # glyphs come out - a thumb with a skin tone, a family of three, a flag
    # of two regional indicators and the Scottish flag, which is a black flag
    # and six invisible tag characters.
    set emoji [$bitmaps colorFont emoji $applePath \
        -chars "👍🏽👨‍👩‍👧🇩🇪🏴󠁧󠁢󠁳󠁣󠁴󠁿" -face 0]
    set info [$bitmaps font info $emoji]
    puts "sbix: [dict get $info glyphs] glyphs,\
        [dict get $info bitmaps] of them pictures,\
        [format %.0f [dict get $info unitsPerEm]] units to the em"

    $bitmaps font -family $emoji -size 24
    $bitmaps text "👍🏽👨‍👩‍👧🇩🇪🏴󠁧󠁢󠁳󠁣󠁴󠁿" -at {20 30}

    # A sequence is one glyph with one width whichever road formed it: the
    # Scottish flag is seven characters and measures what a single emoji
    # measures.
    puts "seven characters, one glyph:\
        [format %.3f [$bitmaps textWidth "🏴󠁧󠁢󠁳󠁣󠁴󠁿" -family $emoji -size 24]] mm\
        against [format %.3f [$bitmaps textWidth "👍🏽" \
            -family $emoji -size 24]] mm"

    # -strike trades resolution against file size, and the same document out
    # of the 32 pixel strike is a fraction of the bytes.
    $bitmaps colorFont small $applePath -chars "👍🏽" -strike 32
    $bitmaps font -family small -size 24
    $bitmaps text "👍🏽" -at {20 50}

    # The refusals of this road, each naming what to do instead.
    foreach {label script} [list \
            "embedding a bitmap face" [list $bitmaps font embed no $applePath] \
            "a strike it lacks"       [list $bitmaps colorFont other \
                                          $applePath -chars "👍" -strike 99] \
            "-palette on pictures"    [list $bitmaps colorFont other \
                                          $applePath -chars "👍" -palette 1]] {
        try {
            {*}$script
            puts "$label: went through, which it should not have"
        } on error {message options} {
            puts "$label -> [dict get $options -errorcode]"
        }
    }
    $bitmaps write [file join $out ref-02-bitmap-font.pdf]
    $bitmaps destroy
} else {
    puts "sbix: skipped - $applePath is not on this machine"
}
```

`TCLPDF SBIX STRIKE` is a pixel size the face has not got, and its message lists the ones it has; `TCLPDF COLORFONT STRIKE` is `-strike` given for a `COLR` face, which has no strikes, and `TCLPDF COLORFONT PALETTE` is `-palette` given for a bitmap face, which has no palette. `TCLPDF FONT FACE` is a face number a collection has not got. `font embed` refuses an `sbix` face **even where some of its characters have outlines** (`TCLPDF FONT OUTLINES`, the table as its fourth word): measured on Apple Color Emoji, 42 of the 1469 characters its `cmap` covers have real outlines - the digits and the keycap bases - 1397 more are contours of two points, which enclose no area, and the remaining 30 have no outline at all (42 + 1397 + 30 = 1469, counted with fontTools over the `cmap` of face 0). What the `sbix` and `morx` readers refuse themselves keeps its own `TCLPDF SBIX` and `TCLPDF MORX` codes.

## Vertical writing, and breaking it into columns

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add
$doc font embed jp $jpTtf

# -direction ttb writes /Identity-V over the same descendant and the same
# embedded file - the writing mode is a property of the CMap, not a second
# copy of the face. One call is ONE column.
$doc text "日本語の縦書き" -at {175 30} -family jp -size 13 -direction ttb

# A prose text is broken into columns by [textLines], where -width is the
# column HEIGHT: what the breaker asks of a candidate is "how far does this
# reach", and that is answered along whichever axis the text writes.
set prose "日本語の縦書きでは、行は上から下へ進み、列は右から左へ並びます。"
set columns [$doc textLines $prose -width 90 -family jp -size 12 -direction ttb]

# Placing them is a loop - which is also what decides that the columns run
# right to left.
set x 160
foreach column $columns {
    $doc text $column -at [list $x 30] -family jp -size 12 -direction ttb
    set x [expr {$x - 9}]
}
```

`text -width -direction ttb` is **refused** (`TCLPDF TEXT VERTICAL block`): a horizontal block steps its lines *down* the page and a vertical one would have to step its columns *left*, and the height limit, the column balance, the flow around shapes and the table are all written along that one axis. The message names the two calls above. A table refuses the direction in its own words (`TCLPDF TABLE DIRECTION`) — there is no vertical table.

## What a font refusal says

```tcl
package require tclpdf
set doc [tclpdf new]
$doc page add

# The readers behind [font embed] refuse in CLASSES, and the class is the part
# a script acts on:
#
#   SOURCE       wrong format - try another reader
#   DAMAGED      right format, broken file - stop
#   UNSUPPORTED  sound file, this package does not read it
#   TABLE        a required table is missing (the word after it names it)
#   SUBSET       sound face, it just cannot be cut down (a CFF)
#   METRICS      the face states no em, or the AFM is missing
#   ENCODING     no usable Unicode cmap
#   FACE         -face names a face the collection has not got
try {
    $doc font embed broken -data "not a font at all, really"
    puts "a face made of prose: NOT REFUSED"
} trap {TCLPDF FONT SOURCE} {message options} {
    puts "wrong format: [lindex [dict get $options -errorcode] 3]"
} trap {TCLPDF FONT DAMAGED} {message options} {
    puts "broken file, no point retrying"
}
```

Those **eight** are what the readers themselves say; `trap {TCLPDF FONT}` catches them and the rest of the topic besides - the whole `TCLPDF FONT` space has twenty-two classes, most of them about the call rather than the file. A CFF2 is `UNSUPPORTED cff2`. A `.ttc` is **not** among the refusals: it is a collection and `-face n` picks one of its faces, 0 by default, and only a number the file has not got answers `TCLPDF FONT FACE`.
