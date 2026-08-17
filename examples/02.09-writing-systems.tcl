#!/usr/bin/env tclsh
#
# tclpdf example 2.9 - writing systems, symbols and a colour font that is not
#
#   tclsh examples/02.09-writing-systems.tcl ?output.pdf?
#
# Eleven faces on one page: Japanese, Tibetan, two symbol sets, emoji,
# cuneiform, Egyptian hieroglyphs, Hebrew, Arabic and a brush face. None of
# them is a standard font, all of them are embedded, and the document is
# PDF/A-3u.
#
# TWO OF THE LINES RUN RIGHT TO LEFT and they are not the same case. Hebrew
# needs nothing but the order, so -direction rtl sets it correctly and the
# text extracts as it was written. Arabic needs the order AND the contextual
# forms, and tclpdf sets both - but only in a face that carries whole
# letters. Noto Naskh Arabic, the face in the table, writes a letter as an
# undotted skeleton plus a separate dot glyph placed by GPOS mark attachment,
# which this package does not read, so that line is REFUSED unless the call
# says -unshaped 1 - which this script does, and the line then comes out as
# isolated forms in the right order. The same words are set once more in
# DejaVu Sans, shaped, with -direction rtl and nothing else, followed by an
# invoice line whose numbers keep their own order and whose brackets are
# mirrored. The notes on the page say so.
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
  hebrew   DejaVuSans.ttf                 {Hebrew - see the note below}
      "שלום עולם ברוכים הבאים"
  arabic   NotoNaskhArabic-Variable.ttf   {Arabic - see the note below}
      "العربية مرحبا بالعالم"
  marker   PermanentMarker-Regular.ttf    {A brush face}
      "Handwritten, more or less - and it keeps going"
}

