---
name: tclpdf-tcl
description: >
  Reference code for every documented tclpdf call - the pure-Tcl PDF package (text, fonts, tables, images, SVG, gradients, forms, links, tagged PDF, PDF/UA, PDF/A, ZUGFeRD/Factur-X/Order-X). Use whenever writing or reviewing Tcl that creates a PDF with tclpdf, or when a tclpdf call fails, is refused, or a validator (veraPDF, qpdf, Mustang) rejects the file. Trigger on "tclpdf", "$doc text", "$doc table", "font embed", "pdfa", "zugferd", "tagged", "ua 1", "PDF/A", "PDF/UA", "Factur-X", "Order-X", "PDF erzeugen mit Tcl". Copy from the reference files instead of reinventing a call.
---

# tclpdf: reference code, not recollection

> Long form / rationale: `doc/claude/TCLPDF.md`. The manual is `doc/tclpdf.md` (also as `tclpdf.n`/`.html`); it decides where this skill and memory disagree.

Every call the manual describes has a working snippet in `reference/`. **Copy the snippet, then adapt** - do not write a tclpdf call from memory of jsPDF, ReportLab, FPDF or pdf4tcl: the option names, the coordinate origin, the unit of `-size` and the refusals differ, and the same handful of mistakes come back every time (the trap list below).

## The one setup every snippet assumes

The reference files refer to these variables. Set them once at the top of a script, or of a session:

```tcl
package require Tcl 8.6.11-       ;# open-ended: "8.6" alone is refused by Tcl 9
package require tclpdf            ;# no package require zlib - it is a built-in command; Tk is never loaded

set assets   /path/to/assets                                ;# adjust
set ttf      [file join $assets fonts DejaVuSans.ttf]       ;# any TrueType face
set ttfBold  [file join $assets fonts DejaVuSans-Bold.ttf]
set otf      [file join $assets fonts NimbusSans-Regular.otf]   ;# an OpenType/CFF face
set type1    [file join $assets fonts NimbusSans-Regular.t1]    ;# with its .afm beside it
set variable [file join $assets fonts Roboto-Variable.ttf]      ;# a variable font
set jpeg     [file join $assets images photo.jpg]
set png      [file join $assets images logo.png]
set svgFile  [file join $assets images drawing.svg]
set iccRgb   /path/to/tclpdf/icc/sRGB2014.icc
set iccCmyk  /path/to/tclpdf/icc/ISOcoated_v2_bas.ICC
set invoiceXml [file join $assets xml factur-x.xml]         ;# a Factur-X / ZUGFeRD invoice
set orderXml   [file join $assets xml order-x.xml]          ;# an Order-X order
set out      /path/to/out
```

## The model in ten lines

1. `set doc [tclpdf new -unit mm]` - mm, A4, portrait, PDF 1.7, compressed. `$doc page add` before drawing. `$doc write path` (repeatable, byte-identical) or `writeChannel`. `$doc destroy`.
2. **y counts from the top.** `-at` is the **top left** corner - except `circle`/`ellipse`, where it is the centre. Inside a form or pattern script the origin is that object's own top left.
3. Positions are in the document unit; **font `-size` is always points**.
4. `font` sets **state** that stays (family, style, size, colour, spacing, leading, kerning ...). Every text call takes the same options **per call** without changing the state.
5. `text` without `-width` is one line and returns nothing (a `\n` in it is refused); with `-width` it is a paragraph and returns the **y below**; with `-height h|max` it returns `{y rest}`; with `-paginate 1` it adds pages itself and returns `{y rest page column}`.
6. A colour is a name, `#hex`, a grey number, `{r g b}`, `{c m y k}`, `{gray|rgb|cmyk ...}`, `{separation Name alt ?tint?}`, `{icc alias ...}` or `{pattern name}` in a fill.
7. `save`/`restore` bracket `clip`, `transform`, `opacity`, `blend`, `style` - all of them are graphics state that leaks otherwise. `text` brackets its own colour; the `font -color` state persists.
8. Everything is **checked at the call** and refused with a message naming the fix - a missing glyph, an unknown option, a wrong count, a feature above the PDF version. A refused shape leaves nothing in the page. Read the message; it names the way out.
9. Claims are explicit and checked at the write: `pdfa` (every font embedded, colours against the output intent), `ua` (title, language, fonts, headings, alt texts, link tooltips ...), `zugferd` (one call: PDF/A-3B, intent, XMP, attachment). They need **tdom** for the XMP packet.
10. Tagged PDF: `$doc tagged 1` **before** anything is drawn; then `text` is a `P`, `table` a `Table`, `-tag H1` for headings, `-alt`/`-artifact 1` on every picture, `structure Type -script {...}` for the grouping.

## Where the reference code is

