#!/usr/bin/env tclsh
#
# tclpdf example 5.4 - PDF/A on its own, without an invoice
#
#   tclsh examples/05.04-pdfa.tcl ?output.pdf?
#
# PDF/A was reachable only through [zugferd] in these examples, which made an
# archival document look like an invoice feature. It is not: a contract, a
# report, a certificate - anything that has to be readable in fifteen years
# without the machine that wrote it - is made the same way, and this is the
# whole recipe.
#
# What the declaration asks of the document, and what this file therefore does:
#
#   EVERY FONT EMBEDDED. A standard face is a reference to something the
#   reader is expected to have, which is precisely the assumption PDF/A
#   removes. [pdfa] refuses the document rather than writing one that says
#   PDF/A and is not - try it by dropping "-family face" from a text call.
#
#   COLOUR ANCHORED. An output intent names the colour space the numbers in
#   the file refer to, so that a grey printed today and one printed in 2041
#   mean the same thing. The sRGB profile in icc/ is used here.
#
#   THE METADATA IN XMP. Title, author and the conformance level go into the
#   XMP packet, not only into the document information dictionary - which is
#   the part a reader is allowed to ignore.
#
# Part 3 level U is what this writes: part 1 forbids the transparency tclpdf
# writes without ceremony, part 4 needs PDF 2.0. Level B promises the document
# looks the same in fifteen years; level U adds that its TEXT can still be
# extracted and searched, which rests on the ToUnicode map every embedded face
# carries here anyway - the stronger claim costs nothing, so there is no reason
# to declare the weaker one. Level A would need a tagged structure tree and is
# refused rather than written and rejected at the recipient.
#
# Check with:  verapdf -f 3u out.pdf
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

set target [expr {[llength $argv] ? [lindex $argv 0] : "05.04-pdfa.pdf"}]
set assets [file join $here assets]
set regular [file join $assets fonts DejaVuSans.ttf]
set bold [file join $assets fonts DejaVuSans-Bold.ttf]
set profile [file join [file dirname $here] icc sRGB.icc]

set doc [tclpdf new -unit mm]

# The document information dictionary. It is written as well - a reader that
# shows the title in its window title bar reads it here - but for PDF/A it is
# the XMP packet that counts, and [pdfa] keeps the two in agreement.
# The umlaut is not decoration: the title lands in the XMP packet, whose
# stream declares UTF-8, and a character above ASCII is what proves the
# packet was encoded rather than pasted.
$doc info Title "Calibration certificate 2026-114 – Prüflabor Bochum"
$doc info Author "Alexander Schoepe"
$doc info Subject "Thickness gauge, annual calibration"
$doc info Keywords "calibration, ISO 2360, archival"
# Creator is the application that made the document, Producer the library
# that wrote the file. The second is filled in by the package and can be read
# back; the first is ours to say.
$doc info Creator "Calibration laboratory certificate writer"
puts "  produced by: [$doc info Producer]"

# The language belongs to an archival document as much as the fonts do: it is
# what tells a reader how to pronounce the text and how to hyphenate it.
$doc language en-GB

$doc page add

$doc font embed face $regular
$doc font embed faceBold $bold

# -- the certificate --------------------------------------------------------

$doc rect -at {20 20} -size {170 18} -fill {0.20 0.30 0.45}
$doc font -family faceBold -size 14 -color white
$doc text "Calibration certificate" -at {26 32}
$doc font -family face -size 9 -color white
$doc text "No. 2026-114" -at {184 32} -align right

$doc font -family face -size 10 -color black
set y [$doc text "This certificate records the annual calibration of the\
    thickness gauge below. It is written as PDF/A-3U so that it can be read,\
    read the same way, and searched for as long as it has to be kept - which\
    for a calibration record is the lifetime of the instrument plus five\
    years." \
    -at {20 48} -width 170 -align justify -anchor top]

$doc table -at [list 20 [expr {$y + 8}]] -width 170 -theme grid \
    -style {family face} -headStyle {family faceBold} \
    -head {{Property Value}} \
    -body {
        {"Instrument" "Eddy current gauge, type N"}
        {"Serial number" "N-4471"}
        {"Calibrated on" "30 July 2026"}
        {"Reference standard" "Foil set, ISO 2360, traceable"}
        {"Deviation found" "0.4 um"}
        {"Next calibration due" "30 July 2027"}
    } \
    -columns {{width 60} {}}

# A picture and a bit of transparency, both of which are allowed here and are
# the reason part 1 is not: level B keeps them, part 1 would have to refuse.
$doc save
$doc opacity 0.12
$doc circle -at {160 150} -radius 22 -fill {0.20 0.30 0.45}
$doc restore

