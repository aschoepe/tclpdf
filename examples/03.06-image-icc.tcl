#!/usr/bin/env tclsh
#
# tclpdf example 3.6 - the colour profile a picture brings with it
#
#   tclsh examples/03.06-image-icc.tcl ?output.pdf?
#
# A JPEG may carry an ICC profile in an APP2 segment, a PNG in an iCCP chunk.
# [image embed] keeps it: the picture's colour space becomes /ICCBased instead
# of the bare /DeviceRGB, and -icc 0 leaves the profile behind. The two are the
# same pixels and look alike on any screen - which is the whole difficulty with
# this topic, and the reason for an example rather than a sentence.
#
# WHY IT MATTERS is one step further on, under PDF/A. A picture anchored to its
# own profile carries its meaning with it and is admitted whatever the
# document's output intent says; a /DeviceRGB picture is a device colour and is
# judged against that intent - ISO 19005-2, 6.2.4.3 admits DeviceRGB only under
# an RGB intent. So the script does not claim it. It builds the same PDF/A page
# twice under a GREY output intent, once with the profile and once without, and
# puts the refusal it gets for the second on the page, word for word. The one
# that keeps its profile is written beside the main document as
# <name>-pdfa.pdf, PDF/A-3B, and veraPDF says so.
#
# The other half of the topic is the same profile mechanism for DRAWING colour:
# [icc embed] registers a profile under an alias and {icc alias components} is
# then a colour anywhere one is taken. A profile stands in the document once
# however many roads it arrives by - as a picture's, as a registered space, or
# as the output intent - which is why the second document registers its own
# grey output intent as an alias and paints a rule with it.
#
# The picture is the passport photograph of the German identity card specimen
# of the Personalausweisverordnung, an official work and in the public domain
# under section 5 paragraph 1 of the German copyright act; the details are in
# examples/assets/README.md. It is the only file in the tree with a profile in
# it - 3 144 bytes of sRGB, beside Exif, XMP and a Photoshop segment.
#
# WHO ERIKA MUSTERMANN IS, since the name means nothing outside Germany: she
# is the German Jane Doe. "Mustermann" is "sample man", and the name has stood
# on the specimen documents of the Bundesdruckerei since it first appeared in
# the Bundesgesetzblatt in March 1983 - every German identity card, passport
# and driving licence shown as a sample carries it, the way an English form
# shows John Doe. Her particulars move from specimen to specimen and are not
# worth quoting from memory; the card this photograph comes from gives 12
# August 1964 in Berlin, valid to 31 October 2020, number T22000129.
#
# THE SOURCES PART COMPANY ON ONE POINT and it is worth naming rather than
# smoothing over: the German Wikipedia article says the photographs on these
# specimens are of real Bundesdruckerei employees, while Wikimedia Commons
# calls the person depicted fictitious. Nothing follows from that for the
# licence - an official work stays one, and the file is published for reuse -
# but it is why this package puts the photograph and the signature in a
# signature field and an invoice and does not reproduce a whole identity card.
#
# Check with:  qpdf --qdf --object-streams=disable out.pdf - | grep -n ICCBased
#              verapdf -f 3b out-pdfa.pdf
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set here [file dirname [file normalize [info script]]]
lappend auto_path [file dirname $here]
package require tclpdf

source [file join $here common.tcl]

set target [expr {[llength $argv] ? [lindex $argv 0] : "03.06-image-icc.pdf"}]
set archival [file rootname $target]-pdfa.pdf
set assets [file join $here assets]
set portrait [file join $assets images erika-mustermann.jpg]
set regular [file join $assets fonts DejaVuSans.ttf]
set srgb [file join [file dirname $here] icc sRGB.icc]
set grey [file join [file dirname $here] icc ISOcoated_v2_grey1c_bas.ICC]

