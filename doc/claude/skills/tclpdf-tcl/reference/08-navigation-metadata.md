# Attachments, links, bookmarks, destinations, metadata, viewer preferences, page labels

## Attachments

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc info Title "Reference: navigation and metadata"
$doc page add
$doc font -family helvetica -size 10
$doc text "Attachments, links, bookmarks, metadata" -at {20 20}

# A file, or bytes that never were one (-data needs -name). -data must be BYTES:
# encode text first. -relationship is /AFRelationship: Alternative, Data, Source,
# Supplement or Unspecified. -date is a PDF date. -compress is on by default.
$doc attach -data [encoding convertto utf-8 "reading;value\n1;12.4\n2;12.6\n"] \
    -name readings.csv -mime text/csv -relationship Data \
    -description "The individual readings" -date "D:20260818120000+02'00'"
$doc attach -data [encoding convertto utf-8 "Method: ISO 2360\n"] -name procedure.txt \
    -mime text/plain -relationship Supplement -description "Method and conditions" -compress 0
$doc attach $svgFile -name drawing.svg -mime image/svg+xml -relationship Source \
    -description "The drawing this page was made from"
puts "attached: [llength [$doc attachments]] files"
```

`-mime` takes only `type/subtype`; `-name` may not contain `/` or `\`. Under `pdfa -part 2` attachments are refused - part 3 admits them (see `10-pdfa-zugferd.md`).

## Links

```tcl
# A link is an invisible rectangle - the visible text is a separate call.
$doc font -color {0.1 0.2 0.6}
$doc text "The workshop notes (external)" -at {20 40}
$doc link -at {20 36} -size {60 6} -url "https://www.example.org/workshop?q=Ärger" \
    -tooltip "Opens the workshop notes in a browser"     ;# non-ASCII in the URL becomes %XX

# -page counts from 0 as page current does - not the printed number. The page
# need not exist yet: it is resolved at the write, and a page that never came
# is reported then, naming the link.
$doc text "Go to the second page, top left" -at {20 48}
$doc link -at {20 44} -size {60 6} -page 1 -to {20 20} -zoom 1 -tooltip "Go to page 2"
$doc text "Fit the third page" -at {20 56}
$doc link -at {20 52} -size {60 6} -page 2 -tooltip "Go to page 3"     ;# no -to: the page is fitted
$doc font -color black
```

`-tooltip` becomes the annotation's `Contents`, which PDF/UA requires on every link; under PDF/UA the annotation also has to sit inside a `structure Link` (`09-tagged-ua.md`). `-structure name` points at a named structure element instead of a place (needs a tagged 2.0 document).

## Bookmarks

```tcl
# Returns an id that can be the -parent of further entries. -page defaults to
# the current page and may lie ahead; -at lands on a point; -open 0 collapses.
set chapter [$doc bookmark "Chapter 1" -page 0]
$doc bookmark "Section 1.1" -page 0 -at {20 40} -parent $chapter
$doc bookmark "Section 1.2" -page 1 -at {20 20} -parent $chapter -open 0
$doc bookmark "Chapter 2" -page 2
puts "outline entries: [llength [$doc bookmarks]]"
```

A document with bookmarks opens with the outline pane (`/PageMode /UseOutlines`) unless `catalogEntry PageMode` was set already.

## Destinations, and the catalog

```tcl
# The destination in PDF syntax - what link and bookmark build theirs through.
# The standing use: open the document on a page of your choosing. Page 1 does
# not exist yet here: the answer is then a reference filled at the write.
$doc catalogEntry OpenAction [$doc destination 1 -to {20 20} -zoom 1]
puts "OpenAction: [$doc catalogEntry OpenAction]"
# catalogEntry is for anything the package does not offer by name; a private key
# carries the XX prefix of ISO 32000-2 Annex E.
```

## The information dictionary and the language

```tcl
$doc info Author "Workshop documentation"
$doc info Subject "How the reference code is used"
$doc info Keywords "tclpdf, reference"
$doc info Creator "my-application 2.3"            ;# the application; Producer stays tclpdf unless replaced
$doc info CreationDate "D:20260818120000+02'00'"  ;# PDF date, refused otherwise
$doc info ModDate "D:20260818120000+02'00'"
puts "title: [$doc info Title]"
$doc language de-DE                               ;# RFC 3066; PDF/A-3a and PDF/UA require it
```

Every text key is mirrored into the XMP packet under its Table 317 property (`dc:title`, `dc:creator`, `pdf:Keywords`, `xmp:CreatorTool`, `pdf:Producer`); the two dates as `xmp:CreateDate`/`xmp:ModifyDate`. `Trapped` (`True False Unknown`) is not mirrored.

## The XMP packet: schema, raw XML, or the whole packet

```tcl
# Everything here needs tdom (the packet is built with it).
package require tclpdf::xmp