$doc font -family faceBold -size 10
$doc text "Signed" -at {20 160}
$doc font -family face -size 9
$doc text "Calibration laboratory, Bochum" -at {20 167}
$doc line -from {20 178} -to {90 178} -stroke {0.4 0.4 0.4} -width 0.3

# -- the declaration --------------------------------------------------------

# One call: it writes the output intent with the profile, raises the file
# version to match and produces the XMP packet. Everything it needs about the
# document - which fonts were used, which title was set - it reads back out of
# the document itself rather than being told twice.
#
# Level B is the default and is said explicitly here, as the least a PDF/A
# document claims. -identifier names the output condition in the intent; left
# out it is read from the profile's desc tag, and for the shipped profile it
# is the customary registry name given here anyway - so the line shows where
# the name comes from without changing the file.
$doc pdfa -part 3 -conformance B -profile $profile -identifier "sRGB IEC61966-2.1"

# A claim can be raised afterwards: the second call keeps part, profile and
# identifier and changes only the level - the way an invoice goes from the 3B
# that [zugferd] fixes to 3U. It is U from here on, so the check below is 3u.
$doc pdfa -conformance U

# A property of our own in the XMP packet. PDF/A admits metadata only from
# schemas the packet itself describes (ISO 19005-2, 6.6.2.3.1), so the schema
# comes first - name, namespace, prefix and every property with type,
# category and description - and the value after it. [pdfa extension] takes
# each block as it is; ZUGFeRD announces its four fx: properties the same way.
$doc pdfa extension {<rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
  <pdfaExtension:schemas>
    <rdf:Bag>
      <rdf:li rdf:parseType="Resource">
        <pdfaSchema:schema>Calibration certificate schema</pdfaSchema:schema>
        <pdfaSchema:namespaceURI>urn:example:calibration:1.0#</pdfaSchema:namespaceURI>
        <pdfaSchema:prefix>cal</pdfaSchema:prefix>
        <pdfaSchema:property>
          <rdf:Seq>
            <rdf:li rdf:parseType="Resource">
              <pdfaProperty:name>Laboratory</pdfaProperty:name>
              <pdfaProperty:valueType>Text</pdfaProperty:valueType>
              <pdfaProperty:category>external</pdfaProperty:category>
              <pdfaProperty:description>The laboratory that issued the certificate</pdfaProperty:description>
            </rdf:li>
          </rdf:Seq>
        </pdfaSchema:property>
      </rdf:li>
    </rdf:Bag>
  </pdfaExtension:schemas>
</rdf:Description>}
$doc pdfa extension {<rdf:Description rdf:about="" xmlns:cal="urn:example:calibration:1.0#">
  <cal:Laboratory>Calibration laboratory, Bochum</cal:Laboratory>
</rdf:Description>}

# What was declared, read back rather than repeated from above: the level,
# the profile, the identifier, how many extension blocks were added, and
# whether the claim is registered with the writer - which it is from the
# first [pdfa] call on.
set state [$doc pdfa state]
puts "  PDF/A-[dict get $state part][dict get $state conformance],\
    intent from [file tail [dict get $state profile]]\
    as \"[dict get $state identifier]\""
puts "  extension blocks: [llength [dict get $state extensions]],\
    registered: [dict get $state registered]"

exampleFooter $doc face

# [metadata] answers the XMP packet as the writer built it - empty before the
# first write, and rebuilt on every write from the document's current title,
# language and declarations. A caller may also SET a packet with it; then it
# is kept as given, which PDF/A profiles with prescribed wording rely on.
puts "  metadata before the write: [expr {[$doc metadata] eq {} ? {none yet} : {present}}]"
$doc write $target
puts "  metadata after the write: [string length [$doc metadata]] bytes, xpacket wrapper included"
$doc destroy

# The XMP packet is built during [write], not before it - so this is where it
# can be looked at. Reading it back out of the finished file is also the only
# check that does not simply believe the writer.
set channel [open $target rb]
set bytes [read $channel]
close $channel
regexp {<x:xmpmeta.*?</x:xmpmeta>} $bytes packet
# The element may carry its namespace declaration, so the pattern cannot
# demand that the tag name is followed straight by the closing bracket.
puts "  XMP packet: [string length $packet] bytes,\
    conformance [expr {[regexp {pdfaid:conformance[^>]*>(\w)<} $bytes -> level] ?
        $level : {not found}}]"

puts "  written: $target ([file size $target] bytes)"
puts "  check it with: verapdf -f 3u $target"