# -- what PDF/A makes of the picture without its profile --------------------
#
# Measured before anything is drawn, because the page below quotes the answer.
# The document is thrown away; only the message it refused with is kept.
proc iccRefusal {portrait profile} {
    set channel [file tempfile path]
    close $channel
    set doc [tclpdf new -unit mm]
    $doc pdfa -part 3 -conformance B -profile $profile
    $doc page add
    $doc image embed portrait $portrait -icc 0
    $doc image place portrait -at {20 20} -width 40
    if {[catch {$doc write $path} message]} {
        set answer $message
    } else {
        set answer "not refused - the check did not fire"
    }
    $doc destroy
    file delete $path
    return $answer
}

set refusal [iccRefusal $portrait $grey]

# -- the two pictures -------------------------------------------------------

set doc [tclpdf new -unit mm]
$doc info Title "tclpdf example: the colour profile a picture brings with it"
$doc page add

$doc font -family helvetica -style bold -size 14
$doc text "The colour profile a picture brings with it" -at {20 20}

$doc font -style {} -size 9
$doc text "The same JPEG, embedded twice. The left one keeps the ICC profile\
    out of its APP2 segment and reaches the file as /ICCBased; -icc 0 leaves\
    the profile behind and the right one is /DeviceRGB. Same 420 x 540 pixels,\
    same bytes of image data - the difference is in the file, not in the\
    picture." -at {20 28} -width 170

# Kept and dropped. Both are the same file on disk, so [image embed] is given
# two aliases rather than one: the profile decision belongs to the embedding,
# not to the placement.
$doc image embed kept $portrait
$doc image embed dropped $portrait -icc 0
$doc image place kept -at {20 46} -width 62
$doc image place dropped -at {90 46} -width 62

$doc font -style bold -size 8
$doc text "profile kept: /ICCBased" -at {20 131}
$doc text "-icc 0: /DeviceRGB" -at {90 131}

# Who is in the picture, said ON THE PAGE and not only in the source above: a
# reader outside Germany meets a face and a name and has no way of telling
# whether this is somebody's passport photograph or a sample. Beside the
# pictures rather than under them - the table below starts at 137 mm, and a
# block set there ran underneath it. Seen at 90 dpi.
$doc font -style {} -size 7 -color {0.35 0.35 0.4}
$doc text "Erika Mustermann is the German Jane Doe: the placeholder name on\
    the specimen documents of the Bundesdruckerei since it first appeared in\
    the Bundesgesetzblatt in March 1983. Every German identity card, passport\
    and driving licence shown as a sample carries it.\n\nThis is the passport\
    photograph of the identity card specimen of the\
    Personalausweisverordnung - an official work, in the public domain under\
    section 5 paragraph 1 of the German copyright act, and published for\
    reuse." -at {157 46} -width 33
$doc font -color {0 0 0}

# What the document says about the two, read back out of it rather than
# repeated from the calls above - the one number that differs is [icc].
set rows {}
foreach key {type width height components bitDepth icc} {
    lappend rows [list $key [dict get [$doc image info kept] $key] \
        [dict get [$doc image info dropped] $key]]
}
lappend rows [list {colour space} /ICCBased /DeviceRGB]
$doc font -style {} -size 9
set y [$doc table -at {20 137} -width 170 -theme striped \
    -head {{"image info" "profile kept" "-icc 0"}} -body $rows \
    -columns {{width 60} {} {}}]

# -- the same mechanism as a drawing colour ---------------------------------

# A profile does not need a picture to enter the document. [icc embed] puts one
# under an alias and {icc alias components} paints in it - anchored to the
# profile, exactly as the picture on the left is.
$doc icc embed srgb $srgb
set facts [exampleIccFacts $srgb]

$doc font -style bold -size 10
$doc text "The same profile as a drawing colour" -at [list 20 [expr {$y + 8}]]
set x 20
foreach colour {{0.85 0.2 0.15} {0.2 0.45 0.75} {0.95 0.75 0.1}} {
    $doc rect -at [list $x [expr {$y + 13}]] -size {24 12} \
        -fill [list icc srgb {*}$colour] -radius 1.5
    incr x 27
}
$doc font -style {} -size 8
$doc text "{icc srgb 0.2 0.45 0.75} - [dict get $facts desc],\
    [dict get $facts version], [dict get $facts size] bytes on disk and\
    [dict get $facts flate] as the stream in the file" \
    -at [list 105 [expr {$y + 15}]] -width 85

