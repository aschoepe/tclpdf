# helper.tcl --
#
# Shared helpers for the test suite. Anything a SECOND test file needs belongs
# here rather than being copied - copies drift, and the third copy is then made
# from the wrong one.
#
# Sourced by tests/all.tcl and, so that a single file can also be run on its
# own, by each test file that uses it.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

namespace eval ::tclpdfTest {}

# The four modules that build or read the XMP packet need tdom, and without it
# they refuse to load - which is correct, and is what the manual promises: a
# document that claims no conformance never loads them and runs without tdom.
# The suite has to follow that promise rather than break on it: every test that
# calls [pdfa], [ua], [zugferd], [xmpSchema] or [xmpRaw] carries this
# constraint, so a machine without tdom skips those and runs the rest. Defined
# here because a single test file may be run on its own, and it is set only
# once per file and unconditionally: the answer is the same wherever it is
# asked, so there is nothing to guard against.
::tcltest::testConstraint haveTdom [expr {![catch {package require tdom 0.9.0-}]}]
# "A file this user cannot read" is only measurable where mode 0000 actually
# denies the running user: root reads it anyway, and so does a filesystem
# mounted without permissions. The constraint is the measurement itself -
# make such a file and ask whether it is readable - rather than a guess from
# [id] or $tcl_platform, which would be wrong on both counts.
::tcltest::testConstraint unreadableFile [expr {[catch {
    set tclpdfProbe [file join [::tcltest::temporaryDirectory] \
        unreadable-[pid].probe]
    close [open $tclpdfProbe w]
    file attributes $tclpdfProbe -permissions 0000
    set tclpdfDenied [expr {![file readable $tclpdfProbe]}]
    file attributes $tclpdfProbe -permissions 0644
    file delete $tclpdfProbe
    set tclpdfDenied
} tclpdfDenied] == 0 && $tclpdfDenied}]
unset -nocomplain tclpdfProbe tclpdfDenied

# Read a file as bytes. Every test that looks at a generated PDF needs this,
# and it needs the binary translation - reading a PDF as text turns the binary
# marker in line two into replacement characters and shifts every offset.
proc ::tclpdfTest::readBytes {path} {
  package require tclpdf::io
  return [::tclpdf::io read $path]
}

# The content stream of a page, so a test can check which operators were
# produced rather than only that a file appeared. Reads the buffer, not the
# written object: the object does not exist until [write] runs.
proc ::tclpdfTest::content {doc {index {}}} {
  return [$doc page content $index]
}

# A document with one page and Helvetica at 10 pt - the block the tests of
# runs set, so that a width means the same thing in each of them. Here since
# markdown.test needed it beside textRun.test.
proc ::tclpdfTest::runDoc {} {
  set doc [tclpdf new -unit mm]
  $doc page add
  $doc font -family helvetica -size 10 -style {}
  return $doc
}

# Where the lines of a content stream start: the x values of every Td, and the
# y values, in the order they were written. Two test files wanted the same
# five lines of parsing, which is one too many - a wrapped paragraph is
# checked by looking at where its lines begin, and that belongs in one place.
proc ::tclpdfTest::starts {stream {axis x}} {
  set result {}
  foreach line [split $stream \n] {
    # Td for an unrotated line, Tm for a turned one - the position is the last
    # pair either way. Reading only Td answered "no lines at all" for rotated
    # text, which looks like a drawing bug and is a reading one.
    if {[regexp {^([-0-9.]+) ([-0-9.]+) Td$} $line -> x y]
        || [regexp {^[-0-9.]+ [-0-9.]+ [-0-9.]+ [-0-9.]+ ([-0-9.]+) ([-0-9.]+) Tm$} \
            $line -> x y]} {
      lappend result [expr {$axis eq "x" ? $x : $y}]
    }
  }
  return $result
}

# The differences between consecutive values - the line advance of a block,
# read off the stream rather than assumed.
proc ::tclpdfTest::steps {values {digits 2}} {
  set result {}
  foreach a [lrange $values 0 end-1] b [lrange $values 1 end] {
    lappend result [format %.*f $digits [expr {$a - $b}]]
  }
  return $result
}

# A complete PNG from its parts, byte by byte, so that every depth and
# colour type the format allows can be exercised - a real encoder saves
# whichever depth it was given. "rows" are the filtered scanlines, filter
# byte included; "trns" the tRNS body, or {} for none.
proc ::tclpdfTest::png {width height depth colorType rows {trns {}} {plte {}}} {
  set chunks {}
  lappend chunks IHDR [binary format IIccccc $width $height $depth $colorType 0 0 0]
  if {$plte ne {}} {
    lappend chunks PLTE $plte
  }
  if {$trns ne {}} {
    lappend chunks tRNS $trns
  }
  lappend chunks IDAT [zlib compress $rows] IEND {}
  set png "\x89PNG\r\n\x1a\n"
  foreach {type body} $chunks {
    append png [binary format I [string length $body]] $type $body \
        [binary format I [zlib crc32 $type$body]]
  }
  return $png
}

# An sfnt built out of a real face with tables added or replaced - the fixture
# behind every sbix and every collection test.
#
# The tables of the face are read through [sfnt parse] and handed back to
# [sfnt Rebuild], which is the module's own writer. That is deliberate: what a
# test needs here is a WELL-FORMED container for the one table it cares about,
# and building a second sfnt writer for it would be a second thing to get
# wrong. What the tests measure is never the container.
proc ::tclpdfTest::sfntWith {path replacements} {
  package require tclpdf::sfnt
  set parsed [::tclpdf::sfnt read $path]
  set data {}
  dict for {tag entry} [dict get $parsed tables] {
    dict set data $tag [::tclpdf::sfnt table $parsed $tag]
  }
  dict for {tag bytes} $replacements {
    if {$bytes eq {}} {
      set data [dict remove $data $tag]
    } else {
      dict set data $tag $bytes
    }
  }
  return [::tclpdf::sfnt::Rebuild [binary format I 0x00010000] $data]
}

