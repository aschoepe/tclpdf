---
name: tclpdf-tcl
description: >
  Reference code for every documented tclpdf call - the pure-Tcl PDF package (text, fonts, fallback chains, colour fonts, hyphenation, tables, images in JPEG/PNG/TIFF, SVG, gradients, forms, layers, links, interactive form fields, tagged PDF, PDF/UA, PDF/A, ZUGFeRD/Factur-X/Order-X, encryption, digital signatures, importing and reading a foreign PDF). Use whenever writing or reviewing Tcl that creates a PDF with tclpdf, or when a tclpdf call fails, is refused, or a validator (veraPDF, qpdf, Mustang, pdfsig) rejects the file. Trigger on "tclpdf", "$doc text", "$doc table", "font embed", "colorFont", "-fallback", "image embed", "TIFF", "-dpi", "pdfa", "zugferd", "tagged", "ua 1", "PDF/A", "PDF/UA", "Factur-X", "Order-X", "$doc sign", "encrypt", "pdf import", "TCLPDF IMPORT", "layer create", "hyphenate", "$doc field", "AcroForm", "NeedAppearances", "Formularfeld", "PDF erzeugen mit Tcl". Copy from the reference files instead of reinventing a call.
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
set jpTtf    [file join $assets fonts NotoSansJP-Regular.ttf]   ;# a face with vhea/vmtx and the "vert" feature, for vertical writing
set jpeg     [file join $assets images photo.jpg]
set png      [file join $assets images logo.png]
set tiff     [file join $assets images scan.tiff]         ;# any TIFF
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
2. **y counts from the top.** `-at` is the **top left** corner - except `circle`/`ellipse`/`arc`, where it is the centre. Inside a form or pattern script the origin is that object's own top left.
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
| `reference/02-fonts.md` | font state, the standard 14, embed TTF/OTF/Type 1/variable/bare CFF, `-fallback` chains, font info/names, missing glyphs, kerning/ligatures/combining marks, `-render` modes, RTL and the writing systems, Type 3 (`font define`/`font glyph`), colour fonts (`colorFont`, COLR/CPAL), **vertical writing and breaking it into columns**, **what a font refusal says** (the eight reader classes of `TCLPDF FONT`) |
| `reference/03-text.md` | one line, paragraph, indents (`-indent`/`-indentRight`/`-firstIndent`), **runs inside a paragraph** (`-markup tags`, `-markup markdown`, lists as item paragraphs (`<ul>`/`<ol>`/`<li>`, `- `/`1. `), the `{text options}` list of `-runs 1`, `font family` so that a bold run reaches an embedded face, textLines/textHeight answering runs), soft hyphens, `-hyphenate` and `::tclpdf::hyphenate`, -avoid, -height/-height max, -paginate, -columns/-balance, leader, textPath, pageNumbers, textWidth/Height/Lines, **the four anchors**, **`-fit`/`-shrinkLimit` for one line**, **`-emergencyHyphen`** |
| `reference/04-graphics.md` | line/rect/circle/ellipse/arc/polygon/curve/path, clip, save/restore, opacity, blend, style, transform, **overprint** (the command, `-overprint` on a shape and on `style`), colour forms, separations, **DeviceN**, Lab, icc embed |
| `reference/05-images-svg.md` | image embed/place/draw/info/size, -data, `-inline`, JPEG/PNG/TIFF, `-dpi auto` and where a natural size comes from, TIFF strips and stacking, `-stencil`/`-mask`/`-invert`/`-interpolate`, svg file/-data/info/size, SVG text faces, SVG clip-path and mask (clipping path and luminosity soft mask), preserveAspectRatio (ten alignments, meet/slice/none), `font-weight`, barcodes through tzint, **`-fit` for a form and a drawing**, **what a drawing left out**, **`-interpolate` under PDF/A** |
| `reference/06-tables.md` | head/body/foot, cell dictionaries, spans, columns (width/weight/align/decimal), styles/themes, rtl cells, -top/-bottom, repeated head and foot, the four hooks, table layout |
| `reference/07-patterns-forms.md` | shading axial/radial, stops/extend, shading pattern, **shading function** (type 1), **the four mesh shadings** (`triangles`/`lattice`/`coons`/`tensor`), pattern create (-step/-unit/-origin/-matrix), the stream rule, form create/place, layers (`layer create/draw/state/radio/configure`, `-intent`) |
| `reference/08-navigation-metadata.md` | attach, link, bookmark, destination/OpenAction, catalogEntry, info, language, xmpSchema, xmpRaw, metadata, viewerPreferences, pageLabels, **initialView**, **annot note/stamp**, **the four text markups** (`-text`/`-lines`/`-quads`), **the geometry annotations** (line/square/circle/polygon/polyline) and **a file clipped to the place it belongs** |
| `reference/09-tagged-ua.md` | tagged, structure, -tag, headings, lists, Figure/-alt/-artifact, Link, -expansion, artifacts and their kinds, ua / ua state |
| `reference/10-pdfa-zugferd.md` | pdfa (parts, conformance, profiles, the colour rule), pdfa extension, zugferd, Order-X, zugferd profile/state, the validator commands |
| `reference/11-encryption-signatures.md` | encrypt (AES-256, permissions by name), sign (invisible and visible, one- and two-stage), sign state, **a signature in a tagged document and under PDF/UA** (`-tooltip`/`-contents`, the `Form` element, the artifact rule), `::tclpdf::sign digest`/`embed`/`add` |
| `reference/12-import-update-info.md` | pdf import, `::tclpdf::pdf info`/`pages`/`fonts`/`metadata`, `::tclpdf::update open` and the incremental update, **the handle's own vocabulary** (`add`/`reserve`/`put`/`addStream`/`replaceStream`/`release`/`ref`/`body`/`id`), the `TCLPDF IMPORT` error class |
| `reference/13-form-fields.md` | `field text`/`check`/`radio`/`button`/`listbox`/`combo`, `field default`/`list`/`names`/`state`, the appearance streams and `/NeedAppearances`, `/Opt` and what lands in `/V`, the reset action under PDF/A, form fields in a tagged document and under PDF/UA, and reading a finished form back with `pdf fields` |

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
- **An annotation belongs to a page**: `annot`, `link` and `page add` inside the `-script` of `form create` or `pattern create` are refused (`TCLPDF ANNOT PLACE form`, `TCLPDF LINK PLACE form`, `TCLPDF PAGE CANVAS add`) - the script draws in the form's own space and an annotation's `/Rect` is in the page's. Place the form first and lay the annotation over where it landed. `field` is different and needs no rule: it works out where its widget lands at the write.
- **A pattern belongs to its content stream** (page or form) and ignores the transform in force. Define a gradient **inside** the form that uses it; under `transform`, pass the returned matrix as `-matrix` and give coordinates through `coords`/`extent`/`distance`.
- **`style`, `opacity`, `blend`, `clip`, `transform` leak** until `restore` or a new page. Bracket them.
- **`tagged 1` after drawing is refused.** First call after `tclpdf new`.
- **The standard 14 faces block `pdfa` and `ua`** - every face embedded, and the check runs at the write, listing all offenders.
- **Colour under PDF/A follows the output intent**: RGB needs an RGB profile, CMYK a CMYK one, grey passes anywhere, `{icc ...}` passes anywhere; the `striped` head is RGB. A refused write does **not** undo the drawing.
- **`pdfa -part 2` refuses attachments**; part 3 takes them. **`ua -part 2` and `pdfa -part 3` cannot be combined** - an accessible invoice is `ua 1` + `pdfa -part 3`.
- **`attach -data` needs `-name` and `-date`** - a PDF date such as `D:20260827120000Z`, since `/Params /ModDate` is required of an embedded file stream used as an associated file; the path form takes the file's own `mtime`. It takes bytes: `encoding convertto utf-8` first.
- **`link -page`, `bookmark -page`, `destination`, `pageLabels -from` count from 0** - the index, not the printed number. Printed numbers and page labels must agree.
- **Write-time events fire on every write**: a subscriber that creates objects takes its number from `reservation` once, or the file grows per write.
- **tzint's status is three-valued** (0 ok, 1-4 warning with a good symbol, 5+ nothing) and on failure the target variable is left as it was - test the status, never the variable.
- **`-version` gates features**: `opacity` needs 1.4, shading 1.3, embedded fonts 1.2; a `1.0`/`1.1` document needs `-compress 0`. Nothing is raised silently except by `pdfa`/`ua`.
- **`image embed` of a PNG with alpha is ~100x the cost** of a JPEG or a PNG without; a browser canvas should send `image/jpeg`. Progressive JPEG and interlaced PNG are refused - re-save.
- **The default is `-dpi auto`, not 72.** A placement without `-width`/`-height`/`-size` comes out at the resolution the *file* states (`pHYs`, JFIF, Exif, TIFF `XResolution`), and 72 only where it states none. `image info` answers `xResolution`/`yResolution` **empty** when the file says nothing - empty is not 72 - and `resolution` says which segment the number came from; for a JPEG that states it twice, **Exif wins over JFIF**.
- **A TIFF goes in like any other picture, but may become several.** A compression that carries state from row to row (Deflate, CCITT, JPEG-in-TIFF) begins afresh in every strip, so the picture is one image XObject **per strip**; `image info` answers `strips`. Such a stack can neither be a `-mask` nor wear one (`TCLPDF TIFF STACKED`), and above 256 strips it is refused outright (`TCLPDF TIFF STRIPS`) - re-save with a `RowsPerStrip` that holds the whole picture. `-stencil` stays a PNG option.
- **`page box media {} 0`** reads another page's box - the empty value comes before the index.
- **`-leading {}`** restores the default; `-leading 0` is refused. **`-stretch`/`-size` 0** is refused.
- **`metadata xml`** freezes the packet as given - after it, title and claims are no longer mirrored into XMP.
- **`-fallback` is not a rescue from a missing glyph, it is a chain you name.** Every alias named has to be embedded already; a standard family may stand in the chain too. A character no face in it has is refused exactly as before. Not together with `-direction rtl`.
- **A colour font cannot be embedded, it has to be redrawn.** A face whose pictures live in a `COLR`/`CPAL`, `CBDT`, `sbix` or `SVG` table leaves every outline empty, so `font embed` refuses it (`TCLPDF FONT OUTLINES`) rather than write a valid, extractable, blank document. `colorFont alias path -chars "..."` draws the `COLR` colour glyphs into a Type 3 font instead - version 0's flat layers and version 1's paint graph with its gradients and compositing alike - and gives back the alias; it holds **only** the characters asked for - not a letter, not a space - so it lives in a `-fallback` chain, and the chain is tried in order, which means the symbol face goes first.
- **A Type 3 font has exactly the characters it was given** - the space among them. `font glyph ballot " " -width 400 -script {}` or a string with a blank in it is refused.
- **`-render stroke` reads `-stroke` and `-strokeWidth`** but does not insist on them: without `-stroke` the outline takes the stroking colour in force, which is black unless `style -stroke` set one. `-strokeWidth` is a **line** width in the document unit, not a font weight: the same 0.3 mm at every size.
- **tclpdf ships no hyphenation patterns** (licence). Load a libhyphen `.dic` with `::tclpdf::hyphenate load`, pass `-left 2 -right 2` for German, and know that `-hyphenate 1` needs `language` set. An unloaded language is refused, never set unhyphenated in silence.
- **A Lab colour is not 0..1**: `L*` runs to 100 and `a*`/`b*` over `-range`, which is an option **of the colour**, not of the shape. Out-of-range components are clamped, not refused - sRGB blue needs `-range {-128 127 -128 127}`.
- **A stencil takes the fill colour in force** and has to be one bit per sample; `-mask` names a second **embedded** picture, which must be embedded first and must be grey, without ICC and without transparency of its own.
- **A layer bracket opens and closes in one content stream**: a `layer draw -script` that adds a page is refused (`TCLPDF LAYER SCRIPT`). An `/OC` entry on an annotation is **not offered** - an `annot` or a `link` written inside `layer draw` is taken and lands outside the layer, so bracket the placement instead.
- **`encrypt` comes before anything is DRAWN** and before `language` and `link` (`TCLPDF ENCRYPT ORDER`) - an empty `page add`, even three of them, may already stand. It needs `-version 2.0` and cannot stand with `pdfa`, `zugferd` or `sign`.
- **`sign` prepares; the CMS object comes from a `-signer` prefix** that answers DER. `writeChannel` is refused for a signed document, a second `sign` on one document is refused (`::tclpdf::sign add` does that on the file), and `cades` is a promise `openssl cms -sign` cannot keep. **`::tclpdf::sign add` refuses a file that claims PDF/UA** (`TCLPDF SIGN STATE ua`) and one already certified (`TCLPDF SIGN STATE certified`) - an incremental update cannot rewrite the structure tree a widget has to be hung in, so an accessible signature is made by `sign` on the document as it is written.
- **A form field draws its own appearance, always** - `/NeedAppearances` is never written, and every widget carries an `/AP` or PDF/A fails the file. A choice field's `/V` holds the **displayed** text, not the export value, and `-options` counts words: one is display-and-export, two are `{export display}`, so a two-word display text needs a brace pair of its own. A radio set is **one** field with a widget per button, declared in one call; each button's description is the third word of its `-buttons` entry, and `-contents`/`-label` are refused on it. `-password` refuses `-value`. A push button has no value and needs `-caption`.
- **`tagged 1` is all a form needs for accessibility** - one `Form` element per **widget**, made at the call that declares the field, so a field declared *before* `tagged 1` is outside the tree and `ua` names it. `-tooltip` is the `/TU` PDF/UA requires on every field, `-contents` describes one widget, and `-label {script}` needs a PDF 2.0 file **and a tagged document** - in an untagged one there is no `Form` element to put a `Lbl` in, so the script is not run at all and nothing says so. **A visible signature counts as a field here**: `sign -rect` gets its own `Form` element and object reference, `sign -tooltip` writes its `/TU` and `sign -contents` its `/Contents`, while an invisible signature - the default, `/Rect [0 0 0 0]` - is an artifact under ISO 14289-2, 8.9.2.4.13 and is asked nothing. The rectangle decides that, not the claim, so `ua` may stand before the `sign` call or after it.
- **Under PDF/A a reset button is refused at the WRITE**, in either order of the two calls (`TCLPDF FIELD BUTTON PDFA`): the profile admits no action on a widget at all. So are a field whose page never came (`TCLPDF FIELD PAGE`), one whose rectangle lies entirely beside its page (`TCLPDF FIELD RECT OUTSIDE`), and a reset button whose `-fields` names a field the document never got (`TCLPDF FIELD BUTTON FIELDS`) - that one waits because a reset button may name a field declared after it. Those four; everything else about a field is refused at the call.
- **`pdf import`, `::tclpdf::pdf ...` and `::tclpdf::update open` refuse an encrypted file** - `pdf info` is the one exception and answers it. `pdf import` does not judge what it takes over: a claim covers what this document draws.
- **The message is not a contract, the `-errorcode` is.** `trap {TCLPDF IMPORT}` catches every refusal of the reader - twenty-three classes today, `XFA`, `OPTION` and `ROOM` among them - from every command that shares it, and a refusal registers nothing. Match a class, never a wording.
- **`::tclpdf::pdf`, `::tclpdf::update` and `::tclpdf::sign` need their own `package require`** (`tclpdf::importInfo`, `tclpdf::update`, `tclpdf::sign`) - `package require tclpdf` alone does not bring them.

