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

```tcl
$doc write [file join $out ref-08-navigation-metadata.pdf]
# The packet is built during the write - this is where it can be looked at.
puts "XMP packet: [string length [$doc metadata]] bytes, xpacket wrapper included"
$doc destroy
```