# A TrueType COLLECTION out of a list of complete sfnt byte strings.
#
# Each face keeps its own tables rather than sharing them with the others - a
# real collection shares, and nothing that READS one can tell the difference:
# what a face is, is its table directory. Sharing would make the fixture a
# test of the fixture.
#
# THE DIRECTORY IS RELOCATED, and that is the whole of what makes a collection
# one: a table position in a face of a ttcf is measured from the start of the
# FILE and not from the start of the face. A fixture that simply concatenated
# the faces would have every face after the first pointing into the one before
# it - which is exactly the mistake a reader makes, and a fixture that shared
# it would hide it.
proc ::tclpdfTest::collection {faces} {
    set count [llength $faces]
    # ttcf, version 1.0, the count, and one offset per face. Version 1 has no
    # digital signature fields behind the offsets; version 2 has three more,
    # and nothing here reads them.
    set header [binary format a4SuSuIu ttcf 1 0 $count]
    set base [expr {[string length $header] + $count * 4}]
    set offsets {}
    set body {}
    foreach face $faces {
        set at [expr {$base + [string length $body]}]
        lappend offsets $at
        binary scan $face @4Su numTables
        for {set index 0} {$index < $numTables} {incr index} {
            set entry [expr {12 + $index * 16 + 8}]
            binary scan $face @${entry}Iu position
            set face [string replace $face $entry [expr {$entry + 3}] \
                [binary format Iu [expr {$position + $at}]]]
        }
        append body $face
        # Every face starts on a four byte boundary, as every table does.
        if {[string length $body] % 4} {
            append body [string repeat \x00 [expr {4 - [string length $body] % 4}]]
        }
    }
    return $header[binary format Iu$count $offsets]$body
}

# An "sbix" table: one strike per {ppem records} pair, where records is a dict
# of glyph number to {originX originY graphicType data}. Everything not named
# is empty in that strike, which is what a face does for a glyph that has no
# picture at that size.
proc ::tclpdfTest::sbix {numGlyphs strikes} {
    set count [expr {[llength $strikes] / 2}]
    set header [binary format SuSuIu 1 1 $count]
    set base [expr {[string length $header] + $count * 4}]
    set offsets {}
    set body {}
    foreach {ppem records} $strikes {
        lappend offsets [expr {$base + [string length $body]}]
        set data {}
        set positions {}
        for {set glyph 0} {$glyph <= $numGlyphs} {incr glyph} {
            lappend positions [expr {4 + ($numGlyphs + 1) * 4
                + [string length $data]}]
            if {[dict exists $records $glyph]} {
                lassign [dict get $records $glyph] x y type bytes
                append data [binary format SSa4 $x $y $type] $bytes
            }
        }
        append body [binary format SuSu $ppem 72] \
            [binary format Iu[expr {$numGlyphs + 1}] $positions] $data
    }
    return $header[binary format Iu$count $offsets]$body
}

# A tiny opaque PNG of one colour, and one with an alpha channel - the two
# pictures an sbix fixture puts in a glyph.
proc ::tclpdfTest::sbixPng {width height {alpha 0}} {
    set rows {}
    for {set row 0} {$row < $height} {incr row} {
        append rows \x00
        for {set column 0} {$column < $width} {incr column} {
            if {$alpha} {
                append rows [binary format cccc 200 30 40 \
                    [expr {$column * 255 / $width}]]
            } else {
                append rows [binary format ccc 200 30 40]
            }
        }
    }
    return [::tclpdfTest::png $width $height 8 [expr {$alpha ? 6 : 2}] $rows]
}

# The bodies of every object whose text matches a pattern - what a test reads
# when it has to check what went into the FILE rather than what the API said.
#
# The same loop stands in graphics.test and font.test, which is one copy too
# many already; those two do further work inside it and can move here when
# somebody looks at them.
# Every module of the package, with its source text - the loop three guards
# were writing out for themselves.
#
#   ::tclpdfTest::eachModule name text {
#       ... $name is "font.tcl", $text is what is in it ...
#   }
#
# The generated pkgIndex.tcl is left out: it is not a module, it is written by
# configure, and every guard that walked the tree had to exclude it by hand.
# Sorted, so a failure lists the modules in the same order twice running.
proc ::tclpdfTest::eachModule {nameVar textVar script} {
  upvar 1 $nameVar name $textVar text
  set root [file dirname [file dirname [file normalize [info script]]]]
  foreach path [lsort [glob -directory $root *.tcl]] {
    set name [file tail $path]
    if {$name eq "pkgIndex.tcl"} {
      continue
    }
    set channel [open $path r]
    set text [read $channel]
    close $channel
    # 1 is "continue", 2 is "return" from the caller, and both have to reach
    # it rather than stopping here: a guard that returns early out of this
    # loop would otherwise return out of the loop only.
    set code [catch {uplevel 1 $script} result options]
    if {$code == 1 || $code == 2} {
      dict incr options -level
      return -options $options $result
    }
  }
  return
}

proc ::tclpdfTest::objects {doc pattern} {
  set writer [$doc writer]
  set bodies {}
  for {set number 1} {$number <= [$writer count]} {incr number} {
    set body [$writer body $number]
    if {[string match "*$pattern*" $body]} {
      lappend bodies $body
    }
  }
  return $bodies
}

# Run a script under BOTH XML parsers and answer the unique results: tdom
# where it is installed, and the built-in one either way. A drawing has to
# come out the same whichever parsed it, and without this the fallback is
# only exercised on machines that happen to lack tdom - which is nowhere.
#
# Here rather than in one test file because a SECOND file wants it: svg.test
# has asked since the parser split, svgClip.test since clip-rule learned to
# look at its ancestors, and the answer to "do both parsers agree" is the
# same question in both.
proc ::tclpdfTest::bothParsers {script} {
  set saved $::tclpdf::xml::haveTdom
  set results {}
  foreach mode {1 0} {
    if {$mode && !$saved} {
      continue
    }
    set ::tclpdf::xml::haveTdom $mode
    lappend results [uplevel 1 $script]
  }
  set ::tclpdf::xml::haveTdom $saved
  return [lsort -unique $results]
}

# A scratch path inside the tcltest temporary directory.
proc ::tclpdfTest::scratch {name} {
  return [file join [::tcltest::temporaryDirectory] $name]
}

# Write the same document twice and return both files as bytes.
#
# The write events fire on EVERY write, so anything that creates objects has
# to be idempotent - that contract is what these tests check, and each one of
# them was writing the same six lines to do it. The files are removed again;
# what the caller gets is the two contents.
# Run a script in a FRESH interpreter - the same tclsh, the source tree on
# its auto_path, nothing loaded - and hand back what it printed. The one way
# to measure that a module loads itself through the core's types table: the
# interpreter running the tests has every module loaded already. Round 7
# hoisted this out of three field tests that each carried the eight lines.
proc ::tclpdfTest::freshInterp {script} {
  set here [file normalize [file dirname [file dirname [info script]]]]
  set path [::tclpdfTest::scratch freshInterp-[pid].tcl]
  set channel [open $path w]
  # In FRONT of the path, as all.tcl and every example put the tree: for an
  # equal version Tcl runs the ifneeded script registered last and reads
  # auto_path from the back, so an appended tree lost to an installed copy
  # (measured 2026-09-27, see all.tcl).
  puts $channel "set auto_path \[linsert \$auto_path 0 [list $here]\]"
  puts $channel $script
  close $channel
  try {
    set out [exec [info nameofexecutable] $path]
  } finally {
    file delete $path
  }
  return $out
}

