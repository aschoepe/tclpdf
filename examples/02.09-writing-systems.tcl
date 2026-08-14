#!/usr/bin/env tclsh
#
# tclpdf example 2.9 - writing systems, symbols and a colour font that is not
#
#   tclsh examples/02.09-writing-systems.tcl ?output.pdf?
#
# Ten faces on one page: Japanese, Tibetan, two symbol sets, emoji, cuneiform,
# Egyptian hieroglyphs, Arabic and a brush face. None of them is a standard
# font, all of them are embedded, and the document is PDF/A-3u.
#
# WHY THIS IS AFFORDABLE. The source files add up to 15 MB, the Japanese face
# alone being 8.7 MB for its 17 103 glyphs. What lands in the document is a
# subset of the glyphs actually drawn, and that is a few kilobytes per face.
# The table below reads both numbers off the files rather than repeating them
# from here.
#
# Chinese and Korean were on this page and are not any more: at 17 and 23 MB
# they doubled the size of the source archive for one line each. Japanese
# carries the same point - a face with more glyphs than a Latin one has
# characters.
#
# WHAT DOES NOT WORK, and it is worth knowing before reaching for it: a COLOUR
# font. Noto Color Emoji is 24.5 MB and comes out EMPTY - its glyphs carry no
# outlines at all, the picture lives in COLR layers referencing a palette, and
# subsetting keeps neither. The monochrome Noto Emoji on this page is the one
# that draws. Measured, not assumed: the colour face embeds without complaint
# and renders as nothing.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

# The footer every example draws - shared, because one copy per example is
# how a block starts drifting.
source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.09-writing-systems.pdf"}]
set fonts [file join $here assets fonts]
set profile [file join [file dirname $here] icc sRGB.icc]

# alias, file, what it is, and a line set in it. The text is the point of the
# example, so it is in the language the face is for - everything ABOUT the
# faces stays English.
#
# The symbol lines were READ OUT of each face rather than picked by eye. A
# symbol font covers blocks, not the symbols one happens to think of: Noto
# Sans Symbols has 135 characters in U+2600..U+26FF and U+2600 itself is not
# among them. Choosing by hand produced three lines that stopped the drawing,
# which is how this note came to be here.
#
# Two of the emoji carry a VARIATION SELECTOR behind them - U+FE0F asks for
# the colour form, U+FE0E for the text form. tclpdf has no shaper and treats
# them as ordinary characters, so each becomes a glyph of its own. That is
# harmless here and measured rather than hoped: both carry an advance of zero
# in this face, so nothing shifts. They do end up in the subset and in the
# ToUnicode map, where they belong - the text extracts as it was written.
#
# The music and emoji lines carry characters ABOVE the BMP, and they are
# written as literal UTF-8 rather than as \U escapes on purpose: measured,
# Tcl 8.6 turns \U0001D11E into U+FFFD while Tcl 9 yields the character. The
# literal works under both - 8.6 reports a string length of 2 for it, being a
# surrogate pair internally, but splits it into one character with the right
# code point, which is what the glyph run needs.
set faces {
  sans     NotoSans-Variable.ttf          {Latin, Greek and Cyrillic}
      "Grüße aus Bochum - Ελλάδα - Москва - Łódź - Plzeň"
  jp       NotoSansJP-Regular.ttf         {Japanese}
      "日本語のテキスト ひらがな カタカナ 漢字 東京 一二三四五"
  tibetan  NotoSerifTibetan-Variable.ttf  {Tibetan}
      "ཀ ཁ ག ང ཅ ཆ ཇ ཉ ཏ ཐ ད ན པ ཕ བ མ ཙ ཚ ཛ ཝ ཞ ཟ འ ཡ ར ལ ཤ ས ཧ ཨ"
  symbols  NotoSansSymbols-Variable.ttf   {Symbols}
      "☥ ☦ ☪ ☮ ☯ ☸ ☺ ☽ ☿ ♀ ♂ ♃ ♄ ♈ ♉ ♊ ♪ ♫ ⚐ ⚑ ⛰ ⛽"
  symbols2 NotoSansSymbols2-Regular.ttf   {More symbols}
      "✁ ✂ ✈ ✏ ✔ ✖ ✤ ✪ ❄ ❤ ➜ ➡ ⭐ ⭕ ⚀ ⚁ ⚂ ⚃ ⚄ ⚅ ♔ ♕ ♖ ♗ ♘ ♙"
  emoji    NotoEmoji-Variable.ttf         {Emoji, monochrome}
      "🏡🧁🍰🏜️🎁🎂🎈🎺🙏💕🌶︎🔋🔥🍾😃🐬🚲🌳🔧🌧🔬"
  cuneiform NotoSansCuneiform-Regular.ttf {Cuneiform}
      "𒀀 𒀁 𒀂 𒀃 𒀄 𒀅 𒀆 𒀇 𒀈 𒀉 𒀊 𒀋 𒀌 𒀍 𒀎 𒀏 𒀐 𒀑"
  hiero    NotoSansEgyptianHieroglyphs-Regular.ttf {Egyptian hieroglyphs}
      "𓀀 𓀁 𓀂 𓀃 𓀄 𓀅 𓁀 𓁁 𓂀 𓂁 𓃀 𓃁 𓄀 𓅀 𓆀 𓇀 𓈀 𓉀"
  arabic   NotoNaskhArabic-Variable.ttf   {Arabic - see the note below}
      "العربية مرحبا بالعالم"
  marker   PermanentMarker-Regular.ttf    {A brush face}
      "Handwritten, more or less - and it keeps going"
}