## Checking a document

Run the validators with the profile the file claims - `qpdf --check`, `verapdf -f 3b|3u|3a` / `--flavour ua1|ua2`, Mustang for a hybrid invoice, `pdfsig` for a signed one, `qpdf --show-encryption` for an encrypted one, `pdffonts`, `pdftotext`, `pdfinfo -struct-text`. Each finds what the others do not (`reference/10-pdfa-zugferd.md`, last section). "It opens in a viewer" is not a check.

## Keeping the reference honest

`check.tcl` extracts every ```` ```tcl ```` block from `reference/*.md`, runs each file as one script under a real tclsh with real assets, and runs `qpdf --check` (and veraPDF where a file claims a PDF/A part or a PDF/UA part) over what came out. It also holds the refusals to their own demonstration: **every `catch` and `try` that shows a refusal carries the branch that prints `NOT REFUSED` when the call goes through**, that line is a failure of the file that printed it, and the two are counted against each other in the extracted code before the script is run - so a demonstration written without its branch fails at once instead of passing in silence for ever. Run it after a package change or an edit here:

```sh
tclsh8.6 doc/claude/skills/tclpdf-tcl/check.tcl assets.tcl   # assets.tcl sets the variables above
```

A snippet that stops running is a snippet that must be fixed, not deleted - it is what a reader will copy. The same holds for a refusal that stops being one: the branch is there so that the reference cannot go on promising it.