proc ::tclpdfTest::writeTwice {doc name} {
  set first [scratch $name-a.pdf]
  set second [scratch $name-b.pdf]
  $doc write $first
  $doc write $second
  set result [list [readBytes $first] [readBytes $second]]
  file delete $first $second
  return $result
}

# Try to write a document and report whether it came out, cleaning up either
# way: {code written}, both 0 or 1.
#
# For the tests that turn on a document being ACCEPTED rather than on what is
# in it - PDF/A refusing an unembedded face is the usual reason. The write
# itself may fail, so the file has to be asked about separately, and the
# scratch file has to go whether it did or not.
proc ::tclpdfTest::writes {doc name} {
  set path [scratch $name]
  set code [catch {$doc write $path}]
  set written [expr {[file exists $path] ? 1 : 0}]
  file delete $path
  return [list $code $written]
}

# veraPDF over a written file: "ok" when it says the document keeps the
# profile it was asked about, its whole report when it does not, and "ok"
# where veraPDF is not installed - a missing tool is a SKIP in this tree, not
# a failure.
#
# The same seven lines stood in five test files (color, image twice, pdfa,
# sign) before this proc existed, each with its own idea of which flag to
# pass and what to do with the report. What "flavour" takes is what verapdf's
# -f takes: 3b, 3a, 2b, ua1.
proc ::tclpdfTest::verapdf {path flavour} {
  if {[auto_execok verapdf] eq {}} {
    return ok
  }
  catch {exec verapdf -f $flavour $path 2>@1} report
  if {[regexp {failedChecks="0"} $report]} {
    return ok
  }
  return $report
}

# One list of tokens per show operator in a content stream: a string in
# parentheses stays one token, a TJ number is one token of its own. Reading
# them with a plain [split] is what a first attempt does, and it breaks on the
# escaped parentheses inside the glyph bytes.
#
# Kept per OPERATOR rather than in one flat list, because where a number sits
# between the pieces is exactly what a test about kerning or word spacing has
# to see: the same amounts in the same order but one glyph further on is a
# different line.
proc ::tclpdfTest::shows {stream} {
  set result {}
  foreach line [split $stream \n] {
    if {![string match {*Tj*} $line] && ![string match {*TJ*} $line]} {
      continue
    }
    lappend result [regexp -all -inline \
        {\((?:[^()\\]|\\.)*\)|-?[0-9]+(?:\.[0-9]+)?} $line]
  }
  return $result
}

# The two-byte glyph numbers inside ONE string token of a show operator.
#
# Three lines that look like nothing and are the trap of this file: the glyph
# bytes are a PDF string, so a byte that happens to be a parenthesis or a
# backslash arrives escaped, and reading the token as it stands gives a glyph
# number that is off by one byte from there on. [subst] with both switches is
# what undoes it - with both, because the bytes are arbitrary and a "$" or a
# "[" in them is not a substitution. Written once here; every caller that
# reads glyphs out of a stream goes through it.
proc ::tclpdfTest::glyphsOf {token} {
  binary scan [subst -nocommands -novariables \
      [string range $token 1 end-1]] Su* glyphs
  return $glyphs
}

# The GLYPH NUMBERS of a stream, one list per show operator, with the
# adjustments left out - what a test about which face drew how many glyphs
# asks for.
proc ::tclpdfTest::glyphIds {stream} {
  set result {}
  foreach tokens [shows $stream] {
    set ids {}
    foreach token $tokens {
      if {[string index $token 0] ne "("} {
        continue
      }
      lappend ids {*}[glyphsOf $token]
    }
    lappend result $ids
  }
  return $result
}

# Only the numbers of such a token list - the adjustments, without the glyphs.
proc ::tclpdfTest::numbers {tokens} {
  return [lmap token $tokens {
    if {[string index $token 0] eq "("} continue
    set token
  }]
}

# What a content stream actually DRAWS, as characters and adjustments in the
# order they are written: the glyph numbers read back through the character
# map of the embedded face.
#
# Five test files need this and none of them can do without it: a stream holds
# glyph numbers, and a test about the ORDER of a right-to-left line has to
# speak about characters or it asserts nothing a reader could check. The map
# is turned round rather than looked up per glyph, because a face has tens of
# thousands of entries and a line has twenty glyphs.
#
# Returns one {kind value} pair per piece over the whole stream: {text ...}
# for a run of glyphs, {gap ...} for an adjustment between two of them. Tagged
# rather than left to tell apart by looking, because [string is double] says
# yes to " 4711" - a piece of a line that is a space and a number is not a
# number, and a test that sorted them that way dropped it.
proc ::tclpdfTest::drawn {doc alias stream} {
  set back {}
  dict for {code glyph} [dict get [$doc state fonts] $alias parsed cmap] {
    dict set back $glyph $code
  }
  set result {}
  foreach tokens [shows $stream] {
    foreach token $tokens {
      if {[string index $token 0] ne "("} {
        lappend result [list gap $token]
        continue
      }
      set glyphs [glyphsOf $token]
      set text {}
      foreach glyph $glyphs {
        append text [expr {[dict exists $back $glyph] ?
            [format %c [dict get $back $glyph]] : "?"}]
      }
      lappend result [list text $text]
    }
  }
  return $result
}

# The same, as one string: the characters of the line in drawing order, with
# the adjustments left out. What a reader sees, left to right.
proc ::tclpdfTest::drawnText {doc alias stream} {
  set text {}
  foreach piece [drawn $doc $alias $stream] {
    if {[lindex $piece 0] eq "text"} {
      append text [lindex $piece 1]
    }
  }
  return $text
}

# The decoded stream of one object - for tests that have to look inside a
# compressed stream (a font file, a ToUnicode map, a CIDToGIDMap).
proc ::tclpdfTest::streamOf {writer number} {
  package require tclpdf::filter
  if {$number eq {}} {
    return {}
  }
  set body [$writer body $number]
  set start [expr {[string first "stream\n" $body] + 7}]
  set stop [expr {[string last "\nendstream" $body] - 1}]
  set data [string range $body $start $stop]
  if {[string match {*/Filter /FlateDecode*} $body]} {
    set data [::tclpdf::filter decodeFlate $data]
  }
  return $data
}