# A schema of your own: prefix, namespace, the properties it MAY write, and a
# method of the document that answers them - a method, because the values may
# change before the write. Answered but not listed = the write fails.
oo::define ::tclpdf::document::document {
    method refXmp {} {
        list [list text Laboratory "Calibration laboratory, Bochum"] \
             [list text Certificate "K-2026-114"] \
             [list bag Instruments {{Name "Probe N" Serial 4711} {Name "Probe S" Serial 4712}}]
    }
}
# A bag is a list of resources, each a flat tag-value list; those tags are declared too.
$doc xmpSchema cal urn:example:calibration:1.0# {Laboratory Certificate Instruments Name Serial} refXmp

# Ready-made rdf:Description elements - the rdf prefix is declared, every other
# namespace the fragment declares itself. Parsed at the write; malformed = fails there.
$doc xmpRaw {<rdf:Description rdf:about="" xmlns:ref="urn:example:ref:1.0#">
  <ref:Note>Appended as given</ref:Note>
</rdf:Description>}

# Or take the packet over completely: [metadata xml] keeps it AS GIVEN from then on -
# no rebuild from title, language and claims. Read it back after a write:
# puts [$doc metadata]
```

The packet is built once a schema is registered or a raw contribution is added; a document that claims nothing and adds nothing carries no packet.

## Viewer preferences

```tcl
# Calls accumulate: each sets the keys it names. Values are checked at the call,
# because a reader that meets a misspelled one falls back silently.
$doc viewerPreferences -fitWindow 1 -centerWindow 1 -displayDocTitle 1
$doc viewerPreferences -nonFullScreenPageMode UseOutlines -direction L2R
$doc viewerPreferences -printScaling None -duplex DuplexFlipLongEdge -pickTrayByPDFSize 1 -numCopies 2
puts "viewer preferences: [$doc viewerPreferences]"
```

Booleans: `-hideToolbar -hideMenubar -hideWindowUI -fitWindow -centerWindow -displayDocTitle -pickTrayByPDFSize`; names: `-nonFullScreenPageMode` (`UseNone UseOutlines UseThumbs UseOC`), `-direction` (`L2R R2L`), `-printScaling` (`None AppDefault`), `-duplex` (`Simplex DuplexFlipShortEdge DuplexFlipLongEdge`); `-numCopies` 2..5. `ua` sets `-displayDocTitle 1` and refuses to have it taken back.

## Page labels

```tcl
$doc page add
$doc page add
# One call is one range from -from (index, from 0) to the next range. The tree
# has to begin at 0 - a range without a style is put in front where it does not.
$doc pageLabels -from 0 -style R -prefix ""            ;# I, II ...
$doc pageLabels -from 1 -style D -start 1               ;# 1, 2 ...
$doc pageLabels -from 2 -style none -prefix "Appendix"  ;# a name, no number
puts "labels: [$doc pageLabels]"
```

Styles: `D`, `R`, `r`, `A`, `a`, `none`. Labels and **printed** numbers have to agree (Matterhorn 15-001) and no validator can see it: a document that prints `pageNumbers -from 3` says `pageLabels -from 0 -start 3` as well.

## How the reader opens the document

```tcl
# Three catalogue entries in one call (Table 28): which panel a reader shows
# beside the page (/PageMode), how it arranges them (/PageLayout), and where
# it puts the reader first (/OpenAction). Calls accumulate, as
# viewerPreferences does, and without arguments it answers what is set.
$doc initialView -pageMode UseOutlines -pageLayout TwoColumnLeft
$doc initialView -page 0 -to {20 20} -zoom 1
puts "initial view: [$doc initialView]"

