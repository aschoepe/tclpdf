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

# The bodies of every object whose text matches a pattern - what a test reads
# when it has to check what went into the FILE rather than what the API said.
#
# The same loop stands in graphics.test and font.test, which is one copy too
# many already; those two do further work inside it and can move here when
# somebody looks at them.
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