# The raw glyf data of one glyph, or the empty string for a glyph that has
# none - a space, for instance.
#
# Three test files reach for this, which is two too many for a copy: the
# offsets come from loca and getting them wrong reads the neighbouring glyph
# rather than failing.
proc ::tclpdfTest::glyph {font id} {
  set loca [dict get $font loca]
  if {$id + 1 >= [llength $loca]} {
    return {}
  }
  set start [lindex $loca $id]
  set stop [lindex $loca [expr {$id + 1}]]
  if {$start >= $stop} {
    return {}
  }
  return [string range [::tclpdf::sfnt table $font glyf] $start \
      [expr {$stop - 1}]]
}

# A glyph run as font.tcl builds it from the cmap, before any substitution:
# entries {glyph codes}, one character per entry, in logical order.
#
# Two test files build one - ligatures shorten it, cursive forms lengthen it -
# and both need it to be exactly what the font module would have handed on.
proc ::tclpdfTest::glyphRun {parsed text} {
  set cmap [dict get $parsed cmap]
  set run {}
  foreach char [split $text {}] {
    set code [scan $char %c]
    lappend run [list [dict get $cmap $code] [list $code]]
  }
  return $run
}

# The -errorcode of a refusal, or a line saying there was none. Every parser in
# the package refuses damaged input by name rather than half-reading it, so its
# test file asks the same question over and over: WHICH refusal came back. The
# answer has to be the code, not the message - a message may be reworded, the
# code is the contract. Written to return a string in both cases so that a test
# comparing against an expected code reports the unexpected success as a
# result, not as an error somewhere else.
proc ::tclpdfTest::refusal {script} {
  if {[catch {uplevel 1 $script} result options] == 0} {
    return "no error: $result"
  }
  return [dict get $options -errorcode]
}

# --- COLR version 1 fixtures -----------------------------------------------
#
# Here rather than in colrPaint.test because colorFontPaint.test builds its
# faces out of the same assembler, and a second copy of a byte layout is the
# copy that gets fixed last - the same reason the TIFF fixtures above stand
# here.
#

# F2DOT14 holds -2.0 to just under 2.0, and an angle is written as 180 degrees
# per 1.0 of it. Out of range is refused here rather than written, because the
# wrong answer looks like a flat fill and a fixture that lies is worse than no
# fixture.
proc ::tclpdfTest::colrF2Dot14 {value} {
  set number [expr {int(round($value * 16384))}]
  if {$number < -32768 || $number > 32767} {
    error "$value is outside the range of an F2DOT14 (-2.0 to just under 2.0)"
  }
  return [binary format S $number]
}

# Fixed, signed 16.16 - the type an Affine2x3 stores its six numbers in.
proc ::tclpdfTest::colrFixed {value} {
  return [binary format I [expr {int(round($value * 65536))}]]
}

# Offset24, three bytes big-endian: the width every offset inside a paint
# graph has, and the reason this format needs an assembler at all.
proc ::tclpdfTest::colrOffset24 {value} {
  return [binary format c* [list [expr {($value >> 16) & 0xFF}] \
      [expr {($value >> 8) & 0xFF}] [expr {$value & 0xFF}]]]
}

# A ColorLine: the extend mode, then {offset paletteIndex alpha} per stop.
#
# A VarColorLine is the same with a varIndexBase behind every stop, which
# makes its stops ten bytes rather than six - so a Var gradient has to carry
# one, and the Var gradient formats are the only ones that may.
proc ::tclpdfTest::colrLine {extend stops {varying 0}} {
  set table [binary format cSu [dict get {pad 0 repeat 1 reflect 2} $extend] \
      [llength $stops]]
  foreach stop $stops {
    lassign $stop offset entry alpha
    append table [::tclpdfTest::colrF2Dot14 $offset] [binary format Su $entry] \
        [::tclpdfTest::colrF2Dot14 $alpha]
    if {$varying} {
      append table [binary format Iu 7]
    }
  }
  return $table
}