| file | covers |
| --- | --- |
| `reference/01-document.md` | new/configure/cget, page add/size/box/typeArea, coords/distance/extent, page content, write/writeChannel, events on/off, reservation |
| `reference/02-fonts.md` | font state, the standard 14, embed TTF/OTF/Type 1/variable, font info/names, missing glyphs, kerning/ligatures, RTL and the writing systems |
| `reference/03-text.md` | one line, paragraph, indents, soft hyphens, -avoid, -height/-height max, -paginate, -columns/-balance, leader, textPath, pageNumbers, textWidth/Height/Lines |
| `reference/04-graphics.md` | line/rect/circle/ellipse/polygon/curve/path, clip, save/restore, opacity, blend, style, transform, colour forms, separations, icc embed |
| `reference/05-images-svg.md` | image embed/place/draw/info/size, -data, svg file/-data/info/size, SVG text faces, barcodes through tzint |
| `reference/06-tables.md` | head/body/foot, cell dictionaries, spans, columns (width/weight/align/decimal), styles/themes, rtl cells, -top/-bottom, repeated head, the four hooks, table layout |
| `reference/07-patterns-forms.md` | shading axial/radial, stops/extend, shading pattern, pattern create (-step/-unit/-origin/-matrix), the stream rule, form create/place |
| `reference/08-navigation-metadata.md` | attach, link, bookmark, destination/OpenAction, catalogEntry, info, language, xmpSchema, xmpRaw, metadata, viewerPreferences, pageLabels |
| `reference/09-tagged-ua.md` | tagged, structure, -tag, headings, lists, Figure/-alt/-artifact, Link, -expansion, artifacts and their kinds, ua / ua state |
| `reference/10-pdfa-zugferd.md` | pdfa (parts, conformance, profiles, the colour rule), pdfa extension, zugferd, Order-X, zugferd profile/state, the validator commands |

Each file is one runnable script top to bottom (`check.tcl` beside this file runs them all - see below).

## Traps: what keeps going wrong

- **`{20 [expr ...]}` does not substitute.** Braces quote; build points with `[list 20 $y]`.
- **`-at` for a circle is the centre**, for everything else the top left. y grows downwards.
- **`-family` with an exact PostScript name** (`Times-BoldItalic`) names the face; a `-style bold` in force does not apply to it. `-style` takes only `bold`, `italic`, both, or empty - `-style {}` clears it.
- **A character the face lacks is an error**, not a blank - the standard 14 stop at WinAnsi (`Ł`, `Č`, `→`, `✔` refused). Embed a face that carries it; do not trust a font viewer, it substitutes silently.
- **Text arriving NFD** (`U+0055 U+0308`) gets displaced accents. Normalise to NFC first.
- **A mixed-direction line is refused** under `-direction rtl`; set one call per direction. `-direction` is a line option, not a font option.
- **`text` with `-width` returns y; with `-height` a dict.** Reading `[dict get $y y]` off a plain number is the symptom of mixing them up.
- **`-paginate` needs `-width`** and refuses a numeric `-height`; `-columns` wants `-height max` or `-paginate`; `-balance` not with `-avoid`.
- **A table cell string that starts with a cell key** (`text`, `align`, `colSpan` ...) and has an even word count is read as a dictionary. Write it `{text "..."}`.
- **Unknown table keys are errors** - a misspelled `fontstyle` is refused, not ignored. Column widths: `width` (fixed) or `weight` (share); no percent.
- **A pattern belongs to its content stream** (page or form) and ignores the transform in force. Define a gradient **inside** the form that uses it; under `transform`, pass the returned matrix as `-matrix` and give coordinates through `coords`/`extent`/`distance`.
- **`style`, `opacity`, `blend`, `clip`, `transform` leak** until `restore` or a new page. Bracket them.
- **`tagged 1` after drawing is refused.** First call after `tclpdf new`.
- **The standard 14 faces block `pdfa` and `ua`** - every face embedded, and the check runs at the write, listing all offenders.
- **Colour under PDF/A follows the output intent**: RGB needs an RGB profile, CMYK a CMYK one, grey passes anywhere, `{icc ...}` passes anywhere; the `striped` head is RGB. A refused write does **not** undo the drawing.
- **`pdfa -part 2` refuses attachments**; part 3 takes them. **`ua -part 2` and `pdfa -part 3` cannot be combined** - an accessible invoice is `ua 1` + `pdfa -part 3`.
- **`attach -data` needs `-name`** and takes bytes: `encoding convertto utf-8` first.
- **`link -page`, `bookmark -page`, `destination`, `pageLabels -from` count from 0** - the index, not the printed number. Printed numbers and page labels must agree.
- **Write-time events fire on every write**: a subscriber that creates objects takes its number from `reservation` once, or the file grows per write.
- **tzint's status is three-valued** (0 ok, 1-4 warning with a good symbol, 5+ nothing) and on failure the target variable is left as it was - test the status, never the variable.
- **`-version` gates features**: `opacity` needs 1.4, shading 1.3, embedded fonts 1.2; a `1.0`/`1.1` document needs `-compress 0`. Nothing is raised silently except by `pdfa`/`ua`.
- **`image embed` of a PNG with alpha is ~100x the cost** of a JPEG or a PNG without; a browser canvas should send `image/jpeg`. Progressive JPEG and interlaced PNG are refused - re-save.
- **`page box media {} 0`** reads another page's box - the empty value comes before the index.
- **`-leading {}`** restores the default; `-leading 0` is refused. **`-stretch`/`-size` 0** is refused.
- **`metadata xml`** freezes the packet as given - after it, title and claims are no longer mirrored into XMP.

## Checking a document

Run the validators with the profile the file claims - `qpdf --check`, `verapdf -f 3b|3u|3a` / `--flavour ua1|ua2`, Mustang for a hybrid invoice, `pdffonts`, `pdftotext`, `pdfinfo -struct-text`. Each finds what the others do not (`reference/10-pdfa-zugferd.md`, last section). "It opens in a viewer" is not a check.

## Keeping the reference honest

`check.tcl` extracts every ```` ```tcl ```` block from `reference/*.md`, runs each file as one script under a real tclsh with real assets, and runs `qpdf --check` (and veraPDF where a file claims PDF/A) over what came out. Run it after a package change or an edit here:

```sh
tclsh8.6 doc/claude/skills/tclpdf-tcl/check.tcl assets.tcl   # assets.tcl sets the variables above
```

A snippet that stops running is a snippet that must be fixed, not deleted - it is what a reader will copy.
