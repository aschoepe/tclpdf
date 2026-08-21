# Images, SVG, barcodes

## Images: embed once, place often

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add

# JPEG passes through as DCTDecode, PNG without alpha as FlateDecode; only a
# PNG with an alpha channel is decoded (pure Tcl, ~100x the cost of pass-through).
$doc image embed photo $jpeg
$doc image embed logo  $png

# -width OR -height keeps the aspect ratio; -size sets both; -scale multiplies
# the natural size; -dpi decides the natural size (72 = one pixel one point).
$doc image place photo -at {20 20} -width 60
$doc image place photo -at {90 20} -height 30 -rotate 5 -opacity 0.6
$doc image place logo  -at {150 20} -dpi 300
$doc image place logo  -at {150 50} -scale 0.5

# What a placement would come out at, before placing it - for laying out around it.
puts "photo at 60 mm wide: [$doc image size photo -width 60] mm"
puts [$doc image info photo]      ;# type path bytes width height bitDepth icc components alpha ...
puts "aliases: [$doc image names]"

# Embed and place in one call, for a picture used once. The same image placed
# five times is stored once - by path, or by the bytes with -data.
$doc image draw $png -at {20 70} -width 25 -alt "The company mark"

# -data: bytes that never were a file (a canvas posted from a browser, a plot
# from a subprocess). The format is decided by the leading bytes.
set channel [open $jpeg rb]
set bytes [read $channel]
close $channel
$doc image embed fromBytes -data $bytes
$doc image place fromBytes -at {50 70} -width 25
```

An ICC profile inside the file (JPEG APP2, PNG iCCP) becomes the picture's `/ICCBased` space, shared with `icc embed` and the output intent - `-icc 0` embeds the picture without it. A progressive JPEG and an interlaced PNG are refused with the reason - re-save. `-alt`/`-artifact` matter in tagged documents (see `09-tagged-ua.md`); in an untagged one they change nothing.

## A picture as a stencil, and a picture as a mask

```tcl
# Scaffolding, not tclpdf: a minimal PNG writer, so this page needs no asset
# of its own. A stencil has to be ONE BIT per sample, and a soft mask has to
# be greyscale without alpha and without an ICC profile - two files most
# picture collections do not happen to carry.
proc refPngChunk {type data} {
    return [binary format I [string length $data]]$type$data[binary format I [zlib crc32 $type$data]]
}
proc refPng {path depth colour width height rows} {
    set png "\x89PNG\r\n\x1a\n"
    append png [refPngChunk IHDR [binary format IIccccc $width $height $depth $colour 0 0 0]]
    append png [refPngChunk IDAT [zlib compress [join $rows ""] 9]]
    append png [refPngChunk IEND ""]
    set channel [open $path wb]
    puts -nonewline $channel $png
    close $channel
}

# A ring, 32 x 32, one bit per sample: 0 is black and is the ink.
set rows {}
for {set y 0} {$y < 32} {incr y} {
    set bits ""
    for {set x 0} {$x < 32} {incr x} {
        set d [expr {hypot($x - 15.5, $y - 15.5)}]
        append bits [expr {($d < 15 && $d > 9) ? 0 : 1}]
    }
    lappend rows \x00[binary format B32 $bits]
}
refPng [file join $out ref-05-ring.png] 1 0 32 32 $rows

# A vignette, 64 x 64, eight bits per sample, greyscale: white in the middle,
# black at the edge - coverage, not colour.
set rows {}
for {set y 0} {$y < 64} {incr y} {
    set line ""
    for {set x 0} {$x < 64} {incr x} {
        set d [expr {hypot($x - 31.5, $y - 31.5) / 31.5}]
        append line [binary format c [expr {int(255 * (1.0 - min(1.0, $d)))}]]
    }
    lappend rows \x00$line
}
refPng [file join $out ref-05-vignette.png] 8 0 64 64 $rows

# -stencil 1: the picture has no colour of its own (ImageMask true, and then
# Table 87 forbids it a ColorSpace at all). Every placement paints the FILL
# COLOUR then in force through the bits of the file - one embedding, one
# object, any number of placements in any number of colours.
$doc image embed ring [file join $out ref-05-ring.png] -stencil 1
$doc image embed hole [file join $out ref-05-ring.png] -stencil 1 -invert 1   ;# the other bit is the ink
$doc style -fill crimson
$doc image place ring -at {20 205} -size {20 20}
$doc style -fill {0.15 0.30 0.55}
$doc image place ring -at {45 205} -size {20 20}
$doc image place hole -at {70 205} -size {20 20}
$doc style -fill black