# One paint sub-tree as bytes. The kinds, and the fields each takes:
#
#   {solid palette alpha}
#   {linear extend stops {x0 y0} {x1 y1} {x2 y2}}
#   {radial extend stops {x0 y0} r0 {x1 y1} r1}
#   {sweep extend stops {cx cy} startAngle endAngle}
#   {glyph gid paint}        {colrGlyph gid}       {layers first count}
#   {transform {a b c d e f} paint}   {translate dx dy paint}
#   {scale sx sy paint}      {scaleCenter sx sy cx cy paint}
#   {scaleUniform s paint}   {scaleUniformCenter s cx cy paint}
#   {rotate deg paint}       {rotateCenter deg cx cy paint}
#   {skew x y paint}         {skewCenter x y cx cy paint}
#   {composite mode source backdrop}
#   {raw bytes}              anything the assembler will not write
#   {padded count paint}     the paint, then count dead bytes behind it
#
# and {var <kind> ...} writes the Var twin of a kind: the same fields with a
# varIndexBase behind them. The reader must produce the same node for both.
proc ::tclpdfTest::colrPaint {spec} {
  set kind [lindex $spec 0]
  set varying 0
  if {$kind eq "var"} {
    set varying 1
    set spec [lrange $spec 1 end]
    set kind [lindex $spec 0]
  }
  set tail [expr {$varying ? [binary format Iu 7] : {}}]
  switch -- $kind {
    solid {
      return [binary format cSu [expr {$varying ? 3 : 2}] \
          [lindex $spec 1]][::tclpdfTest::colrF2Dot14 [lindex $spec 2]]$tail
    }
    linear {
      lassign $spec . extend stops p0 p1 p2
      set head [binary format c [expr {$varying ? 5 : 4}]]
      append head [::tclpdfTest::colrOffset24 [expr {$varying ? 20 : 16}]]
      append head [binary format SSSSSS {*}$p0 {*}$p1 {*}$p2]
      return $head$tail[::tclpdfTest::colrLine $extend $stops $varying]
    }
    radial {
      lassign $spec . extend stops c0 r0 c1 r1
      set head [binary format c [expr {$varying ? 7 : 6}]]
      append head [::tclpdfTest::colrOffset24 [expr {$varying ? 20 : 16}]]
      append head [binary format SSSuSSSu {*}$c0 $r0 {*}$c1 $r1]
      return $head$tail[::tclpdfTest::colrLine $extend $stops $varying]
    }
    sweep {
      lassign $spec . extend stops centre start end
      set head [binary format c [expr {$varying ? 9 : 8}]]
      append head [::tclpdfTest::colrOffset24 [expr {$varying ? 16 : 12}]]
      append head [binary format SS {*}$centre]
      # THE SWEEP'S TWO ANGLES CARRY A BIAS OF 1.0 and the rotation's and the
      # skew's do not: the font stores degrees / 180 - 1, so 0 to 360 is
      # -1.0 to 1.0 and a whole turn fits where 358 was the ceiling without
      # it. A fixture written without the bias makes every sweep in this
      # suite half a circle out and agrees with a reader that has the same
      # gap - which is how the gap survived until 2026-08-26.
      append head [::tclpdfTest::colrF2Dot14 [expr {$start / 180.0 - 1.0}]] \
          [::tclpdfTest::colrF2Dot14 [expr {$end / 180.0 - 1.0}]]
      return $head$tail[::tclpdfTest::colrLine $extend $stops $varying]
    }
    glyph {
      set child [::tclpdfTest::colrPaint [lindex $spec 2]]
      return [binary format c 10][::tclpdfTest::colrOffset24 6][binary format Su \
          [lindex $spec 1]]$child
    }
    colrGlyph {
      return [binary format cSu 11 [lindex $spec 1]]
    }
    layers {
      return [binary format ccIu 1 [lindex $spec 2] [lindex $spec 1]]
    }
    transform {
      set child [::tclpdfTest::colrPaint [lindex $spec 2]]
      set affine {}
      foreach value [lindex $spec 1] {
        append affine [::tclpdfTest::colrFixed $value]
      }
      append affine $tail
      return [binary format c [expr {$varying ? 13 : 12}]][::tclpdfTest::colrOffset24 \
          [expr {7 + [string length $affine]}]][::tclpdfTest::colrOffset24 7]$affine$child
    }
    translate {
      set body [binary format SS [lindex $spec 1] [lindex $spec 2]]$tail
      return [binary format c [expr {$varying ? 15 : 14}]][::tclpdfTest::colrOffset24 \
          [expr {4 + [string length $body]}]]$body[::tclpdfTest::colrPaint [lindex $spec 3]]
    }
    scale {
      set body [::tclpdfTest::colrF2Dot14 [lindex $spec 1]][::tclpdfTest::colrF2Dot14 [lindex $spec 2]]$tail
      return [binary format c [expr {$varying ? 17 : 16}]][::tclpdfTest::colrOffset24 \
          [expr {4 + [string length $body]}]]$body[::tclpdfTest::colrPaint [lindex $spec 3]]
    }
    scaleCenter {
      set body [::tclpdfTest::colrF2Dot14 [lindex $spec 1]][::tclpdfTest::colrF2Dot14 [lindex $spec 2]]
      append body [binary format SS [lindex $spec 3] [lindex $spec 4]] $tail
      return [binary format c [expr {$varying ? 19 : 18}]][::tclpdfTest::colrOffset24 \
          [expr {4 + [string length $body]}]]$body[::tclpdfTest::colrPaint [lindex $spec 5]]
    }
    scaleUniform {
      set body [::tclpdfTest::colrF2Dot14 [lindex $spec 1]]$tail
      return [binary format c [expr {$varying ? 21 : 20}]][::tclpdfTest::colrOffset24 \
          [expr {4 + [string length $body]}]]$body[::tclpdfTest::colrPaint [lindex $spec 2]]
    }
    scaleUniformCenter {
      set body [::tclpdfTest::colrF2Dot14 [lindex $spec 1]]
      append body [binary format SS [lindex $spec 2] [lindex $spec 3]] $tail
      return [binary format c [expr {$varying ? 23 : 22}]][::tclpdfTest::colrOffset24 \
          [expr {4 + [string length $body]}]]$body[::tclpdfTest::colrPaint [lindex $spec 4]]
    }
    rotate {
      set body [::tclpdfTest::colrF2Dot14 [expr {[lindex $spec 1] / 180.0}]]$tail
      return [binary format c [expr {$varying ? 25 : 24}]][::tclpdfTest::colrOffset24 \
          [expr {4 + [string length $body]}]]$body[::tclpdfTest::colrPaint [lindex $spec 2]]
    }
    rotateCenter {
      set body [::tclpdfTest::colrF2Dot14 [expr {[lindex $spec 1] / 180.0}]]
      append body [binary format SS [lindex $spec 2] [lindex $spec 3]] $tail
      return [binary format c [expr {$varying ? 27 : 26}]][::tclpdfTest::colrOffset24 \
          [expr {4 + [string length $body]}]]$body[::tclpdfTest::colrPaint [lindex $spec 4]]
    }
    skew {
      set body [::tclpdfTest::colrF2Dot14 [expr {[lindex $spec 1] / 180.0}]]
      append body [::tclpdfTest::colrF2Dot14 [expr {[lindex $spec 2] / 180.0}]] $tail
      return [binary format c [expr {$varying ? 29 : 28}]][::tclpdfTest::colrOffset24 \
          [expr {4 + [string length $body]}]]$body[::tclpdfTest::colrPaint [lindex $spec 3]]
    }
    skewCenter {
      set body [::tclpdfTest::colrF2Dot14 [expr {[lindex $spec 1] / 180.0}]]
      append body [::tclpdfTest::colrF2Dot14 [expr {[lindex $spec 2] / 180.0}]]
      append body [binary format SS [lindex $spec 3] [lindex $spec 4]] $tail
      return [binary format c [expr {$varying ? 31 : 30}]][::tclpdfTest::colrOffset24 \
          [expr {4 + [string length $body]}]]$body[::tclpdfTest::colrPaint [lindex $spec 5]]
    }
    composite {
      set source [::tclpdfTest::colrPaint [lindex $spec 2]]
      set backdrop [::tclpdfTest::colrPaint [lindex $spec 3]]
      return [binary format c 32][::tclpdfTest::colrOffset24 8][binary format c \
          [lindex $spec 1]][::tclpdfTest::colrOffset24 \
          [expr {8 + [string length $source]}]]$source$backdrop
    }
    raw {
      return [lindex $spec 1]
    }
    padded {
      # A paint with dead bytes behind it, so that whatever follows in the
      # SAME blob sits a stated distance further on. The only way to make an
      # Offset24 inside a paint graph actually need its third byte: every
      # offset in this format is relative to its own record, and an assembler
      # that writes the child straight after the parent never produces one
      # above 255 - let alone above 65535, which is where a reader that took
      # the low two bytes stops being right.
      return [::tclpdfTest::colrPaint [lindex $spec 2]][string repeat \x00 \
          [lindex $spec 1]]
    }
  }
  error "unknown paint kind \"$kind\""
}