# -page, -to and -zoom are the three words destination and link use and go
# through the same code, so an open action and a bookmark pointing at the same
# place cannot disagree. -page counts from 0 and may name a page not added
# yet. Without -to the destination is /Fit, the whole page.
#
# A misspelt page mode is refused rather than written: a reader that meets one
# falls back on its default, and no validator reports it either.
if {[catch {$doc initialView -pageMode UseOutline} message]} {
    puts "refused, as it should be: $message"
}
```

A caller's `-pageMode` wins over the `/UseOutlines` a `bookmark` sets by itself. It is a command of its own rather than three more keys of `viewerPreferences`, because a viewer preference is a wish a reader may ignore while these are what it *does* when the file opens - and `viewerPreferences` answers the dictionary that goes into `/ViewerPreferences`, which the PDF/UA check reads. An **action** is not offered: `catalogEntry OpenAction` takes one, and ISO 19005 forbids most action types outright.

```tcl
$doc write [file join $out ref-08-navigation-metadata.pdf]
# The packet is built during the write - this is where it can be looked at.
puts "XMP packet: [string length [$doc metadata]] bytes, xpacket wrapper included"
$doc destroy
```

## A note, a stamp, and marking a passage

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add
$doc font -family helvetica -size 11

# WHO DRAWS THE PICTURE decides everything else. A note, and a stamp given
# -name, are drawn by the READER from a fixed set of symbols - which is what
# makes a note look like the reader's other notes, and which is why a document
# claiming PDF/A refuses one (Table 166 wants an appearance stream on every
# annotation). The way out is -appearance.
#
# -contents IS the note, and it is required. -icon is one of Comment, Key,
# Note (the default), Help, NewParagraph, Paragraph or Insert; -size defaults
# to the 20 by 20 points a reader draws its symbol in, and the symbol does not
# scale with the rectangle - the number decides only where it sits.
$doc annot note -at {180 30} -contents "Check this against the delivery note" \
    -icon Comment -title "E. Mustermann" -open 1 -colour {1 0.85 0.35} \
    -date [clock scan "2026-08-18 12:00" -format "%Y-%m-%d %H:%M"]

# A rubber stamp. -name is one of the fourteen a reader draws itself and
# -size is then REQUIRED, there being nothing to derive one from.
$doc annot stamp -at {150 40} -size {40 14} -name Draft -contents "not final"

# -appearance names a form built with [form create] and wins over /Name: with
# one present a reader never looks at the name, so the two are exclusive. The
# form's own size is used where -size is left out - the numbers are then not
# written in two places and cannot come to disagree.
set docGlobal $doc
$doc form create seal -size {36 14} -script {
    $docGlobal rect -at {0 0} -size {36 14} -radius 2 \
        -stroke {0.7 0.15 0.1} -width 0.6
    $docGlobal font -family helvetica -style bold -size 7 -color {0.7 0.15 0.1}
    $docGlobal text "RECEIVED" -at {18 9} -align center
}
$doc annot stamp -at {150 60} -appearance seal -contents "received 18 August"
$doc annot note -at {180 60} -appearance seal -contents "the same, under PDF/A"
$doc font -family helvetica -size 11 -color black
```

```tcl
# THE FOUR TEXT MARKUPS need none of that: the package draws their appearance
# itself, always and without being asked, because the marked rectangles and
# the colour are the whole picture. What such an annotation consists of is its
# /QuadPoints, and there are three ways to say where those are - one of them
# is required.

# 1. -text marks ONE line and repeats what the [text] call that drew it said:
#    the same string and the same point, plus -align and -anchor where those
#    were given. The width is textWidth's and the height the face's ascender
#    plus descender, so the band covers capitals and descenders and nothing
#    else.
$doc text "The amount due is 1.284,50 EUR." -at {20 100}
$doc annot highlight -text "The amount due is 1.284,50 EUR." -at {20 100} \
    -contents "the amount due" -title "E. Mustermann"

$doc text "recieve" -at {20 110}
$doc annot squiggly -text "recieve" -at {20 110} -contents "spelling"

$doc text "old price" -at {60 110}
$doc annot strikeout -text "old price" -at {60 110} -contents "superseded"

$doc text "Right aligned, and marked as such." -at {190 120} -align right
$doc annot underline -text "Right aligned, and marked as such." -at {190 120} \
    -align right -contents "the aligned line"

# 2. -lines marks a PARAGRAPH and takes what [textLines] answered for it - the
#    plain list, or the dictionaries of -hyphens 1; both are read. ONE
#    quadrilateral per line, one leading apart, and ONE annotation for the
#    whole passage, which is what /QuadPoints is an array for and what makes a
#    reader announce the remark once rather than once per line.
set passage "A passage of several lines, marked as one remark rather than as\
    one remark per line - which is what the array of quadrilaterals is for."
$doc text $passage -at {20 135} -width 100
$doc annot highlight -lines [$doc textLines $passage -width 100] -at {20 135} \
    -contents "the whole passage" -colour {0.75 0.90 1}

# The leading is the text state's own, which is what the block used;
# -leading overrides it for a block broken some other way.
$doc annot underline -lines [$doc textLines $passage -width 100] -at {20 160} \
    -leading 5 -contents "broken elsewhere, so the leading is given"

# 3. -quads takes the rectangles directly, {x y w h} counted from the TOP LEFT
#    as -at is everywhere else. It is the road for a passage this package did
#    not set, for a table cell whose geometry the caller already has, for a
#    JUSTIFIED block - whose lines were stretched after they were measured -
#    and for text in a Type 3 face, which carries no descender to measure
#    with. Each of those three refusals names this option.
$doc text "A justified block, whose lines were stretched after they were\
    measured, is marked by giving the rectangles." -at {20 180} -width 100 \
    -align justify
$doc annot strikeout -quads {{20 176 100 5} {20 181 100 5} {20 186 62 5}} \
    -contents "the justified block"

# One of the three is required, and asking for none is refused.
if {[catch {$doc annot highlight -contents "nothing marked"} message]} {
    puts "refused, as it should be: $message"
}
```

