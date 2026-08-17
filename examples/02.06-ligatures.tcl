#!/usr/bin/env tclsh
#
# tclpdf example 2.6 - standard ligatures
#
#   tclsh examples/02.06-ligatures.tcl ?output.pdf?
#
# In most faces the f is drawn with a hook that runs into whatever follows it.
# Set "fi" from the plain letters and the hook collides with the dot of the i;
# the type designer therefore drew a single glyph for the pair, and told the
# font which letters it stands for. That is a ligature, and this page turns it
# on and off so the collision is visible.
#
# WHAT IT COSTS UNDER THE PAGE. A ligature is the one thing in this package
# that breaks the rule everything else is built on: a character has a glyph
# and a glyph has a character. Three characters become ONE glyph, and that has
# to be true all the way through, or the file is quietly wrong:
#
#   the width has to be the ligature's own advance, not the sum of the three
#   the ToUnicode map has to turn that one glyph back into three characters,
#     or "office" is copied out of the reader as "oce"
#   the subset has to carry the ligature glyph, which the cmap cannot reach -
#     it exists only as the output of a GSUB lookup
#   kerning afterwards applies to the ligature, not to the letters inside it
#
# ONLY "liga" is read: the standard ligatures, which the OpenType feature
# registry has on by default. Not the discretionary ones (dlig), which the
# registry has off and which the designer meant as a choice, and not the
# required ones (rlig) of the Arabic scripts, which need a shaper this package
# does not have.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "02.06-ligatures.pdf"}]
set assets [file join $here assets]

set doc [tclpdf new -unit mm]
$doc info Title "Standard ligatures"
$doc page add

# Two faces are enough here, and they carry different ligature sets - which
# is half of what this page has to show.
$doc font embed body [file join $assets fonts DejaVuSans.ttf]
$doc font embed sans [file join $assets fonts google Roboto-Regular.ttf]

$doc font -family body -style bold -size 14 -color {0.20 0.30 0.45}
$doc text "Standard ligatures" -at {20 25}

$doc font -family body -size 9 -color {0.35 0.35 0.35}
$doc text "The same words twice. Look at the f: with ligatures off its hook\
    runs into the dot of the following i, which is the collision the ligature\
    was drawn to avoid." -at {20 32} -width 170

# -- the words, large enough to see the collision ---------------------------

set words "office fluffy final waffle"
set y 50

foreach {face caption} {body {DejaVu Sans}  sans {Roboto}} {
  $doc font -family body -size 8 -color {0.45 0.45 0.45}
  $doc text $caption -at [list 20 [expr {$y - 9}]]

  # -ligatures is a font option, so it can be set as state on [font] or per
  # call on [text]. The first face does it the first way, the second face the
  # second way - and the state is left at its default afterwards either way.
  foreach ligatures {0 1} {
    set at [expr {$y + $ligatures * 12}]
    if {$face eq "body"} {
      $doc font -family $face -size 22 -color black -ligatures $ligatures
      $doc text $words -at [list 20 $at]
      $doc font -ligatures 1
    } else {
      $doc font -family $face -size 22 -color black
      $doc text $words -at [list 20 $at] -ligatures $ligatures
    }
    $doc font -family body -size 7 -color {0.6 0.6 0.6}
    $doc text [expr {$ligatures ? "on" : "off"}] -at [list 155 $at]
  }

  # How many glyphs the line is actually made of. The characters do not
  # change - only how many pieces they are drawn in.
  set plain [$doc textWidth $words -family $face -size 22 -ligatures 0]
  set joined [$doc textWidth $words -family $face -size 22 -ligatures 1]
  $doc font -family body -size 7 -color {0.45 0.45 0.45}
  $doc text [format "%d characters, width %.2f mm against %.2f mm" \
      [string length $words] $plain $joined] \
      -at [list 20 [expr {$y + 20}]]

  set y [expr {$y + 42}]
}

# -- a ligature is not a width ---------------------------------------------

# Measured on DejaVu Sans at 100 points: the fi and fl ligatures have EXACTLY
# the advance of the two letters they replace, while ff, ffi and ffl are
# narrower by 0.53 mm each. So a ligature cannot be detected by measuring -
# the shape changes and the width need not. That is worth knowing before
# writing a test that compares widths and concludes a font has no ligatures.

$doc font -family body -style bold -size 10 -color black
$doc text "A ligature is not a width" -at [list 20 $y]
$doc font -family body -size 8 -color {0.45 0.45 0.45}
$doc text "How much narrower each pair becomes, measured at 100 points. Where\
    the figure is zero the ligature is still there - fi and fl in this face\
    are drawn as one glyph that happens to take exactly the room the two\
    letters took. Only the eye sees those; the line breaker cannot."\
    -at [list 20 [expr {$y + 5}]] -width 170

set y [expr {$y + 20}]
$doc font -family body -size 8 -color {0.35 0.35 0.35}
foreach face {body sans} {
  set name [dict get [$doc font info $face] family]
  set pieces {}
  foreach word {fi fl ff ffi ffl} {
    set plain [$doc textWidth $word -family $face -size 100 -ligatures 0]
    set joined [$doc textWidth $word -family $face -size 100 -ligatures 1]
    lappend pieces [format "%s %.2f" $word [expr {$plain - $joined}]]
  }
  $doc text "$name: [join $pieces {, }] mm" -at [list 20 $y] -width 170
  set y [expr {$y + 6}]
}

# -- and the text is still text ---------------------------------------------

$doc font -family body -style bold -size 10 -color black
$doc text "The text stays copyable" -at [list 20 [expr {$y + 6}]]
$doc font -family body -size 8 -color {0.45 0.45 0.45}
$doc text "Select the line below in a reader and copy it: it comes back as\
    six characters, not as four. The ToUnicode map carries the ligature glyph\
    back to the letters it was made from, which is the half of this feature\
    that no one sees and everyone would miss." \
    -at [list 20 [expr {$y + 11}]] -width 170

$doc font -family body -style bold -size 20 -color black
$doc text "office" -at [list 20 [expr {$y + 30}]]

exampleFooter $doc body
$doc write $target
puts "  written: $target ([file size $target] bytes)"
$doc destroy