# The whole version 1 table.
#
#   base      list of {glyphId paint} - the BaseGlyphList
#   layers    list of paints - the LayerList a {layers first count} slices into
#   clips     list of {startGlyph endGlyph {xMin yMin xMax yMax}}
#   v0        list of {glyphId firstLayer numLayers} - the version 0 records a
#             version 1 table may carry BESIDE the new ones (5.7.11)
#   v0Layers  list of {glyphId paletteIndex}
proc ::tclpdfTest::colrTableV1 {base layers {clips {}} {v0 {}} {v0Layers {}}} {
  set baseListAt 34
  set records {}
  set blobs {}
  set at [expr {4 + [llength $base] * 6}]
  foreach entry $base {
    lassign $entry glyph paint
    set bytes [::tclpdfTest::colrPaint $paint]
    # The paint offset is measured from the start of the BaseGlyphList, not
    # from the start of the table.
    append records [binary format SuIu $glyph $at]
    append blobs $bytes
    incr at [string length $bytes]
  }
  set baseList [binary format Iu [llength $base]]$records$blobs
  set layerListAt [expr {$baseListAt + [string length $baseList]}]
  set layerList {}
  if {[llength $layers]} {
    set offsets {}
    set blobs {}
    set at [expr {4 + [llength $layers] * 4}]
    foreach paint $layers {
      set bytes [::tclpdfTest::colrPaint $paint]
      append offsets [binary format Iu $at]
      append blobs $bytes
      incr at [string length $bytes]
    }
    set layerList [binary format Iu [llength $layers]]$offsets$blobs
  }
  set clipListAt [expr {$layerListAt + [string length $layerList]}]
  set clipList {}
  if {[llength $clips]} {
    set records {}
    set boxes {}
    set at [expr {5 + [llength $clips] * 7}]
    foreach clip $clips {
      lassign $clip first last box
      append records [binary format SuSu $first $last][::tclpdfTest::colrOffset24 $at]
      append boxes [binary format c 1][binary format SSSS {*}$box]
      incr at 9
    }
    set clipList [binary format cIu 1 [llength $clips]]$records$boxes
  }
  set v0At [expr {$clipListAt + [string length $clipList]}]
  set v0Records {}
  foreach record $v0 {
    append v0Records [binary format SuSuSu {*}$record]
  }
  set v0LayerAt [expr {$v0At + [string length $v0Records]}]
  set v0LayerRecords {}
  foreach record $v0Layers {
    append v0LayerRecords [binary format SuSu {*}$record]
  }
  set header [binary format SuSuIuIuSu 1 [llength $v0] \
      [expr {[llength $v0] ? $v0At : 0}] \
      [expr {[llength $v0Layers] ? $v0LayerAt : 0}] [llength $v0Layers]]
  append header [binary format IuIuIuIuIu $baseListAt \
      [expr {[llength $layers] ? $layerListAt : 0}] \
      [expr {[llength $clips] ? $clipListAt : 0}] 0 0]
  return $header$baseList$layerList$clipList$v0Records$v0LayerRecords
}

# --- TIFF fixtures ---------------------------------------------------------
#
# Here rather than in imageTiff.test because imageTiffStreams.test builds its
# pictures out of the same four procedures, and a second copy of a byte layout
# is the copy that gets fixed last.

# The bytes of one field's values, in the file's byte order.
proc ::tclpdfTest::tiffValues {order type values} {
  set big [expr {$order eq "MM"}]
  switch -- $type {
    2 - 7 {return $values}
    1 - 6 {return [binary format c* $values]}
    3 - 8 {return [binary format [expr {$big ? "S*" : "s*"}] $values]}
    4 - 9 - 13 {return [binary format [expr {$big ? "I*" : "i*"}] $values]}
    5 - 10 {
      set result {}
      foreach {top bottom} $values {
        append result [binary format [expr {$big ? "II" : "ii"}] $top $bottom]
      }
      return $result
    }
  }
  # A type the format does not define - written as it stands, so that a
  # fixture can carry one and the reader can be seen to step over it.
  return $values
}

# How many values a field holds - which is not the same as how many bytes.
proc ::tclpdfTest::tiffCount {type values} {
  switch -- $type {
    2 - 7 {return [string length $values]}
    5 - 10 {return [expr {[llength $values] / 2}]}
  }
  return [llength $values]
}

# A whole TIFF file.
#
# "directories" is a list of directories, each a list of entries. Everything
# is laid out in one order: header, image data at offset 8, then the overflow
# value areas of every directory, then the directories themselves. The next
# pointer of each one names the following directory, and of the last one is 0
# unless -next says otherwise.
proc ::tclpdfTest::tiffFile {directories args} {
  array set option {-order MM -version 42 -data {} -next {} -first {}}
  array set option $args
  set order $option(-order)
  set big [expr {$order eq "MM"}]
  set short [expr {$big ? "S" : "s"}]
  set long [expr {$big ? "I" : "i"}]

  # Where the overflow area of each directory begins, and where each
  # directory itself does. Both are wanted before a single entry is written,
  # because an entry either holds its values or points at them.
  set at [expr {8 + [string length $option(-data)]}]
  set bases {}
  set blobs {}
  foreach entries $directories {
    set blob {}
    foreach entry $entries {
      lassign $entry tag type values
      set payload [::tclpdfTest::tiffValues $order $type $values]
      if {[string length $payload] > 4} {
        append blob $payload
      }
    }
    lappend bases $at
    lappend blobs $blob
    incr at [string length $blob]
  }
  set offsets {}
  foreach entries $directories {
    lappend offsets $at
    incr at [expr {2 + 12 * [llength $entries] + 4}]
  }

  set file "$order[binary format $short $option(-version)]"
  append file [binary format $long \
      [expr {$option(-first) ne {} ? $option(-first) : [lindex $offsets 0]}]]
  append file $option(-data)
  append file [join $blobs {}]

  set index 0
  foreach entries $directories base $bases {
    append file [binary format $short [llength $entries]]
    set used 0
    foreach entry $entries {
      lassign $entry tag type values
      set payload [::tclpdfTest::tiffValues $order $type $values]
      append file [binary format ${short}${short}${long} \
          $tag $type [::tclpdfTest::tiffCount $type $values]]
      if {[string length $payload] > 4} {
        append file [binary format $long [expr {$base + $used}]]
        incr used [string length $payload]
      } else {
        append file $payload
        append file [string repeat \x00 [expr {4 - [string length $payload]}]]
      }
    }
    incr index
    if {$index < [llength $directories]} {
      append file [binary format $long [lindex $offsets $index]]
    } elseif {$option(-next) ne {}} {
      append file [binary format $long $option(-next)]
    } else {
      append file [binary format $long 0]
    }
  }
  return $file
}

