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
