---
name: tclpdf-tcl
description: >
  Reference code for every documented tclpdf call - the pure-Tcl PDF package (text, fonts, hyphenation, tables, images, SVG, gradients, forms, layers, links, tagged PDF, PDF/UA, PDF/A, ZUGFeRD/Factur-X/Order-X, encryption, digital signatures, importing and reading a foreign PDF). Use whenever writing or reviewing Tcl that creates a PDF with tclpdf, or when a tclpdf call fails, is refused, or a validator (veraPDF, qpdf, Mustang, pdfsig) rejects the file. Trigger on "tclpdf", "$doc text", "$doc table", "font embed", "pdfa", "zugferd", "tagged", "ua 1", "PDF/A", "PDF/UA", "Factur-X", "Order-X", "$doc sign", "encrypt", "pdf import", "layer create", "hyphenate", "PDF erzeugen mit Tcl". Copy from the reference files instead of reinventing a call.
---

# tclpdf: reference code, not recollection

> Long form / rationale: `doc/claude/TCLPDF.md`. The manual is `doc/tclpdf.md` (also as `tclpdf.n`/`.html`); it decides where this skill and memory disagree.

This skill ships **with the tclpdf source**, so that anyone who fetches the package has a checked reference for writing their own PDFs. Checked literally: `check.tcl` beside this file runs every snippet on your machine against your copy of the package - see the end of this page.

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
set hyphenPatterns /usr/share/hyphen/hyph_de_DE.dic         ;# THE PACKAGE SHIPS NONE - see 03-text.md
set out      /path/to/out
```

## The model in ten lines

1. `set doc [tclpdf new -unit mm]` - mm, A4, portrait, PDF 1.7, compressed. `$doc page add` before drawing. `$doc write path` (repeatable, and byte-identical unless the document is signed or encrypted) or `writeChannel` (refused for a signed document). `$doc destroy`.
2. **y counts from the top.** `-at` is the **top left** corner - except `circle`/`ellipse`, where it is the centre. Inside a form or pattern script the origin is that object's own top left.
3. Positions are in the document unit; **font `-size` is always points**.
4. `font` sets **state** that stays (family, style, size, colour, spacing, leading, kerning ...). Every text call takes the same options **per call** without changing the state.
5. `text` without `-width` is one line and returns nothing (a `\n` in it is refused); with `-width` it is a paragraph and returns the **y below**; with `-height h|max` it returns `{y rest}`; with `-paginate 1` it adds pages itself and returns `{y rest page column}`.
6. A colour is a name, `#hex`, a grey number, `{r g b}`, `{c m y k}`, `{gray|rgb|cmyk ...}`, `{separation Name alt ?tint?}`, `{icc alias ...}`, `{lab L a b}` or `{pattern name}` in a fill.
7. `save`/`restore` bracket `clip`, `transform`, `opacity`, `blend`, `style` - all of them are graphics state that leaks otherwise. `text` brackets its own colour; the `font -color` state persists.
8. Everything is **checked at the call** and refused with a message naming the fix - a missing glyph, an unknown option, a wrong count, a feature above the PDF version. A refused shape leaves nothing in the page. Read the message; it names the way out.
9. Claims are explicit and checked at the write: `pdfa` (every font embedded, colours against the output intent), `ua` (title, language, fonts, headings, alt texts, link tooltips ...), `zugferd` (one call: PDF/A-3B, intent, XMP, attachment). They need **tdom** for the XMP packet. `encrypt` and `sign` are declared the same way and exclude each other, and `encrypt` excludes every PDF/A claim.
10. Tagged PDF: `$doc tagged 1` **before** anything is drawn; then `text` is a `P`, `table` a `Table`, `-tag H1` for headings, `-alt`/`-artifact 1` on every picture, `structure Type -script {...}` for the grouping.

## Where the reference code is

| file | covers |
| --- | --- |
| `reference/01-document.md` | new/configure/cget, page add/size/box/typeArea, coords/distance/extent, page content, write/writeChannel, events on/off, reservation |
| `reference/02-fonts.md` | font state, the standard 14, embed TTF/OTF/Type 1/variable, `-fallback` chains, font info/names, missing glyphs, kerning/ligatures/combining marks, `-render` modes, RTL and the writing systems, Type 3 (`font define`/`font glyph`) |
| `reference/03-text.md` | one line, paragraph, indents, soft hyphens, `-hyphenate` and `::tclpdf::hyphenate`, -avoid, -height/-height max, -paginate, -columns/-balance, leader, textPath, pageNumbers, textWidth/Height/Lines |
| `reference/04-graphics.md` | line/rect/circle/ellipse/polygon/curve/path, clip, save/restore, opacity, blend, style, transform, colour forms, separations, Lab, icc embed |
| `reference/05-images-svg.md` | image embed/place/draw/info/size, -data, `-stencil`/`-mask`/`-invert`/`-interpolate`, svg file/-data/info/size, SVG text faces, barcodes through tzint |
| `reference/06-tables.md` | head/body/foot, cell dictionaries, spans, columns (width/weight/align/decimal), styles/themes, rtl cells, -top/-bottom, repeated head, the four hooks, table layout |
| `reference/07-patterns-forms.md` | shading axial/radial, stops/extend, shading pattern, pattern create (-step/-unit/-origin/-matrix), the stream rule, form create/place, layers (`layer create/draw/state/radio/configure`) |
| `reference/08-navigation-metadata.md` | attach, link, bookmark, destination/OpenAction, catalogEntry, info, language, xmpSchema, xmpRaw, metadata, viewerPreferences, pageLabels |
| `reference/09-tagged-ua.md` | tagged, structure, -tag, headings, lists, Figure/-alt/-artifact, Link, -expansion, artifacts and their kinds, ua / ua state |
| `reference/10-pdfa-zugferd.md` | pdfa (parts, conformance, profiles, the colour rule), pdfa extension, zugferd, Order-X, zugferd profile/state, the validator commands |
| `reference/11-encryption-signatures.md` | encrypt (AES-256, permissions by name), sign (invisible and visible, one- and two-stage), sign state, `::tclpdf::sign digest`/`embed`/`add` |
| `reference/12-import-update-info.md` | pdf import, `::tclpdf::pdf info`/`pages`/`fonts`/`metadata`, `::tclpdf::update open` and the incremental update |