# The tags of a plain 4 x 4 greyscale image, 8 bits, one strip of 16 bytes at
# offset 8. Every test that is about one tag starts here and replaces that one
# tag, so that what is being tested is the only thing that differs.
proc ::tclpdfTest::tiffBase {} {
  return [list \
      [list 256 3 4] \
      [list 257 3 4] \
      [list 258 3 8] \
      [list 259 3 1] \
      [list 262 3 1] \
      [list 273 4 8] \
      [list 277 3 1] \
      [list 278 3 4] \
      [list 279 4 16] \
      [list 282 5 {300 1}] \
      [list 283 5 {300 1}] \
      [list 284 3 1] \
      [list 296 3 2]]
}

# The same entries with some replaced or added, kept in ascending tag order
# the way the format asks for.
proc ::tclpdfTest::tiffWith {entries args} {
  foreach entry $args {
    set index [lsearch -exact -index 0 $entries [lindex $entry 0]]
    if {$index >= 0} {
      set entries [lreplace $entries $index $index $entry]
    } else {
      lappend entries $entry
    }
  }
  return [lsort -integer -index 0 $entries]
}

# The same entries with some tags left out.
proc ::tclpdfTest::tiffWithout {entries args} {
  foreach tag $args {
    set index [lsearch -exact -index 0 $entries $tag]
    if {$index >= 0} {
      set entries [lreplace $entries $index $index]
    }
  }
  return $entries
}

# Sixty-four bytes of picture, so that a strip offset has somewhere to point.
set ::tiffData [string repeat \xa5 64]

# A file from one directory, with the base tags and the changes handed in.
# Everything up to the first option is an entry; the rest goes to [::tclpdfTest::tiffFile].
proc ::tclpdfTest::tiffOne {args} {
  set entries {}
  set options {}
  set index 0
  foreach item $args {
    if {[string match -* $item]} {
      set options [lrange $args $index end]
      break
    }
    lappend entries $item
    incr index
  }
  return [::tclpdfTest::tiffFile [list [::tclpdfTest::tiffWith [::tclpdfTest::tiffBase] {*}$entries]] \
      -data $::tiffData {*}$options]
}

# The -errorcode of a refusal, so that a test asserts the CONTRACT rather than
# the wording of a message.

# --- the signature ---------------------------------------------------------

# --- fixtures a second test file needs -------------------------------------
#
# Both of these were written for tests/import.test and moved here unchanged
# when tests/importFields.test wanted them too - which is what the head of
# this file says is to happen rather than a copy being made.

# A classic-table file from a list of object bodies, byte for byte - the
# boilerplate of [handcrafted], extracted when the norm-review fixtures
# would have been its fourth copy.
# "extra" is written into the trailer beside /Size and /Root - for the
# fixtures whose point is an entry that hangs off the trailer rather than off
# the catalog, /Info being the one that has one.
proc ::tclpdfTest::buildpdf {name objects {extra {}}} {
    set out "%PDF-1.4\n"
    set offsets {}
    set number 0
    foreach body $objects {
        lappend offsets [string length $out]
        append out "[incr number] 0 obj\n$body\nendobj\n"
    }
    set xref [string length $out]
    append out "xref\n0 [expr {$number + 1}]\n"
    append out [format "%010d %05d f \n" 0 65535]
    foreach offset $offsets {
        append out [format "%010d %05d n \n" $offset 0]
    }
    append out "trailer\n<< /Size [expr {$number + 1}] /Root 1 0 R $extra >>\n"
    append out "startxref\n$xref\n%%EOF\n"
    set path [scratch $name]
    set channel [open $path wb]
    puts -nonewline $channel $out
    close $channel
    return $path
}

# What a script under test raises: {code tclpdf? errorcode}. "tclpdf?" is 1
# when the message opens with "tclpdf:", the guarantee of doc/tclpdf.md - so a
# refusal reads {1 1 {TCLPDF ...}} and a clean run {0 0 {}}.
proc ::tclpdfTest::refuse {script} {
    set code [catch {uplevel 1 $script} msg opts]
    return [list $code [string match {tclpdf:*} $msg] \
        [dict get $opts -errorcode]]
}

# The colour of one or more points of a rendered page, each as {r g b} 0..255.
# Rendered as a PPM rather than a PNG: P6 is a header and the bytes, and
# reading it needs nothing but [binary scan].
#
# ONE rendering for all the points, because a mesh or a gradient has to be
# judged at its corners AND in the middle, and rendering the same page once
# per point is both slower and - if the renderer ever wobbles - a comparison
# of two different pictures.
#
# -unit is the unit the POINTS are in, and it is the whole reason this used to
# be two procedures: a page of this package is laid out in millimetres, while
# a shading test speaks in the PDF points its shading dictionary is written
# in. Getting it wrong does not fail, it reads the wrong pixel.
proc ::tclpdfTest::pixels {path points args} {
  set dpi 72
  set unit pt
  foreach {option value} $args {
    switch -- $option {
      -dpi {set dpi $value}
      -unit {set unit $value}
      default {error "unknown option \"$option\" - known are -dpi -unit"}
    }
  }
  set per [expr {$unit eq "mm" ? 25.4 : 72.0}]
  set stem [::tclpdfTest::scratch [file rootname [file tail $path]]-ppm]
  exec {*}[auto_execok pdftoppm] -r $dpi $path $stem
  set ppm [glob $stem-*.ppm]
  set bytes [::tclpdfTest::readBytes [lindex $ppm 0]]
  file delete {*}$ppm
  # P6, width, height, maximum - whitespace separated, then the raw triples.
  regexp {^P6\s+(\d+)\s+(\d+)\s+(\d+)\s} $bytes header width height -
  set offset [string length $header]
  set result {}
  foreach point $points {
    lassign $point x y
    set column [expr {int($x * $dpi / $per)}]
    set row [expr {int($y * $dpi / $per)}]
    set start [expr {$offset + ($row * $width + $column) * 3}]
    binary scan [string range $bytes $start [expr {$start + 2}]] cu3 rgb
    lappend result $rgb
  }
  return $result
}

# One point, in millimetres - the shape the colour tests have always used.
proc ::tclpdfTest::pixel {path x y {dpi 20}} {
  return [lindex [::tclpdfTest::pixels $path [list [list $x $y]] -dpi $dpi -unit mm] 0]
}

# The -errorcode of a refusal, or the string "no refusal" when the call went
# through. A test that reported a missing refusal as an empty code would look
# like a code mismatch and send the reader to the wrong place.
#
# Here rather than in one test file since 2026-08-24, when the font sub-modules
# got the codes they had never carried: three files ask this question, and the
# next one that refuses something will be the fourth.
proc ::tclpdfTest::refusalCode {script} {
  if {![catch {uplevel 1 $script} message options]} {
    return "no refusal"
  }
  return [dict get $options -errorcode]
}

