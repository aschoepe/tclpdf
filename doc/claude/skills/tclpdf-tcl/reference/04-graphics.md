# Graphics: shapes, paths, clipping, state, transforms, colour

## The shapes

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc page add

$doc line -from {20 20} -to {80 20} -stroke black -width 0.5
$doc line -from {20 24} -to {80 24} -stroke gray -width 0.3 -dash {2 1} -cap round
$doc rect -at {20 30} -size {40 20} -fill {0.9 0.92 0.96} -stroke steelblue -width 0.4
$doc rect -at {65 30} -size {40 20} -radius 3 -fill steelblue -opacity 0.5    ;# rounded corners
$doc circle -at {130 40} -radius 10 -fill crimson -stroke black -width 0.3    ;# -at is the CENTRE
$doc ellipse -at {160 40} -size {30 16} -fill {cmyk 0 0.16 1 0}               ;# -at is the CENTRE
$doc arc -at {130 40} -radius 16 -start 30 -extent 120 -stroke crimson -width 1  ;# 0 is 3 o'clock, CCW
$doc arc -at {160 40} -size {30 16} -extent 240 -style pieslice -fill plum      ;# arc|pieslice|chord
$doc polygon -points {20 60 40 75 20 90} -fill navy                            ;# closed by default
$doc polygon -points {50 60 70 75 50 90} -stroke navy -close 0                 ;# open
$doc curve -from {90 90} -c1 {100 60} -c2 {120 60} -to {130 90} -stroke {0.2 0.5 0.3} -width 0.6
$doc path -segments {{move 150 60} {line 180 60} {curve 190 70 190 80 180 90} {line 150 90} {close}} \
    -fill {0.95 0.85 0.4} -stroke black -width 0.3
# A self-intersecting path: -rule evenodd leaves the hole open.
$doc path -segments {{move 20 100} {line 60 100} {line 60 130} {line 20 130} {close}
                     {move 30 108} {line 50 108} {line 50 122} {line 30 122} {close}} \
    -fill {0.7 0.75 0.85} -rule evenodd
```

Common options: `-fill`, `-stroke` (colours), `-width` (0 = thinnest line the device draws), `-dash` (lengths, or `none`/`solid`), `-cap` (`butt round square`), `-join` (`miter round bevel`), `-miter` (1 or more), `-opacity`, `-blend`. A refused shape - a point that is not a number, an unknown segment, an odd `-points` count - leaves nothing behind in the page. Points are `-at`/`-from`/`-to`/`-c1`/`-c2`, exactly two numbers each; segments are `{move x y}`, `{line x y}`, `{curve x1 y1 x2 y2 x y}`, `{close}` and begin with a `move`.

`arc` takes the same `-radius` or `-size {w h}` as `ellipse` and `-at` is the centre. Angles are **degrees, 0 at three o'clock, growing counter-clockwise as the page is read** (90 points up); `-start` defaults to 0, `-extent` is required and may be negative, `360` is the whole ellipse and beyond ±360 - or exactly 0 - is refused. `-style` is `arc` (open), `pieslice` or `chord`. `-style arc` takes no `-fill`: PDF closes an open path before filling it, so the result would silently be a chord - write `-style chord` when that is what you mean.

## Clipping - always inside save/restore

```tcl
$doc save
$doc clip -at {80 100} -size {50 30}
foreach dx {0 6 12 18 24 30 36 42 48 54 60} {
    $doc line -from [list [expr {80 + $dx}] 100] -to [list [expr {60 + $dx}] 130] -stroke darkcyan -width 2
}
$doc restore
$doc rect -at {80 100} -size {50 30} -stroke black -width 0.3

$doc save
$doc clip -rule evenodd -segments {{move 140 100} {line 190 100} {line 190 130} {line 140 130} {close}
                                   {move 150 108} {line 180 108} {line 180 122} {line 150 122} {close}}