set doc [tclpdf new -unit mm]
$doc info Title "Writing systems and symbols"
$doc info Author "Alexander Schoepe"
$doc page add

foreach {alias file what line} $faces {
  $doc font embed $alias [file join $fonts $file]
}

# Nicht in der Liste oben: die Musikschrift setzt keine Zeile, sie liefert die
# Zeichen fuer das gezeichnete Notensystem weiter unten.
$doc font embed music [file join $fonts NotoMusic-Regular.ttf]

$doc font -family sans -size 15 -color {0.20 0.30 0.45}
$doc text "Ten faces, one page" -at {20 22}

$doc font -family sans -size 9 -color {0.35 0.35 0.35}
$doc text "Every line below is set in a face of its own, embedded and subset\
    to what it draws. The document is PDF/A-3u, so none of them may be left\
    out." -at {20 30} -width 170

# -- the faces themselves ----------------------------------------------------

set y 42
foreach {alias file what line} $faces {
  # The face NAMES itself: the family is read back out of the document rather
  # than written down here, so the label cannot claim a face the file does not
  # carry - the same rule the footer follows.
  $doc font -family sans -size 7 -color {0.45 0.45 0.45}
  $doc text "$what - [dict get [$doc font info $alias] family]" -at [list 20 $y]
  $doc font -family $alias -size 14 -color black
  # Not every face has every character of its own sample - a symbol picked
  # from the wrong block would stop the whole document, and saying which one
  # is more useful than a document that does not exist.
  # The Arabic line is refused unless it is asked for explicitly: its script
  # needs shaping and reordering, and drawing it anyway is a decision the
  # caller has to make. Here it IS the point of the page - see the note below.
  set extra {}
  if {$alias eq "arabic"} {
    set extra {-unshaped 1}
  }
  if {[catch {$doc text $line -at [list 20 [expr {$y + 7}]] {*}$extra} message]} {
    $doc font -family sans -size 7 -color {0.65 0.20 0.20}
    $doc text "not set: $message" -at [list 20 [expr {$y + 7}]] -width 170
  }
  set y [expr {$y + 17}]
}

# WHY THE JAPANESE FACE IS THE STATIC ONE. Noto Sans JP also comes as a
# variable font, and embedding that one gave a label reading "Noto Sans JP
# Thin" and a visibly thin line. Not a mistake in the label: a variable font
# carries one set of outlines plus a rule for bending them, and what gets
# embedded is the DEFAULT instance - measured, this family defaults to
# wght 100, not 400. Regular exists in it as a named instance, but reaching a
# named instance means computing outlines, which this package does not do yet.
# The static Regular is 5.2 MB against 8.7 MB for the variable file, so it is
# the cheaper answer as well.