# How many refusals in a module reach a caller with no code at all. The
# contract is that a documented class is trappable, and a bare "return -code
# error" defeats it silently - the caller sees NONE and its trap never fires.
# Counted in the source rather than by calling every refusal, because most of
# them need a fixture that does not exist and the question is about the module
# as a whole.
proc ::tclpdfTest::refusalsWithoutCode {module} {
  set path [file join [file dirname [file dirname [file normalize \
      [info script]]]] $module]
  set channel [open $path]
  set text [read $channel]
  close $channel
  # THE NEXT LINE COUNTS TOO. A refusal whose message is long enough is
  # written as "return -code error \\" with the -errorcode on the line
  # below, and looking at one line at a time called every one of those bare:
  # measured 2026-08-25, afm.tcl came back as 6 where 3 is the truth, and
  # colorFont.tcl as 7 where it is 3. A guard that overcounts is worse than
  # none, because the number it reports cannot be used as a limit.
  set lines [split $text \n]
  set bare 0
  for {set index 0} {$index < [llength $lines]} {incr index} {
    set line [lindex $lines $index]
    if {![string match {*return -code error*} $line]} {
      continue
    }
    set pair $line[lindex $lines [expr {$index + 1}]]
    if {![string match {*-errorcode*} $pair]} {
      incr bare
    }
  }
  return $bare
}

# --- GSUB fixtures ---------------------------------------------------------
#
# Here rather than in gsubApply.test because gsubContext.test assembles its
# tables out of the same three pieces, and a second copy of a byte layout is
# the copy that gets fixed last.
#
# WHY A WHOLE TABLE IS BUILT AT ALL. A contextual lookup names the lookups it
# applies BY INDEX in the lookup list, so there is no way to exercise one
# through its subtable alone: the index has to point at something. The same
# goes for the extension lookup, whose whole content is an offset to a lookup
# of another type. Both are therefore tested through [gsubApply prepare],
# which needs the script list and the feature list as well - and those are
# eleven lines to assemble and unreadable to write by hand twice.

# One lookup of a lookup list, from its subtables. The offsets are relative to
# the start of the lookup, which is what the format says and what a reader
# that adds the lookup list offset by mistake gets wrong.
proc ::tclpdfTest::gsubLookup {type flag subtables} {
  set count [llength $subtables]
  set at [expr {6 + $count * 2}]
  set offsets {}
  foreach subtable $subtables {
    lappend offsets $at
    incr at [string length $subtable]
  }
  return [binary format Su* [list $type $flag $count {*}$offsets]][join \
      $subtables {}]
}

# Lookup type 1, format 2: one glyph becomes one other.
#
#   0  format 2 | 2  coverage at 8 | 4  one glyph | 6  the substitute
#   8  coverage format 1, one glyph
#
# Here since 2026-08-26: forms.test builds a face whose rlig and liga each
# hold one of these, to show which of the two stages runs first.
proc ::tclpdfTest::gsubSingle {from to} {
  return [binary format Su* [list 2 8 1 $to 1 1 $from]]
}

# Lookup type 2, format 1: one glyph becomes several.
#
#   0  format 1 | 2  coverage at 8 | 4  one sequence | 6  sequence at 14
#   8  coverage format 1, one glyph | 14  the sequence
#
# Here since colorFont.test needs one to show what it refuses: a "ccmp" that
# takes a character apart cannot become a Type 3 glyph.
proc ::tclpdfTest::gsubMultiple {from outputs} {
  return [binary format Su* [list 1 8 1 14 1 1 $from [llength $outputs] \
      {*}$outputs]]
}

# Lookup type 4, format 1: several glyphs become one.
#
#   0  format 1 | 2  coverage at 8 | 4  one set | 6  set at 14
#   8  coverage format 1, the FIRST component
#  14  ligature set: one ligature, at 14+4 = 18
#  18  the ligature glyph, the component count, the components after the first
#
# Here rather than in gsubApply.test since 2026-08-26: colorFont.test builds a
# face that forms SEQUENCES - a ZWJ family and a skin tone - and a ligature
# subtable is what a sequence is made of. A second copy of the layout is the
# copy that gets fixed last.
proc ::tclpdfTest::gsubLigature {components to} {
  return [binary format Su* [list 1 8 1 14 1 1 [lindex $components 0] 1 4 \
      $to [llength $components] {*}[lrange $components 1 end]]]
}

# An extension subtable around another subtable: format 1, the type it wraps,
# and a 32 bit offset from the start of the extension subtable itself.
proc ::tclpdfTest::gsubExtension {type subtable} {
  return [binary format SuSuIu 1 $type 8]$subtable
}

# A whole GSUB table: one script with one default language system, the
# features named in FEATURES (a dict tag -> list of lookup indices), and the
# lookups as they were handed in.
proc ::tclpdfTest::gsubTable {lookups features {script latn}} {
  set tags [dict keys $features]
  set featureCount [llength $tags]
  # The language system names every feature by its index in the feature list.
  set indices {}
  for {set index 0} {$index < $featureCount} {incr index} {
    lappend indices $index
  }
  set langSys [binary format Su* [list 0 0xFFFF $featureCount {*}$indices]]
  set scriptList [binary format Su 1][binary format a4 $script][binary \
      format Su 8][binary format Su* {4 0}]$langSys
  # The feature records first, then the feature tables they point at.
  set at [expr {2 + $featureCount * 6}]
  set records {}
  set bodies {}
  foreach tag $tags {
    set used [dict get $features $tag]
    set body [binary format Su* [list 0 [llength $used] {*}$used]]
    lappend records $tag $at
    lappend bodies $body
    incr at [string length $body]
  }
  set featureList [binary format Su $featureCount]
  foreach {tag offset} $records {
    append featureList [binary format a4 $tag][binary format Su $offset]
  }
  append featureList [join $bodies {}]
  set count [llength $lookups]
  set at [expr {2 + $count * 2}]
  set offsets {}
  foreach lookup $lookups {
    lappend offsets $at
    incr at [string length $lookup]
  }
  set lookupList [binary format Su* [list $count {*}$offsets]][join $lookups {}]
  set header 10
  return [binary format IuSuSuSu 0x00010000 $header \
      [expr {$header + [string length $scriptList]}] \
      [expr {$header + [string length $scriptList] \
          + [string length $featureList]}]]$scriptList$featureList$lookupList
}