$doc rect -at {140 100} -size {50 30} -fill {0.95 0.65 0.15}
$doc restore
```

`clip` ends in `W n` and draws nothing itself; it holds until the graphics state is restored, so it wants a `save` around it. `restore` without an open `save` in the same stream is refused. Give `-at`/`-size` **or** `-segments`, not both.

## Opacity, blend mode, the drawing state

```tcl
$doc save
$doc opacity 0.35                    ;# both sides; "opacity 0.35 fill" or "... stroke" for one (PDF 1.4)
$doc circle -at {40 160} -radius 12 -fill red
$doc circle -at {52 160} -radius 12 -fill green
$doc restore                         ;# the alpha is graphics state - take it back

$doc save
$doc blend Multiply                  ;# one of the sixteen; Compatible is refused
$doc rect -at {80 148} -size {24 24} -fill {0.95 0.65 0.15}
$doc circle -at {92 160} -radius 8 -fill {0.85 0.2 0.3}
$doc restore

# style: the same options the shapes take, in force until changed. A shape paints
# the sides style coloured plus the ones it names; a text between them leaves
# them alone. save/restore takes it back, a new page starts fresh.
$doc save
$doc style -fill {0.9 0.92 0.96} -stroke steelblue -width 0.8 -dash {3 1.5} -join round
$doc rect -at {120 148} -size {30 24}                 ;# filled AND stroked from the state
$doc rect -at {155 148} -size {30 24} -fill white     ;# still stroked blue
$doc line -from {120 178} -to {185 178} -dash solid   ;# per call wins
$doc restore
```

`-opacity`/`-blend` on a shape keep the change inside that shape's own save/restore. `opacity`, `blend`, `style` as commands are state and hold until changed.

## Overprint - the one state a reader never shows

```tcl
# Whether what is painted knocks out what lies under it on the OTHER plates
# (the default) or leaves it standing. Nothing a viewer shows changes; the
# press does. Black text on a cyan panel is the standing case: knocked out,
# the cyan plate is punched where the letters go and a misregister of a tenth
# of a millimetre shows white round every letter.
$doc save
$doc overprint -fill 1 -stroke 1
$doc rect -at {20 195} -size {45 14} -fill {cmyk 1 0 0 0}
$doc font -family helvetica -style bold -size 11 -color {cmyk 0 0 0 1}
$doc text "OVERPRINTED" -at {23 205}
$doc restore

# -mode writes /OPM: it says what a ZERO in a CMYK value means. 0 leaves that
# plate alone, 1 ("nonzero overprint") paints it at nought - which is how one
# plate is set without disturbing the rest.
$doc save
$doc overprint -fill 1 -mode 1
$doc rect -at {70 195} -size {45 14} -fill {cmyk 0 0.6 0.9 0}
$doc restore

# The shapes take -overprint themselves, which sets both sides at once inside
# the shape's own q/Q - a shape filled AND stroked in one call has no way of
# saying which of the two it meant.
$doc rect -at {120 195} -size {30 14} -fill {cmyk 0 0.9 0.9 0} -overprint 1

# And style takes it too, where it holds until changed like every other
# drawing state - so a run of shapes is set once rather than per call.
$doc save
$doc style -overprint 1 -fill {cmyk 0.15 0 1 0}
$doc rect -at {155 195} -size {12 14}
$doc rect -at {170 195} -size {12 14}
$doc restore