# -mask names a SECOND embedded picture as this one's mask. What it becomes
# depends on what that picture is: a -stencil is all-or-nothing and becomes
# /Mask (the base shows or it does not), anything else is coverage and becomes
# /SMask (the base FADES). The mask is embedded first, gets an object of its
# own and no page resource, and two pictures may share one.
$doc image embed fade [file join $out ref-05-vignette.png]
$doc image embed faded $jpeg -mask fade -interpolate 1     ;# -interpolate: a hint, nothing more
$doc image place photo -at {100 205} -width 40
$doc image place faded -at {145 205} -width 40
puts [$doc image info ring]        ;# ... stencil 1 mask {} interpolate 0 bitDepth 1 ...
```

The two need not be the same size - every image is defined on the unit square, so their edges coincide on the page. Refused, each naming the reason: a JPEG as a stencil (`DCTDecode` always delivers 8 bits), a PNG that is not one bit per sample and one sample per pixel, a mask that is not greyscale or that carries an ICC profile (`-icc 0` is the way out) or transparency of its own, a picture that already brings its own alpha channel asked to wear a second mask, and a stencil asked to wear one at all. Under `pdfa` a stencil passes under **every** output intent: it brings no colour space to be judged - what is judged is the fill colour it lets through.

## SVG: real vectors, not a picture

```tcl
# Paths, shapes, groups, transforms, use, text and gradients become PDF operators.
# Returns {x y width height} of what was drawn.
set box [$doc svg $svgFile -at {20 110} -width 50 -alt "A sample drawing"]
puts "drawn: $box"
puts "natural size: [$doc svg size $svgFile]"
puts "skipped elements of the LAST drawing: [$doc svg info]"

# -data: markup from a variable - what a generator wants, no temporary file.
set colour "#2f6fb0"
set markup "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">\
    <circle cx=\"20\" cy=\"20\" r=\"18\" fill=\"$colour\"/>\
    <text x=\"20\" y=\"25\" font-family=\"house, helvetica\" font-size=\"12\"\
        text-anchor=\"middle\" fill=\"white\">OK</text></svg>"
$doc font embed house $ttfBold          ;# font-family="house" in the markup resolves to it
$doc svg -data $markup -at {80 110} -width 20 -alt "Status: OK"
$doc svg -data $markup -at {105 110} -size {30 15} -artifact 1     ;# decoration, said so
```

Text in a drawing uses the same faces as `text`: `font-family` is a wish list, the first name that resolves wins, an embedded alias resolves; a list nobody satisfies ends at `helvetica`, which a PDF/A document then refuses at the write - name a face the document has. `font-weight`/`font-style` are not read. `svg size` takes a file name only; for markup, the size is what drawing returns.

## Barcodes through tzint (optional, a C extension)

```tcl
# tclpdf has no encoder and needs none: tzint encodes into SVG, svg -data draws it.
if {![catch {package require tzint 1.3-}]} {
    # THE STATUS IS THREE-VALUED: 0 silence, 1..4 warning WITH a good symbol,
    # 5 and up nothing produced - and then the target variable is left AS IT WAS.
    proc encode {varName data args} {
        upvar 1 $varName markup
        set rc [::tzint::Encode svg markup $data {*}$args -stat info]
        if {$rc >= 5} { error "barcode not produced: [dict get $info error]" }
        if {$rc != 0} { puts "  note: [dict get $info error]" }
        return $rc
    }
    encode markup "tclpdf 1.1" -barcode code128
    $doc svg -data $markup -at {20 150} -height 16 -alt "Code 128: tclpdf 1.1"

    encode markup "https://example.org/" -barcode qrcode
    $doc svg -data $markup -at {90 150} -height 20 -alt "QR: https://example.org/"

    # EPC-QR / GiroCode: -eci 26 forces UTF-8 as line 3 of the dataset claims,
    # -security 2 is the level the specification asks for.
    set epc "BCD\n002\n1\nSCT\nBANKDEFFXXX\nMuster GmbH\nDE89370400440532013000\nEUR12.34\n\n\nRechnung 4711"
    encode markup $epc -barcode qrcode -security 2 -eci 26
    $doc svg -data $markup -at {120 150} -height 25 -alt "GiroCode: 12,34 EUR to Muster GmbH"

    # The clear text line under an EAN: tzint asks for font-family="OCRB, monospace" -
    # embed a face under the alias OCRB and the digits are real OCR-B, as text.
    # -smalltext 1 with -height 24 gives about 8 pt; or -notext 1 and set it yourself.
    # $doc font embed OCRB /path/to/OCRB.ttf
    encode markup "123456789012" -barcode ean13 -smalltext 1
    $doc svg -data $markup -at {20 180} -height 24 -alt "EAN-13 1234567890128"
}
```

A Euro sign is a warning (rc 3) for `qrcode` and an error (rc 6) for `code128`. Test the status, never the variable.

```tcl
$doc write [file join $out ref-05-images-svg.pdf]
$doc destroy
```