# -- what PDF/A says --------------------------------------------------------

$doc font -style bold -size 10
$doc text "Under PDF/A, the difference decides" -at [list 20 [expr {$y + 34}]]
$doc font -family courier -style {} -size 7.5 -color {0.70 0.15 0.15}
set y [$doc text $refusal -at [list 20 [expr {$y + 40}]] -width 170]
$doc font -family helvetica -size 9 -color {0 0 0}
set y [$doc text "That is the picture on the right, under a grey output\
    intent. The one on the left goes into the very same document without a\
    word: it is anchored to its own profile, not to the device. It is written\
    beside this file as [file tail $archival]." \
    -at [list 20 [expr {$y + 4}]] -width 170]

$doc font -family courier -size 8 -color {0.25 0.25 0.3}
foreach command [list \
    "qpdf --qdf --object-streams=disable [file tail $target] - | grep -n ICCBased" \
    "verapdf -f 3b [file tail $archival]"] {
    set y [expr {$y + 5}]
    $doc text $command -at [list 20 $y]
}

exampleFooter $doc
$doc write $target
puts "  written: $target ([file size $target] bytes)"
puts "  kept: icc [dict get [$doc image info kept] icc] bytes,\
    dropped: icc [dict get [$doc image info dropped] icc] bytes"
$doc destroy

# -- the archivable twin ----------------------------------------------------
#
# The proof rather than the assertion: a colour picture in a document whose
# output intent is GREY. It passes because it brings its own profile - and the
# intent profile is registered as an alias besides, so its 936 bytes serve as
# the intent and as the colour of the rule below at once. One profile, one
# stream - measured: /DestOutputProfile and the ICCBased colour space of the
# rule name the same object.

set doc [tclpdf new -unit mm]
$doc pdfa -part 3 -conformance B -profile $grey
$doc icc embed press $grey
$doc info Title "A picture under an output intent of another colour space"
$doc font embed body $regular
$doc page add

$doc font -family body -size 12 -color {icc press 0.1}
$doc text "A colour picture under a grey output intent" -at {20 20}
$doc font -size 9 -color {gray 0.15}
$doc text "PDF/A-3B, output intent [file tail $grey]. The picture below is RGB\
    and is admitted all the same, because it brings the profile that says what\
    its numbers mean. Embedded with -icc 0 instead it would be DeviceRGB, and\
    the write would be refused. The rule is painted in {icc press 0.35} - the\
    output intent profile registered as a colour space besides, so the same\
    [file size $grey] bytes stand in the file once and serve both."\
    -at {20 28} -width 170
$doc rect -at {20 54} -size {170 1.5} -fill {icc press 0.35}

$doc image embed portrait $portrait
$doc image place portrait -at {20 62} -width 65
$doc font -size 8
$doc text "/ICCBased with /N 3: the [dict get [$doc image info portrait] icc]\
    bytes of sRGB the JPEG carried in its APP2 segment" -at {20 152} -width 65
# Who is in the picture, on the page and not only in the source: a reader who
# meets the name for the first time should not have to guess whether this is
# somebody's passport photograph.
$doc font -size 7
$doc text "Erika Mustermann is the German Jane Doe - the placeholder name on\
    every German specimen document since 1983. This is the passport\
    photograph of the identity card specimen of the\
    Personalausweisverordnung, an official work in the public domain."\
    -at {20 162} -width 65
$doc font -size 9
$doc text "Nothing on this page is a device colour. The text is grey, which\
    ISO 19005-2 admits under any intent; the rule is the intent's own profile;\
    and the picture is anchored to the profile it brought with it. That is\
    what makes a grey intent enough for a page with a colour photograph on\
    it." -at {95 62} -width 95

exampleDone $doc $archival body {gray 0.45}