# A call naming NONE of the three is refused rather than writing a graphics
# state that changes nothing.
if {[catch {$doc overprint} message]} {
    puts "refused, as it should be: $message"
}
```

Naming the stroke says something about the fill as well: a graphics state carrying `/OP` and no `/op` sets **both** parameters (ISO 32000-2, Table 58), so a call that gives `-stroke` writes the fill side out too - from `-fill` where the call gives it, otherwise from the fill overprint already in force. The fill side is remembered per content stream and taken back by `restore`, exactly as the colours of `style` are. **The trap** is that overprinting a *light* colour is a mistake - yellow over cyan, overprinted, is green - and no viewer shows it and no validator reports it.

## Transformations

```tcl
# -at is a fixed point to turn/scale/skew about; -translate is a displacement -
# not the same thing. Parts compose translate, rotate, skew, scale, like a
# sequence of cm operators, so -translate is in unturned document units.
$doc save
$doc transform -at {40 210} -rotate -20
$doc rect -at {20 202} -size {40 16} -fill {0.8 0 0} -opacity 0.4
$doc font -family helvetica -style bold -size 12 -color {0.8 0 0}
$doc text "APPROVED" -at {40 213} -align center
$doc restore

$doc save
$doc transform -at {100 210} -scale {1 -1}       ;# a negative factor mirrors
$doc text "mirrored" -at {100 210} -align center
$doc restore

$doc save
$doc transform -at {150 210} -skew {0 -15}       ;# second angle: horizontal slant, an italic-looking stamp
$doc text "slanted" -at {150 213} -align center
$doc restore

# -matrix takes six raw cm operands (points, y up) as they stand and ignores the
# other options; a singular matrix is refused before it is written.
$doc save
$doc transform -matrix [list 1 0 0 1 [$doc distance 5] 0]
$doc text "5 mm to the right by matrix" -at {20 230} -color black -style {} -size 9
$doc restore
```

`transform` returns the matrix it applied - what `shading ... -matrix` and `shading pattern ... -matrix` take when a gradient is drawn under a transform (see `07-patterns-forms.md`).

## Colour

```tcl
# A name (148, no Tk), a hex triplet, a grey value, {r g b}, {c m y k}, or the
# space spelled out - the unambiguous form. Components are clamped to 0..1;
# NaN is refused instead (TCLPDF COLOUR COMPONENTS number) - it names no colour
# and has no nearest valid value to be clamped to.
foreach {colour x} {steelblue 20 #ffd700 40 #fd7 60 0.5 80 {0.2 0.45 0.75} 100
        {0 0.16 1 0} 120 {gray 0.5} 140 {rgb 1 0.84 0} 160 {cmyk 0 0.16 1 0} 180} {
    $doc rect -at [list $x 240] -size {16 10} -fill $colour
}
```

A name or triplet whose three components are equal (`black`, `white`, `gray`, `#808080`) is written as DeviceGray - usable under every PDF/A output intent. Three and four numbers are told apart by count.

### Separations - spot colours

```tcl
# {separation Name alternate ?tint?}: the plate as the press knows it, an
# ordinary device colour a reader shows instead, coverage 0..1 (default 1).
$doc rect -at {20 255} -size {40 12} -fill {separation Varnish {cmyk 0 0 0 0.2} 0.8}
$doc rect -at {65 255} -size {40 12} -fill {separation "PANTONE 300 C" {rgb 0 0.36 0.65}}
$doc rect -at {110 255} -size {40 12} -stroke {separation All {gray 0}} -width 1   ;# registration
```

One name is one ink: a name appearing again must carry the same alternate. The alternate is never another separation or a pattern; under PDF/A it follows the output intent like every colour.

### DeviceN - several named plates at once

```tcl
# {devicen {{Name colour} ...} ?{tint ...}?}: a list of colourants, each
# written exactly the way a separation is, and one tint per name in the same
# order - all of them 1 unless said otherwise. This is high-fidelity printing
# (CMYK plus orange and green) and the duotone.
$doc configure -version 1.6      ;# every entry of the attributes dictionary is 1.6
$doc rect -at {20 285} -size {40 10} \
    -fill {devicen {{Orange {cmyk 0 0.45 1 0}} {Green {cmyk 0.8 0 0.7 0.1}}} {0.7 0.3}}

# A duotone: black plus one spot, at two different coverages.
foreach {tint x} {1.0 65 0.6 90 0.3 115} {
    $doc rect -at [list $x 285] -size {20 10} \
        -fill [list devicen {{Black {gray 0}} {{PANTONE 300 C} {rgb 0 0.36 0.65}}} \
            [list [expr {$tint * 0.4}] $tint]]
}

# /None names a component that is never painted, it is the one name that may
# be repeated, and it stays out of the fallback colour as well.
$doc rect -at {140 285} -size {20 10} -fill {devicen {{Orange {cmyk 0 0.45 1 0}} {None}} {1 1}}
```

