# Document, pages, coordinates, writing, events

Every snippet on this page runs top to bottom as one script. `$assets`, `$out` and the file variables come from the setup block in `SKILL.md`.

## Create, configure, ask

```tcl
package require Tcl 8.6.11-       ;# the open-ended form: "8.6" alone is refused by Tcl 9
package require tclpdf

# mm, A4 portrait, PDF 1.7, compressed streams - all defaults, spelled out once.
set doc [tclpdf new -unit mm -format a4 -orientation portrait -version 1.7 -compress 1]

# What the document knows about itself.
puts "unit: [$doc cget -unit], format: [$doc cget -format], version: [$doc cget -version]"
puts "known formats: [tclpdf formats]"

# Options change afterwards; pages already added keep their size.
$doc configure -typeArea {20 20 25 25}     ;# top bottom left right, in the document unit
puts "type area margins: [$doc cget -typeArea]"
```

Two numbers as a format are taken as given (`{88 55}` stays 88 by 55) and are turned only when an orientation is asked for in the same call. `-version` is a promise about the file: a feature the version does not have (`opacity` below 1.4, a shading below 1.3, an embedded font below 1.2) is refused naming both, never raised silently. `pdfa` and `ua` are the exceptions - claims lift the version to 1.7 or 2.0. Below 1.2 there is no Flate: a `1.0` or `1.1` document needs `-compress 0`.

## Pages

```tcl
$doc page add                                     ;# document defaults
$doc page add -format a5 -orientation landscape   ;# a page of its own size
$doc page add -format {88 55}                     ;# width height in the document unit
$doc page add -rotate 90                          ;# a multiple of 90

puts "pages: [$doc page count], current: [$doc page current]"   ;# current counts from 0
puts "size of page 1: [$doc page size 1]"                       ;# {width height} in the unit

# The five page boxes: media, crop, bleed, trim, art - two CORNERS, not corner and size.
$doc page box trim {5 5 83 50}                    ;# on the current page
puts "media box of the first page: [$doc page box media {} 0]"  ;# empty value, then the index
```

The media box must measure 3 to 14400 pt a side and cannot be shrunk under a box already set. A box out of order or reaching beyond the media box is refused with both rectangles in the message.

## The type area

```tcl
# Where flowing text and breaking tables begin and end. Without -typeArea it is
# 5 % of the height top and bottom and 5 % of the width at the sides.
$doc page add
lassign [$doc page typeArea] x0 y0 x1 y1
puts "type area of this page: $x0 $y0 $x1 $y1"
```

`text -height max`, `text -paginate` and a `table` without `-top`/`-bottom` stop at `y1` and resume at `y0`. A running head belongs above `y0`.

## Coordinates and units

y counts **from the top**, `-at` is the **top left** corner of what is placed - except `circle` and `ellipse`, where it is the centre. Inside a form or a pattern script the origin is that object's own top left corner, y down, exactly as on the page.

```tcl
puts "PDF user space of {20 30}: [$doc coords 20 30]"   ;# points, y up, for a caller that needs it
puts "20 mm in points: [$doc distance 20]"
puts "one inch in points: [$doc distance 1 in]"
puts "an A6 sheet in points: [$doc extent {105 148}]"
```

## Diagnosis: what a call actually produced

```tcl
$doc rect -at {10 10} -size {30 20} -fill steelblue
puts [$doc page content]          ;# the content stream so far, as text
```

This is the way to see a graphics state that leaks past the shape that set it.

## Writing

```tcl
$doc info Title "Reference: document"
$doc font -family helvetica -size 10
$doc text "Written twice: to a file, and to a channel." -at {20 20}

$doc write [file join $out ref-01-document.pdf]

# A channel: a CGI response, a socket, a pipe. The caller opens and closes it;
# the package puts it into binary translation, and the xref offsets are counted
# from the header, so a channel that already carries an HTTP header is fine.
set channel [open [file join $out ref-01-document-channel.pdf] w]
$doc writeChannel $channel
close $channel
```

Writing does not finish the document: a second `write` of an unchanged document is byte-identical, and drawing between two writes works - the second file carries the additions.

## Events

```tcl
# beforeWrite, resources, catalog, info, afterWrite - and pageAdded after every
# page add, the ones text -paginate and a breaking table add included.
puts "events: [$doc events]"

# A running head on every page, present and future. The bus passes the document
# first, so the handler does not capture $doc from its surroundings.
set token [$doc on pageAdded [list apply {{doc index} {
    lassign [$doc page typeArea] x0 y0 x1 y1
    $doc font -family helvetica -size 8 -color {0.45 0.45 0.5}
    $doc text "page [expr {$index + 1}]" -at [list $x1 [expr {$y0 - 6}]] -align right -tag Artifact
    $doc font -family helvetica -size 10 -color black
}}]]
$doc page add                          ;# the handler draws on it
puts "subscribers of pageAdded: [llength [$doc subscribers pageAdded]]"
$doc off $token                        ;# by token, not by event and script

# Write-time events fire on EVERY write. A subscriber that creates objects must
# reserve its object number once and write over it on later runs.
namespace eval ::ref {}
proc ::ref::stamp {doc} {
    set number [$doc reservation ref::stamp]           ;# stable across writes
    $doc streamObject {Type /XXRefStamp} "stamp bytes" $number
    $doc catalogEntry XXRefStamp "$number 0 R"         ;# XX prefix: ISO 32000-2 Annex E
}
$doc on beforeWrite ::ref::stamp
$doc write [file join $out ref-01-document.pdf]
$doc destroy
```

Errors in a subscriber are **not** caught - a plugin that fails must fail audibly. Everything else about extending the package - `oo::define` on the document class, `state`, `resource`, `writer` - is in `doc/PLUGINS.md` of the source distribution.