Each file is one runnable script top to bottom (`check.tcl` beside this file runs them all - see below).

## Traps: what keeps going wrong

- **`{20 [expr ...]}` does not substitute.** Braces quote; build points with `[list 20 $y]`.
- **`-at` for a circle is the centre**, for everything else the top left. y grows downwards.
- **`-family` with an exact PostScript name** (`Times-BoldItalic`) names the face; a `-style bold` in force does not apply to it. `-style` takes only `bold`, `italic`, both, or empty - `-style {}` clears it.
- **A character the face lacks is an error**, not a blank - the standard 14 stop at WinAnsi (`Ł`, `Č`, `→`, `✔` refused). Embed a face that carries it; do not trust a font viewer, it substitutes silently.
- **Combining marks are placed** from the face's GPOS anchors, so text arriving NFD (`U+0055 U+0308`) sets correctly and measures the same as the composed spelling. Hebrew nikud and Arabic harakat belong here: a vocalised `-direction rtl` line is set, not refused. It needs a face that carries the lookups - the standard fourteen refuse `U+0308` outright, being outside WinAnsi. On a path a mark rides with its base, but `-spacing` counts glyphs, so the decomposed spelling opens one gap per mark that the composed one does not.
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
- **`-fallback` is not a rescue from a missing glyph, it is a chain you name.** Every face in it has to be embedded already, and a character no face has is refused exactly as before. Not together with `-direction rtl`.
- **A Type 3 font has exactly the characters it was given** - the space among them. `font glyph ballot " " -width 400 -script {}` or a string with a blank in it is refused.
- **`-render stroke` needs `-stroke`**, and `-strokeWidth` is a **line** width in the document unit, not a font weight: the same 0.3 mm at every size.
- **tclpdf ships no hyphenation patterns** (licence). Load a libhyphen `.dic` with `::tclpdf::hyphenate load`, pass `-left 2 -right 2` for German, and know that `-hyphenate 1` needs `language` set. An unloaded language is refused, never set unhyphenated in silence.
- **A Lab colour is not 0..1**: `L*` runs to 100 and `a*`/`b*` over `-range`, which is an option **of the colour**, not of the shape. Out-of-range components are clamped, not refused - sRGB blue needs `-range {-128 127 -128 127}`.
- **A stencil takes the fill colour in force** and has to be one bit per sample; `-mask` names a second **embedded** picture, which must be embedded first and must be grey, without ICC and without transparency of its own.
- **A layer bracket opens and closes in one content stream**: a `layer draw -script` that adds a page is refused. An annotation cannot be put into a layer at all.
- **`encrypt` comes first** - before the first page and before `language` and `link` - needs `-version 2.0`, and cannot stand with `pdfa`, `zugferd` or `sign`.
- **`sign` prepares; the CMS object comes from a `-signer` prefix** that answers DER. `writeChannel` is refused for a signed document, a second `sign` on one document is refused (`::tclpdf::sign add` does that on the file), and `cades` is a promise `openssl cms -sign` cannot keep.
- **`pdf import`, `::tclpdf::pdf ...` and `::tclpdf::update open` refuse an encrypted file** - `pdf info` is the one exception and answers it. `pdf import` does not judge what it takes over: a claim covers what this document draws.
- **`::tclpdf::pdf`, `::tclpdf::update` and `::tclpdf::sign` need their own `package require`** (`tclpdf::importInfo`, `tclpdf::update`, `tclpdf::sign`) - `package require tclpdf` alone does not bring them.

## Checking a document

Run the validators with the profile the file claims - `qpdf --check`, `verapdf -f 3b|3u|3a` / `--flavour ua1|ua2`, Mustang for a hybrid invoice, `pdfsig` for a signed one, `qpdf --show-encryption` for an encrypted one, `pdffonts`, `pdftotext`, `pdfinfo -struct-text`. Each finds what the others do not (`reference/10-pdfa-zugferd.md`, last section). "It opens in a viewer" is not a check.

## Keeping the reference honest

`check.tcl` extracts every ```` ```tcl ```` block from `reference/*.md`, runs each file as one script under a real tclsh with real assets, and runs `qpdf --check` (and veraPDF where a file claims PDF/A) over what came out. Run it after a package change or an edit here:

```sh
tclsh8.6 doc/claude/skills/tclpdf-tcl/check.tcl assets.tcl   # assets.tcl sets the variables above
```

A snippet that stops running is a snippet that must be fixed, not deleted - it is what a reader will copy.