# -- where this package stops --------------------------------------------------

set y [expr {$y + 6}]
$doc font -family sans -size 11 -color black
$doc text "Where this package stops" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "Cuneiform and hieroglyphs come out right because they ask for\
    nothing beyond a glyph per character, left to right. The Arabic line above\
    does NOT, and it is on this page to say so rather than to be admired." \
    -at [list 20 $y] -width 170
set y [expr {$y + 12}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "Two things are wrong with it, both measured. The letters are in\
    their ISOLATED forms: in this face U+0628 maps to glyph 614, the same one\
    the isolated presentation form uses, while the initial, medial and final\
    shapes are glyphs 1278, 1310 and 1345 - reachable only through the init,\
    medi and fina features of GSUB, which need a shaper. And the line runs\
    left to right, because nothing here reorders it. Arabic, Hebrew with\
    nikud, Devanagari and Thai all need that shaper; tclpdf does not have one\
    and does not pretend to." -at [list 20 $y] -width 170
set y [expr {$y + 26}]

# -- what a music font is not ------------------------------------------------

$doc page add
set y 22
$doc font -family sans -size 11 -color black
$doc text "Music needs more than a font" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "Noto Music has every piece: a five-line staff (U+1D11A), clefs,\
    noteheads, rests, a combining stem. Setting them as TEXT does not give a\
    score, though - measured, all three ways fail. Staff segments in a row\
    leave gaps between them; a clef after a staff segment stands NEXT to it,\
    because every character carries its own advance and sits on the baseline;\
    and the combining stem lands to the right of the notehead rather than on\
    it, for the same reason the Arabic line above comes out wrong. That is why\
    the music face has no line of its own in the list." \
    -at [list 20 $y] -width 170
set y [expr {$y + 24}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "What does work is the other way round: the staff DRAWN as\
    lines, the note heads set from the face, and everything that is a stroke -\
    stems, bar lines - drawn as well. Below: two flats, four bars, note values\
    from a whole down to a quarter, and a rest." -at [list 20 $y] -width 170
set y [expr {$y + 14}]

$doc font -family sans -size 7 -color {0.45 0.45 0.45}
$doc text "Note heads and rest - [dict get [$doc font info music] family]" \
    -at [list 20 $y]
set y [expr {$y + 8}]

# One staff, four bars. The unit of the whole drawing is the LINE GAP: a step
# up is half of it, a stem is three and a half of them. Writing it that way
# means the staff can be resized by changing one number.
set gap 1.6
set left 20
set right 150
set top $y

for {set line 0} {$line < 5} {incr line} {
  $doc line -from [list $left [expr {$top + $line * $gap}]] \
      -to [list $right [expr {$top + $line * $gap}]] -width 0.15
}

# The bottom line is step 0, and a step is half a gap. The G clef sits so its
# spiral wraps the second line from the bottom.
# The y a note head has to be SET at so that its middle lands on a given step.
#
# A glyph is placed by its baseline, and a note head does not straddle that:
# measured on this face it runs from -1 to 269 thousandths of the em, so its
# middle sits 134 above the baseline - 0.9 mm at 19 pt. Ignoring that puts
# every note half a line space too high, which looks almost right and is not.
proc staffY {top gap step {lift 0.9}} {
  return [expr {$top + 4 * $gap - $step * $gap / 2.0 + $lift}]
}

$doc font -family music -size 19 -color black
$doc text "𝄞" -at [list [expr {$left + 1}] [staffY $top $gap 2 0]]
# Two flats, on the B and E lines - the key of B flat major.
$doc font -family music -size 19
foreach step {6 3} {
  set x [expr {$left + 8 + ($step == 6 ? 0 : 2.4)}]
  $doc text "♭" -at [list $x [staffY $top $gap $step 0.6]]
}

# value: whole, half or quarter. A whole note has no stem; the others get one,
# and it goes down when the head sits above the middle line.
proc note {doc top gap x step value} {
  set y [staffY $top $gap $step]
  $doc font -family music -size 19 -color black
  if {$value eq "whole"} {
    $doc text "𝅝" -at [list $x $y]
    return
  }
  $doc text [expr {$value eq "half" ? "𝅗" : "𝅘"}] -at [list $x $y]
  # The stem starts at the MIDDLE of the head, which is 0.9 mm above the
  # baseline the glyph was placed on. It goes up on the right for notes below
  # the middle line and down on the left for those above it.
  set middle [expr {$y - 0.9}]
  set stem [expr {3.5 * $gap}]
  if {$step > 4} {
    $doc line -from [list $x $middle] -to [list $x [expr {$middle + $stem}]] \
        -width 0.18
  } else {
    $doc line -from [list [expr {$x + 2.2}] $middle] \
        -to [list [expr {$x + 2.2}] [expr {$middle - $stem}]] -width 0.18
  }
}

# Bar 1: quarter, quarter, half. Bar 2: a whole. Bar 3: quarter and a rest.
foreach {x step value} {
    28 2 quarter  36 4 quarter  44 5 half
    62 3 whole
    86 6 quarter  94 4 quarter  102 2 half
    124 0 quarter} {
  note $doc $top $gap $x $step $value
}
# The rest, and the bar lines that divide the whole thing.
$doc font -family music -size 19 -color black
$doc text "𝄽" -at [list 134 [staffY $top $gap 1 0]]
foreach x {56 78 118 150} {
  $doc line -from [list $x $top] -to [list $x [expr {$top + 4 * $gap}]] -width 0.15
}
# A closing double bar, thick line last.
$doc line -from [list 148.4 $top] -to [list 148.4 [expr {$top + 4 * $gap}]] -width 0.15
$doc line -from [list 149.6 $top] -to [list 149.6 [expr {$top + 4 * $gap}]] -width 0.45
set y [expr {$y + 16}]

# -- the colour font that is not ---------------------------------------------

set y [expr {$y + 8}]
$doc font -family sans -size 11 -color black
$doc text "The one that does not work" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
set y [$doc text "Noto Color Emoji is not on this page, and not by oversight. Its\
    glyphs carry no outlines: the picture is a stack of COLR layers over a\
    palette, and subsetting keeps neither. tclpdf embeds the face without\
    complaining and the page comes out empty - 24.5 MB for nothing. The\
    monochrome Noto Emoji above is the one that draws." \
    -at [list 20 $y] -width 170]

# -- what it costs -----------------------------------------------------------

set y [expr {$y + 8}]
$doc font -family sans -size 11 -color black
$doc text "What a face costs in the document" -at [list 20 $y]
set y [expr {$y + 7}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "The file size is read off the font, the glyph count out of the\
    document. A face is only ever as big as what it draws - which is what\
    makes ten of them on one page reasonable at all." \
    -at [list 20 $y] -width 170
set y [expr {$y + 12}]

set rows {}
foreach {alias file what line} $faces {
  set info [$doc font info $alias]
  lappend rows [list $what \
      [format "%.1f MB" [expr {[file size [file join $fonts $file]] / 1048576.0}]] \
      [dict get $info glyphs]]
}
# The music face is embedded too, though it sets no line of its own - so it
# belongs in the tally.
set info [$doc font info music]
lappend rows [list "Music notation" \
    [format "%.1f MB" [expr {[file size [file join $fonts NotoMusic-Regular.ttf]]
        / 1048576.0}]] \
    [dict get $info glyphs]]

$doc font -family sans -size 8 -color black
set y [$doc table -at [list 20 $y] -width 170 -theme grid \
    -style {family sans size 8} -headStyle {family sans size 8} \
    -head {{{Face} {File on disk} {Glyphs in the file}}} \
    -body $rows \
    -columns {{align left} {align right} {align right}}]

# -- the declaration ---------------------------------------------------------

$doc pdfa -part 3 -conformance U -profile $profile

exampleDone $doc $target sans