The colour is `/C` and defaults to yellow for `highlight` and red for the other three; the appearance is drawn in the same colour, the highlight under the `Multiply` blend mode so that the words show through the band rather than disappearing under it. Shared with the note and the stamp: `-contents` (the description), `-title` (the owner of the remark, `/T`), `-colour` (grey, RGB or CMYK - the three spellings `/C` has), `-opacity` (which fades the whole annotation, appearance and all), `-date` (a time as `clock seconds` answers - without it an annotation carries **no** date at all, so that the same script writes the same bytes twice), and `-appearance`. Under PDF/UA `-contents` is required on every annotation.

## Annotations that have a shape

```tcl
$doc font -family helvetica -size 10

# The difference from DRAWING the same shape is not the picture but what it
# is: a line drawn with [line] is content - it prints, and a reader can
# neither switch it off nor ask who put it there - while the same line as an
# annotation carries an author, a date and a description.
#
# -colour is the outline (/C, red by default), -fill the inside (/IC). A line
# and a polyline have no inside, so an -fill on them writes none.
$doc annot line -from {20 40} -to {90 40} -contents "the correction"
$doc annot square -at {20 55} -size {60 18} -contents "this block"
$doc annot circle -at {100 55} -size {60 18} -fill {1 1 0.75} -contents "agreed"
$doc annot polygon -points {{20 85} {70 78} {90 108}} -fill {0.9 0.95 1} \
    -contents "the area"
$doc annot polyline -points {{110 85} {135 78} {155 108}} -contents "the route"

# The appearance is drawn WITHOUT being asked for, unlike a note's: the
# picture follows entirely from the geometry, the colours and the width - so
# these pass PDF/A and PDF/UA where a note without -appearance does not.
# /Rect grows by half the line width, since a reader may clip to it.
```

```tcl
$doc info Title "Reference: annotations"
$doc write [file join $out ref-08-annotations.pdf]
$doc destroy
```

`circle` is the standard's word and means an **ellipse** inscribed in the rectangle. Square, circle and line are PDF 1.3; polygon and polyline are 1.5.

## A file clipped to the place it belongs

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add
set docGlobal $doc

# The file travels ONCE: [attach] embeds it, and the annotation points at it
# by the name that call gave it - not by a path.
$doc attach -data "Delivery note 2026-4711\n" -name lieferschein.txt \
    -mime text/plain -description "the delivery note for line 1"
$doc annot attachment -at {180 40} -name lieferschein.txt \
    -contents "the delivery note"

# Without -appearance the picture is the READER's icon (-icon Graph,
# Paperclip, PushPin or Tag), exactly as it is for [annot note] - so under a
# claim that requires an appearance it is refused. Draw one and name it:
$doc form create clip -size {14 16} -script {
    $docGlobal line -from {4 3} -to {4 12} -stroke {0.2 0.3 0.45} -width 1.1
}
$doc annot attachment -at {180 60} -name lieferschein.txt -appearance clip \
    -contents "the same, under PDF/A"
```

```tcl
$doc info Title "Reference: an attachment on the page"
$doc write [file join $out ref-08-attachment-annotation.pdf]
$doc destroy
```

A name nothing was attached under is refused (`TCLPDF ANNOT ATTACHMENT UNKNOWN`). With `-appearance` no `/Name` is written at all: `/AP` wins over it (Table 166), and a `/Name` nothing draws is a statement with no reader.