It is **not** a separation with several names: the space carries one function that turns n tints into the alternate space, so what it describes is how the inks look *together* (ISO 32000-2, 8.6.6.5). All the colourants therefore paint into one alternate - a grey one is promoted to the space of the coloured ones, mixing RGB with CMYK is refused, and Lab and ICC based colourants are refused too (paint such a plate on its own with `{separation Name {lab L a b} tint}`). `All` is refused here; at most 32 colourants. A colourant and a separation of the same name are the same plate and must agree about their alternate. A gradient cannot take one. (PDF 1.6.)

### Lab - a colour as it was measured

```tcl
# {lab L a b}: L* from 0 to 100, a* and b* over the range the space names.
# The numbers are NOT 0..1 like every other space here - a Lab colour clamped
# to that range would come out black.
$doc rect -at {20 272} -size {24 10} -fill {lab 54.29 80.81 69.88}      ;# the red of sRGB, as a measurement
$doc rect -at {48 272} -size {24 10} -fill {lab 87.73 -86.18 83.18}

# The two parameters of the space are options OF THE COLOUR, not of the shape:
# -whitePoint (D50 by default, the illuminant of every printed measurement)
# and -range (the standard's own {-100 100 -100 100}). Components outside the
# range are CLAMPED, as the standard prescribes - sRGB blue has a b* of
# -112.05 and needs the wider range prepress uses. A NaN among the components
# is refused, and so is one in -whitePoint or -range (TCLPDF COLOUR LAB).
$doc rect -at {76 272} -size {24 10} -fill {lab 32.30 79.20 -107.86 -range {-128 127 -128 127}}

# The point of the space is the spot colour: a plate with the measurement
# behind its name instead of a CMYK guess. Tint 0 is L* 100 - paper, not ink.
$doc rect -at {104 272} -size {24 10} -fill {separation "Spot Red" {lab 48.3 68.5 47.3} 0.6}
$doc font -family helvetica -size 8 -color {lab 30 0 0}
$doc text "Lab text" -at {134 279}
```

Lab is device independent, so `pdfa` admits it under **every** output intent - where a bare `{rgb ...}` is refused under a CMYK press intent. A gradient cannot take one, for the same reason it cannot take an ICC based colour: a shading names its space by family, and a Lab space is an array. `Lab` and `Lab` plus eight hexadecimal digits are the names this writer gives its own Lab spaces - not to be used for a separation or an `icc embed` alias. (PDF 1.1.)

### ICC based colours

```tcl
# Register a profile once; {icc alias components} is then a colour anywhere -
# fill, stroke, text - with as many components as the profile has.
$doc icc embed srgb $iccRgb
$doc icc embed press $iccCmyk
puts "profiles: [$doc icc names]"
$doc rect -at {155 255} -size {30 12} -fill {icc srgb 0.2 0.45 0.75}
$doc font -family helvetica -size 8 -color {icc press 0 0.5 1 0}
$doc text "ICC text" -at {155 275}
```

An ICC based colour is anchored to its profile, not to the device, so `pdfa` admits it under **every** output intent - `{icc srgb …}` passes PDF/A under a CMYK press intent where the bare `{rgb …}` is refused. A profile stands in the file once however many roads it arrives by (colour, picture profile, output intent). A shading cannot take one - give stops in grey, RGB or CMYK. (PDF 1.3.)

```tcl
$doc write [file join $out ref-04-graphics.pdf]
$doc destroy
```