# The lines of the two right-to-left faces, kept by alias: the demonstration
# further down sets the Arabic one in a second face, and typing it twice is
# how two lines that are meant to be the same stop being it.
set shaped {}
foreach {alias file what line} $faces {
  dict set shaped $alias $line
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
$doc text "Eleven faces, one page" -at {20 22}

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
  # The two right-to-left lines are refused unless the call says what to do
  # about them, and they need different things - which is the point of having
  # both on this page.
  #
  # Hebrew needs the ORDER and nothing else, so -direction rtl is the whole
  # answer: the glyphs the cmap gives are the ones the reader expects, and
  # reversing the run puts them where they belong.
  #
  # Arabic needs the order AND the contextual forms. tclpdf sets both since
  # the cursive forms arrived - but not with THIS face: Noto Naskh Arabic
  # writes a letter as an undotted skeleton plus a separate dot glyph, and
  # placing that dot is GPOS mark attachment, which this package does not
  # read. So the line is refused unless the caller says -unshaped 1, and the
  # same words in a face that carries whole letters are set below. See the
  # note under the lines.
  #
  # Both are anchored at the RIGHT margin, and that is not decoration: with
  # -direction rtl the default -align left means the edge the line STARTS at
  # in reading order, which is the right one. Anchored at 20 like the others
  # the line would end there and run off the left edge of the sheet -
  # measured, pdftotext -bbox then reports words at a negative x, and the
  # words that fell off the paper are missing from the extracted text.
  set extra {}
  set at 20
  if {$alias eq "hebrew"} {
    set extra {-direction rtl}
    set at 190
  }
  if {$alias eq "arabic"} {
    set extra {-unshaped 1 -direction rtl}
    set at 190
  }
  if {[catch {$doc text $line -at [list $at [expr {$y + 7}]] {*}$extra} message]} {
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
    nothing beyond a glyph per character, left to right. The Hebrew line asks\
    for one thing more - that the line run the other way. The Arabic line\
    asks for two: the order and the contextual forms, and the second depends\
    on the face." -at [list 20 $y] -width 170
set y [expr {$y + 10}]

# A page of its own for the right-to-left lines: what a line does and does
# not reverse is easier to see with room around it than squeezed under the
# table of faces.
$doc page add
set y 22
$doc font -family sans -size 11 -color black
$doc text "Right to left, and what stays put" -at [list 20 $y]
set y [expr {$y + 9}]

# THE SAME WORDS IN THE OTHER FACE, and this is the point of the section: the
# forms are not a property of the package alone. DejaVu Sans carries whole
# Arabic letters, so -direction rtl is the whole answer for it.
#
# THE SECOND LINE is an invoice line, and it is there for what a right-to-left
# line does NOT reverse: the invoice number, the amount with its separators
# and the percentage keep their own order, and the brackets around the tax
# rate are drawn mirrored. Both are checked against the file rather than
# claimed - tests/text.test 13.x reads the glyphs back out of the content
# stream and the text back out through pdftotext.
#
# THE THIRD LINE is the same point with the OTHER signs an amount comes with:
# a temperature with its degree sign, a rate in per mille, an amount in
# pounds. They are European Terminators in UAX #9 like the percent and the
# euro sign, and they used to be missing from a hand list - measured
# 2026-08-16, "5°" came out of the file as "°5". The classes are read off the
# Unicode database now (bidiData.tcl), so the three stay with their numbers.
set invoice "الفاتورة 4711 - 1.234,50 € (19%)"
set amounts "الحرارة -17,5° - الخصم 3‰ - المبلغ £1.234,50"
$doc font -family sans -size 7 -color {0.45 0.45 0.45}
$doc text "The same words in DejaVu Sans, set with -direction rtl and nothing\
    else, an invoice line and a line of amounts under them:" -at [list 20 $y]
$doc font -family hebrew -size 14 -color black
$doc text [dict get $shaped arabic] -at [list 190 [expr {$y + 7}]] \
    -direction rtl
$doc text $invoice -at [list 190 [expr {$y + 15}]] -direction rtl
$doc text $amounts -at [list 190 [expr {$y + 23}]] -direction rtl
set y [expr {$y + 28}]

$doc font -family sans -size 8 -color {0.35 0.35 0.35}
$doc text "Measured, not asserted. The shapes come out of the init, medi and\
    fina features of GSUB, and the glyphs are the ones HarfBuzz produces for\
    the same words - checked glyph by glyph against hb-shape. In the invoice\
    line the digits run left to right inside the right-to-left line, as\
    Unicode says they must, and \"(\" is drawn with the glyph of \")\"; a\
    line that MIXES the two directions is refused instead: deciding where\
    such a run goes is the bidi algorithm, and this package has none. What is\
    still missing in Arabic is the rest of a shaper - the ligatures reached\
    through chaining lookups, and the mark placement of GPOS, which is why\
    nikud, Devanagari and Thai stay refused." \
    -at [list 20 $y] -width 170
set y [expr {$y + 30}]

# -- the everyday, right to left ---------------------------------------------

# The lines an invoice or a letter actually has, in Hebrew and Arabic - each
# with its meaning at the left, so a reader who has neither script can check
# what the file says. Nothing here needs more than DejaVu Sans and -direction
# rtl: the numbers, dates and the amount keep their own order inside the
# line, the brackets come out mirrored, and every line is one call. Below,
# the same in a table: the description column is right-to-left, the amount
# column left-to-right - said once as a style, not per cell - and the amount
# column stands at the LEFT, which is where a right-to-left table puts it.
$doc font -family sans -size 11 -color black
$doc text "The everyday, right to left" -at [list 20 $y]
set y [expr {$y + 8}]
foreach {gloss line} {
    "thank you very much"                 "תודה רבה"
    "invoice number 4711"                 "חשבונית מספר 4711"
    "total 1,234.50 euro"                 "סך הכל 1.234,50 €"
    "date: 17 August 2026"                "תאריך: 17.08.2026"
    "(including 17 % tax)"                "(כולל מס 17%)"
    "with kind regards"                   "בברכה"
    "thank you for your trust"            "شكرا لثقتكم"
    "invoice number 2026-114"             "الفاتورة رقم 2026-114"
    "due date 30 September 2026"          "تاريخ الاستحقاق 30.09.2026"
    "please pay within 30 days"           "الرجاء الدفع خلال 30 يوما"
    "address: 12 Nile Street, Cairo"      "العنوان: شارع النيل 12، القاهرة"
} {
    $doc font -family sans -size 7 -color {0.45 0.45 0.45}
    $doc text $gloss -at [list 20 $y]
    $doc font -family hebrew -size 11 -color black
    $doc text $line -at [list 190 $y] -direction rtl
    set y [expr {$y + 7}]
}
set y [expr {$y + 4}]

# The invoice table: description right-to-left, amount left-to-right. The
# amount column is the FIRST column so that it stands at the left; its head
# is an Arabic word again, so that one cell says rtl for itself. Meaning:
# "description" / "amount"; "printing 12,500 boxes"; "varnish and
# die-cutting"; "total".
$doc font -family sans -size 7 -color {0.45 0.45 0.45}
$doc text "The same in a table - the description column right to left, the\
    amount column left to right, said once as a style:" -at [list 20 $y]
set y [expr {$y + 4}]
set y [$doc table -at [list 20 $y] -width 170 -theme grid \
    -style {family hebrew size 9 direction rtl} \
    -columns {{width 40 direction ltr align decimal} {}} \
    -head {{{text "المبلغ" direction rtl} "الوصف"}} \
    -body {
        {"18.400,00" "طباعة 12.500 علبة"}
        {"3.180,00"  "ورنيش وتقطيع"}
    } \
    -foot {{"21.580,00" "المجموع"}} \
    -decimal ,]

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
set y [expr {$y + 21}]

# The remark the reader sees: HOW the score below is made, and what it is not.
$doc font -family sans -size 8 -color {0.35 0.35 0.35}
set y [$doc text "What does work is the other way round, and below it is\
    carried through: the first eight bars of Beethoven's piano sonata op. 2\
    no. 1, right hand, set by hand. Whatever is a glyph - clef, key, time,\
    heads, dots, accidentals, rests, staccato, fermata, arpeggio, dynamics -\
    is Noto Music; whatever is a stroke - staff and ledger lines, stems, bar\
    lines, beams, slurs, the hairpin - is tclpdf graphics, because no font\
    can deliver those: Unicode holds only begin/end signals for an engraving\
    engine there (U+1D173 to U+1D17A). Every position is a number in a table\
    in this script. There is no engraving engine behind it and none is\
    planned: this is a picture of these eight bars, not a tool for the\
    ninth." -at [list 20 $y] -width 170]
set y [expr {$y + 4}]

# "Allegro" is bold, and the sans face on this page has no bold - it is a
# variable font whose default instance is Regular. The named instance Bold of
# the same file is embedded as a face of its own; it is counted in the tally
# further down like every other face.
$doc font embed bold [file join $fonts NotoSans-Variable.ttf] -instance Bold

# THE THREE NUMBERS everything below is measured in. gap is the distance
# between two staff lines; a step (one note name up) is half of it, a stem is
# three and a half of them, a beam half a gap thick. size is the point size the
# music glyphs are set at, em the same in millimetres - glyph geometry that
# was MEASURED on the face is written in thousandths of the em, so both scale
# together. Change gap and size in step and the whole score follows.
set gap 1.6
set size 19
set em [expr {$size * 25.4 / 72.0}]

# The bottom line is step 0, and a step is half a gap: the y of a step, and the
# y a glyph has to be SET at so that its reference lands on that step.
#
# A glyph is placed by its baseline, and a note head does not straddle that:
# measured on this face it runs from -1 to 269 thousandths of the em, so its
# middle sits 134 above the baseline - 0.9 mm at 19 pt. Ignoring that puts
# every note half a line space too high, which looks almost right and is not.
# The default lift is that head lift; other glyphs pass their own, measured
# the same way off their bounding box.
proc stepY {top step} {
  global gap
  return [expr {$top + 4 * $gap - $step * $gap / 2.0}]
}
proc staffY {top step {lift {}}} {
  global em
  if {$lift eq ""} {set lift [expr {0.134 * $em}]}
  return [expr {[stepY $top $step] + $lift}]
}

# One music glyph at a page position, at the score size or a fraction of it.
proc glyph {doc x y text {scale 1.0}} {
  global size
  $doc font -family music -size [expr {$size * $scale}] -color black
  $doc text $text -at [list $x $y]
}

# Five lines from left to right, and the bar lines - a thin one, or the final
# thin-plus-thick pair.
proc staff {doc top left right} {
  global gap
  for {set line 0} {$line < 5} {incr line} {
    $doc line -from [list $left [expr {$top + $line * $gap}]] \
        -to [list $right [expr {$top + $line * $gap}]] -width 0.15
  }
}
proc bar {doc top x {kind single}} {
  global gap
  set bottom [expr {$top + 4 * $gap}]
  if {$kind eq "final"} {
    $doc line -from [list [expr {$x - 1.2}] $top] -to [list [expr {$x - 1.2}] $bottom] \
        -width 0.15
    $doc line -from [list $x $top] -to [list $x $bottom] -width 0.45
    return
  }
  $doc line -from [list $x $top] -to [list $x $bottom] -width 0.15
}

# Ledger lines for a head outside the staff: one through every even step from
# the staff outwards to the head - a note ON the first ledger line and one in
# the space above it both need that line. Its length is the head plus a little
# on either side.
proc ledger {doc top x step} {
  global gap em
  set from [expr {$x + 0.05 * $em - 0.35 * $gap}]
  set to [expr {$x + 0.347 * $em + 0.35 * $gap}]
  if {$step >= 10} {
    for {set s 10} {$s <= $step} {incr s 2} {
      $doc line -from [list $from [stepY $top $s]] -to [list $to [stepY $top $s]] -width 0.18
    }
  } elseif {$step <= -2} {
    for {set s -2} {$s >= $step} {incr s -2} {
      $doc line -from [list $from [stepY $top $s]] -to [list $to [stepY $top $s]] -width 0.18
    }
  }
}

# A note: head glyph, stem, and what hangs on it. Every measure is a multiple
# of gap or a thousandth of the em read off the face:
#   the head runs from 50 to 347 thousandths of the em right of x, so an
#   up-stem stands at its right edge, a down-stem at its left;
#   -stem up|down|none, default by the rule of the staff - down when the head
#   sits above the middle line (step > 4), up otherwise;
#   -stemTo y ends the stem at that y instead of 3.5 gap away, which is how a
#   beam group makes its stems reach the beam;
#   -staccato 1 sets U+1D17C on the head side away from the stem, in the next
#   space (measured: the dot of that glyph is centred 97 right of and 67 below
#   the origin);
#   -dot 1 sets U+1D16D to the right, in the space - a head on a line takes the
#   space above it (measured: 47 right, 278 above the origin);
#   -accidental glyph sets a flat or natural before the head (see accidental).
# Returns the y of the head's middle, which is what a slur or a fermata wants.
proc note {doc top x step {value quarter} args} {
  global gap em
  set opts {stem {} stemTo {} staccato 0 dot 0 accidental {}}
  foreach {key value} $args {dict set opts [string range $key 1 end] $value}
  set middle [stepY $top $step]
  ledger $doc $top $x $step
  set glyph [expr {$value eq "half" ? "𝅗" : "𝅘"}]
  glyph $doc $x [staffY $top $step] $glyph
  set stem [dict get $opts stem]
  if {$stem eq ""} {set stem [expr {$step > 4 ? "down" : "up"}]}
  set headLeft [expr {$x + 0.050 * $em}]
  set headRight [expr {$x + 0.347 * $em}]
  set centre [expr {($headLeft + $headRight) / 2.0}]
  if {$stem ne "none"} {
    set sx [expr {$stem eq "up" ? $headRight - 0.09 : $headLeft + 0.09}]
    set end [dict get $opts stemTo]
    if {$end eq ""} {
      set end [expr {$middle + ($stem eq "up" ? -3.5 : 3.5) * $gap}]
    }
    $doc line -from [list $sx $middle] -to [list $sx $end] -width 0.18
  }
  if {[dict get $opts staccato]} {
    # Away from the stem; a head on a line (even step) reaches into the next
    # space, one on a space into the next one.
    set off [expr {($step % 2 == 0 ? 1.5 : 1.0) * $gap * ($stem eq "up" ? 1 : -1)}]
    glyph $doc [expr {$centre - 0.097 * $em}] [expr {$middle + $off - 0.067 * $em}] "𝅼"
  }
  if {[dict get $opts dot]} {
    set dotStep [expr {$step % 2 == 0 ? $step + 1 : $step}]
    glyph $doc [expr {$headRight + 0.45 * $gap - 0.047 * $em}] \
        [expr {[stepY $top $dotStep] + 0.278 * $em}] "𝅭"
  }
  if {[dict get $opts accidental] ne ""} {
    accidental $doc $top $x $step [dict get $opts accidental]
  }
  return $middle
}

# A flat or a natural before the head at x: the natural is symmetric about 132
# thousandths of the em, the flat's belly sits on the step with a lift of
# 0.6 mm at this size (both measured, the flat by eye).
proc accidental {doc top x step glyph} {
  global em
  set lift [expr {$glyph eq "♮" ? 0.132 * $em : 0.6}]
  glyph $doc [expr {$x - 0.36 * $em}] [staffY $top $step $lift] $glyph
}

# A chord: heads at every step, one stem from the lowest head to 3.5 gap
# beyond the highest (or the other way round for a down-stem), and U+1D183 in
# front of it when it is arpeggiated - one glyph, 987 thousandths tall, which
# covers a four-note chord in thirds; centred on the middle of the chord.
proc chord {doc top x steps {stem up} {arpeggio 0}} {
  global gap em
  set steps [lsort -integer $steps]
  set low [lindex $steps 0]
  set high [lindex $steps end]
  foreach step $steps {
    note $doc $top $x $step quarter -stem none
  }
  if {$stem eq "up"} {
    set sx [expr {$x + 0.347 * $em - 0.09}]
    $doc line -from [list $sx [stepY $top $low]] \
        -to [list $sx [expr {[stepY $top $high] - 3.5 * $gap}]] -width 0.18
  } else {
    set sx [expr {$x + 0.050 * $em + 0.09}]
    $doc line -from [list $sx [stepY $top $high]] \
        -to [list $sx [expr {[stepY $top $low] + 3.5 * $gap}]] -width 0.18
  }
  if {$arpeggio} {
    glyph $doc [expr {$x - 0.35 * $em}] \
        [expr {[stepY $top [expr {($low + $high) / 2.0}]] + 0.5 * $em}] "𝆃"
  }
}

# A beam group. notes is {x step ...}; the stems all point the way of the head
# farthest from the middle line, the beam runs from the end of the first stem
# to the end of the last (3.5 gap from each head, so it follows the notes) and
# every stem in between is drawn to it. -beams 2 puts a second beam
# 0.8 gap inside the first over the whole group (sixteenths); -second {i j}
# over the notes i..j only (an eighth followed by sixteenths). -triplet 1 sets
# a "3" beyond the beam. Beam thickness is half a gap. Returns nothing.
proc beam {doc top notes args} {
  global gap em
  set opts {beams 1 second {} triplet 0}
  foreach {key value} $args {dict set opts [string range $key 1 end] $value}
  set far 0
  foreach {x step} $notes {
    if {abs($step - 4) >= abs($far - 4)} {set far $step}
  }
  set stem [expr {$far > 4 ? "down" : "up"}]
  set sign [expr {$stem eq "down" ? 1 : -1}]
  set xs {}
  set ys {}
  foreach {x step} $notes {
    lappend xs [expr {$stem eq "up" ? $x + 0.347 * $em - 0.09 : $x + 0.050 * $em + 0.09}]
    lappend ys [expr {[stepY $top $step] + $sign * 3.5 * $gap}]
  }
  set x1 [lindex $xs 0]
  set y1 [lindex $ys 0]
  set xn [lindex $xs end]
  set yn [lindex $ys end]
  # The beam's y at any stem: on the line through its two ends.
  set beamY {}
  foreach sx $xs {
    lappend beamY [expr {$y1 + ($yn - $y1) * ($sx - $x1) / ($xn - $x1)}]
  }
  set i 0
  foreach {x step} $notes {
    note $doc $top $x $step quarter -stem $stem -stemTo [lindex $beamY $i]
    incr i
  }
  set thick [expr {0.5 * $gap * $sign}]
  $doc polygon -points [list $x1 $y1 $xn $yn $xn [expr {$yn - $thick}] \
      $x1 [expr {$y1 - $thick}]] -fill black
  set second [dict get $opts second]
  if {[dict get $opts beams] == 2} {set second [list 0 [expr {$i - 1}]]}
  if {[llength $second]} {
    lassign $second a b
    set inside [expr {0.8 * $gap * $sign}]
    set ya [expr {[lindex $beamY $a] - $inside}]
    set yb [expr {[lindex $beamY $b] - $inside}]
    $doc polygon -points [list [lindex $xs $a] $ya [lindex $xs $b] $yb \
        [lindex $xs $b] [expr {$yb - $thick}] [lindex $xs $a] [expr {$ya - $thick}]] \
        -fill black
  }
  if {[dict get $opts triplet]} {
    set mid [expr {([lindex $notes 0] + [lindex $notes end-1]) / 2.0 + 0.2 * $em}]
    set edge [expr {$stem eq "down" ? max($y1, $yn) + 1.9 * $gap : min($y1, $yn) - 0.6 * $gap}]
    $doc font -family sans -size 6 -color black
    $doc text "3" -at [list $mid $edge] -align center
  }
}

# A slur or a tie: a flat Bezier from one head to another, ABOVE the heads
# (from is the head middle each; the ends stand 0.7 gap off the heads, the
# control points 1.4 gap further, which bows it by about a gap). below 1 turns
# it under the heads.
proc slur {doc x1 y1 x2 y2 {below 0}} {
  global gap em
  set sign [expr {$below ? 1 : -1}]
  set x1 [expr {$x1 + 0.2 * $em}]
  set x2 [expr {$x2 + 0.2 * $em}]
  set y1 [expr {$y1 + $sign * 0.7 * $gap}]
  set y2 [expr {$y2 + $sign * 0.7 * $gap}]
  # A gap and a half of bow, less for a short slur - a bow that is a quarter
  # of the span reads as a slur, more reads as a hoop.
  set bow [expr {$sign * min(1.4 * $gap, 0.25 * abs($x2 - $x1))}]
  set high [expr {$below ? max($y1, $y2) : min($y1, $y2)}]
  $doc curve -from [list $x1 $y1] \
      -c1 [list [expr {$x1 + ($x2 - $x1) * 0.3}] [expr {$high + $bow}]] \
      -c2 [list [expr {$x1 + ($x2 - $x1) * 0.7}] [expr {$high + $bow}]] \
      -to [list $x2 $y2] -width 0.3
}

# A grace note: the eighth WITH its flag as one glyph (U+1D160, stem up), at
# 60 % of the size, a slash through the stem, and a slur under it to the main
# note. The head lift scales with the glyph, which is why staffY takes the
# em into account rather than a fixed 0.9 mm.
proc grace {doc top x step toX toStep} {
  global gap em
  set scale 0.6
  set y [staffY $top $step [expr {0.134 * $em * $scale}]]
  glyph $doc $x $y "𝅘𝅥𝅮" $scale
  set stemX [expr {$x + 0.33 * $em * $scale}]
  $doc line -from [list [expr {$stemX - 0.7}] [expr {$y - 0.45 * $em * $scale}]] \
      -to [list [expr {$stemX + 0.7}] [expr {$y - 0.72 * $em * $scale}]] -width 0.18
  # The slur: a small arc from under the grace head to the left of the main
  # head, bowed a little to the lower right of the straight line between them
  # - the main note is a sixth up and 3.5 mm to the right, so a long bow would
  # only be a second slash.
  set x1 [expr {$x + 0.25 * $em * $scale}]
  set y1 [expr {[stepY $top $step] + 0.55 * $gap}]
  set x2 [expr {$toX - 0.3}]
  set y2 [expr {[stepY $top $toStep] + 0.6 * $gap}]
  $doc curve -from [list $x1 $y1] \
      -c1 [list [expr {$x1 + 0.35 * ($x2 - $x1) + 0.5}] [expr {$y1 + 0.35 * ($y2 - $y1) + 0.5}]] \
      -c2 [list [expr {$x1 + 0.7 * ($x2 - $x1) + 0.5}] [expr {$y1 + 0.7 * ($y2 - $y1) + 0.5}]] \
      -to [list $x2 $y2] -width 0.25
}

# The rests, each placed by its own measured box: the quarter and the eighth
# rest are centred on the middle line (their box is centred at 500
# thousandths), the whole rest hangs from the fourth line (its top is at 512).
proc rest {doc top x kind} {
  global em
  switch $kind {
    whole {glyph $doc $x [expr {[stepY $top 6] + 0.512 * $em}] "𝄻"}
    eighth {glyph $doc $x [expr {[stepY $top 4] + 0.5 * $em}] "𝄾"}
    default {glyph $doc $x [expr {[stepY $top 4] + 0.5 * $em}] "𝄽"}
  }
}

# The fermata U+1D110 over a head: its box starts 648 thousandths above the
# baseline, so the baseline goes that far below where its underside belongs;
# centred over the head (the glyph's middle is 379 thousandths in).
proc fermata {doc top x underside} {
  global em
  glyph $doc [expr {$x + 0.2 * $em - 0.379 * $em}] [expr {$underside + 0.648 * $em}] "𝄐"
}

# Dynamics from the face - p U+1D18F, f U+1D191, s U+1D18D (SUBITO), so sf
# and ff are two glyphs each - on one baseline below the system, and the
# hairpin as two lines opening from a point.
proc dynamic {doc top x text} {
  global gap
  glyph $doc $x [expr {$top + 4 * $gap + 5.4 * $gap}] $text
}
proc hairpin {doc top from to} {
  global gap
  set y [expr {$top + 4 * $gap + 3.6 * $gap}]
  $doc line -from [list $from $y] -to [list $to [expr {$y - 0.6 * $gap}]] -width 0.2
  $doc line -from [list $from $y] -to [list $to [expr {$y + 0.6 * $gap}]] -width 0.2
}

# The clef, the four flats of F minor - B, E, A, D: steps 4 7 3 6 - and the
# time signature, alla breve U+1D135, whose box is centred at 497 thousandths
# and so goes on the middle line.
proc opening {doc top left {time 0}} {
  global em
  glyph $doc [expr {$left + 1}] [staffY $top 2 0] "𝄞"
  set x [expr {$left + 7}]
  foreach step {4 7 3 6} {
    glyph $doc $x [staffY $top $step 0.6] "♭"
    set x [expr {$x + 2.2}]
  }
  if {$time} {
    glyph $doc [expr {$left + 16.5}] [expr {[stepY $top 4] + 0.497 * $em}] "𝄵"
  }
}

# -- the score: two systems, every position a number -------------------------
#
# Beethoven, Sonata op. 2 no. 1, first movement, bars 1-8 of the right hand.
# Steps: c' = -2 (first ledger line below), e' = 0 (bottom line), f'' = 8 (top
# line), a'' = 10 (first ledger line above), c''' = 12. What each line means:
#   note X STEP ?value? ?options?      one head with its stem
#   accidental X STEP GLYPH            a flat or natural before a head at X
#   beam {X STEP X STEP ...} ?opts?    a beamed group, stems to the beam
#   chord X {STEPS} up|down arpeggio   heads on one stem
#   grace X STEP MAINX MAINSTEP        small eighth, slashed, slurred
#   slur X1 STEP1 X2 STEP2             a bow above the heads
#   rest X quarter|whole|eighth        a rest
#   fermata X STEP                     over the head at that step
#   dynamic X TEXT / hairpin FROM TO   below the system
#   bar X ?final?                      a bar line
# The x values are millimetres on the page and were chosen by hand.

set left 20
set right 190
$doc font -family sans -size 8 -color black
$doc text "Ludwig van Beethoven, op. 2 Nr. 1" -at [list $right $y] -align right

set top1 [expr {$y + 9}]
set top2 [expr {$top1 + 24}]

$doc font -family bold -size 9 -color black
$doc text "Allegro" -at [list 27 [expr {$top1 - 5.5}]]

# The bar number of the second system, in a small box before the clef.
$doc rect -at [list $left [expr {$top2 - 8.5}]] -size {3.6 3.4} -stroke black -width 0.15
$doc font -family sans -size 6.5 -color black
$doc text "5" -at [list [expr {$left + 1.8}] [expr {$top2 - 5.7}]] -align center

set systems [list \
  $top1 {
    dynamic 40.5 "𝆏"
    note 43.5 -2 quarter -staccato 1
    bar 49
    note 51.5 1 quarter -staccato 1
    note 58.5 3 quarter -staccato 1
    note 65.5 5 quarter -staccato 1
    note 72.5 8 quarter -staccato 1
    bar 79
    note 81.5 10 quarter -dot 1
    beam {91 9 96 8 101 7} -beams 2 -triplet 1
    accidental 101 7 "♮"
    slur 81.5 10 107 8
    note 107 8 quarter -staccato 1
    rest 113.5 quarter
    bar 119
    hairpin 112 146
    note 121.5 2 quarter -staccato 1
    note 128.5 5 quarter -staccato 1
    note 135.5 7 quarter -staccato 1 -accidental "♮"
    note 142.5 9 quarter -staccato 1
    bar 149
    note 151.5 11 quarter -dot 1
    beam {162 10 167 9 172 8} -beams 2 -triplet 1
    slur 151.5 11 178.5 9
    note 178.5 9 quarter -staccato 1
    rest 184 quarter
    bar 190
  } \
  $top2 {
    dynamic 35.5 "𝆏"
    grace 39.5 5 43 10
    note 43 10 quarter -dot 1
    dynamic 41.5 "𝆍𝆑"
    beam {53 9 58 8 63 7} -beams 2 -triplet 1
    accidental 63 7 "♮"
    slur 43 10 69 8
    note 69 8 quarter -staccato 1
    rest 73.5 quarter
    bar 77
    grace 78.5 6 82 11
    note 82 11 quarter -dot 1
    dynamic 80.5 "𝆍𝆑"
    beam {92 10 97 9 102 8} -beams 2 -triplet 1
    slur 82 11 108 9
    note 108 9 quarter -staccato 1
    rest 112.5 quarter
    bar 116
    dynamic 118.5 "𝆑𝆑"
    chord 119.5 {1 3 5 8} up 1
    note 126.5 12 quarter -dot 1
    beam {134.5 11 138.5 10 142.5 9} -beams 2
    slur 126.5 12 142.5 9
    note 147 8 quarter
    bar 151
    dynamic 152.5 "𝆏"
    beam {154.5 7 159.5 8 163.5 9} -second {1 2}
    accidental 154.5 7 "♮"
    note 168 10 quarter
    slur 168 10 173 7
    note 173 7 quarter
    fermata 173 7
    rest 177 quarter
    bar 181
    rest 183 whole
    bar 190 final
  }]

foreach {top events} $systems {
  staff $doc $top $left $right
  # The clef and key on both systems, the time signature on the first only.
  opening $doc $top $left [expr {$top == $top1}]
  foreach event [split [string trim $events] \n] {
    set event [string trim $event]
    if {$event eq ""} continue
    set args [lassign $event kind]
    switch $kind {
      note {note $doc $top {*}$args}
      accidental {accidental $doc $top {*}$args}
      beam {beam $doc $top {*}$args}
      chord {chord $doc $top {*}$args}
      grace {grace $doc $top {*}$args}
      slur {
        lassign $args x1 s1 x2 s2
        slur $doc $x1 [stepY $top $s1] $x2 [stepY $top $s2]
      }
      rest {rest $doc $top {*}$args}
      fermata {
        lassign $args x step
        # The underside 3.4 gap above the head: clear of the slur arriving
        # there, whose bow reaches about 2.5 gap above the head it ends on.
        fermata $doc $top $x [expr {[stepY $top $step] - 3.4 * $gap}]
      }
      dynamic {dynamic $doc $top {*}$args}
      hairpin {hairpin $doc $top {*}$args}
      bar {bar $doc $top {*}$args}
      default {error "unknown event: $event"}
    }
  }
}

set y [expr {$top2 + 4 * $gap + 13}]
$doc font -family sans -size 7 -color {0.45 0.45 0.45}
$doc text "Glyphs: [dict get [$doc font info music] family] - lines, stems,\
    beams, slurs and the hairpin drawn; every position by hand." -at [list 20 $y]
set y [expr {$y + 2}]

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
# belongs in the tally, and so does the bold instance of the sans face that
# sets one word of the score: same file, a subset of its own.
foreach {alias file what} {
    music NotoMusic-Regular.ttf "Music notation"
    bold  NotoSans-Variable.ttf "Latin, bold instance of the same file"
} {
  lappend rows [list $what \
      [format "%.1f MB" [expr {[file size [file join $fonts $file]] / 1048576.0}]] \
      [dict get [$doc font info $alias] glyphs]]
}

$doc font -family sans -size 8 -color black
set y [$doc table -at [list 20 $y] -width 170 -theme grid \
    -style {family sans size 8} -headStyle {family sans size 8} \
    -head {{{Face} {File on disk} {Glyphs in the file}}} \
    -body $rows \
    -columns {{align left} {align right} {align right}}]

# -- the declaration ---------------------------------------------------------

$doc pdfa -part 3 -conformance U -profile $profile

exampleDone $doc $target sans
