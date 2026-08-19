# tclpdf versus pdf4tcl — the measured comparison

Created 2026-08-19, because the question came from outside ("how does this compare to pdf4tcl?").

| | what was examined | version |
| --- | --- | --- |
| **Date of measurement** | measured 2026-08-18 (font path, live interpreter) and 2026-08-19 (all grep counts, manual cross-check) | — |
| **pdf4tcl** | `pdf4tcl094` as downloaded | **0.9.4** (`package provide pdf4tcl 0.9.4`; `pdf4tcl.tcl` dated 2020-11-19) — the last published release (SourceForge file list retrieved 2026-08-19: 0.9.4 of 2021-01-25 is the newest); 11,297 lines in four files: `pdf4tcl.tcl`, `glyph2uni.tcl`, `stdmetrics.tcl`, `pkgIndex.tcl` |
| **tclpdf** | this source tree | **1.1.1** (`package provide tclpdf 1.1.1`), tree of 2026-08-19 evening (page import `pdf import` new, checked in as `f1eee9a0`); 27,811 lines in 70 modules |

The pdf4tcl statements are counted at the source and the manual (`pdf4tcl.man`) or measured in a live interpreter — not from memory; wherever a number appears, it is a grep or measurement result of those two days. Both licences are BSD-style free (pdf4tcl: Tcl licence; tclpdf: MIT). Should a newer pdf4tcl release appear, the **no** rows must be re-measured before being quoted.

This paper is the long form with the evidence; the short form for answers to outside questions is in the project wiki.

## The one structural difference: the font path

Everything else is feature lists; this is architecture, and it decides most practical cases.

**pdf4tcl addresses glyphs through one 8-bit encoding per font.** `pdf4tcl::createFont base name cp1252` binds the embedded file to exactly one codepage; whoever needs a second one registers the same file again under a second name with `cp1251` and switches "fonts" in the text. Whatever falls outside the chosen codepage **silently becomes a question mark** — no error while drawing, none while extracting. `createFontSpecEnc` allows a hand-built encoding, but that too ends at 256 positions (the manual's own words: "a list of (up to 256) unicode values").

**tclpdf addresses through glyph IDs** (Type0/CIDFontType2, Identity-H) with a ToUnicode reverse map and subsets to the glyphs actually used. There is no codepage boundary, and a character the font does not have is an **error with a position** instead of a silent replacement character.

Measured 2026-08-18, the same DejaVu Sans embedded in both packages:

| input | pdf4tcl (cp1252) | pdf4tcl (cp1251) | tclpdf |
| --- | --- | --- | --- |
| `Grüße, Café` | Grüße, Café | Gr??e | Grüße, Café |
| `Łódź` | **?ód?** | — | Łódź |
| `Москва` | **??????** | Москва | Москва |
| `İstanbul` | **?stanbul** | — | İstanbul |
| `中文` | **??** | **??** | **refused with a message** ("has no glyph for U+4E2D (position 9)") |

None of the question-mark rows produced any message in pdf4tcl — neither while drawing nor from `pdftotext`. That is the difference that matters for invoices and everything archivable: the error travels unnoticed all the way to the recipient.

## What tclpdf can do versus pdf4tcl

Per row: the feature, and how the finding on the pdf4tcl side is substantiated. Where **no** stands, it was checked like this: the terms named are PDF keywords that would have to appear literally in the *generated document* (`/OutputIntents`, `/Separation`, `Identity-H` …) — and a grep over the entire source (`pdf4tcl.tcl`, 11,297 lines) finds them **not a single time**. What the program can nowhere write, it cannot deliver, whatever its procedures are called. Where the term does occur but no feature stands behind it, that was read up individually and the row says so. The opposite direction — what pdf4tcl can do and tclpdf cannot — is measured the same way in all fairness and sorted into the topics, recognizable by the **no** on the tclpdf side; three of those (canvas, AcroForm, catPdf) are genuine unique features.

| feature | tclpdf | pdf4tcl (measured) |
| --- | --- | --- |
| **Standards, metadata, archiving** | | |
| PDF/A-2/-3 (B, U, A) with OutputIntent and colour-space check before writing | yes | **no** — the keywords `PDF/A` and `OutputIntent` do not occur in the source |
| XMP metadata packet, extensible (`xmpSchema`, `xmpRaw`) | yes | **no** — `XMP` does not occur in the source; there is only the Info dictionary (`metadata -author …`) |
| Tagged PDF (structure tree, 49+ types, Annex L check), PDF/UA-1/-2, WTPDF | yes | **no** — `StructTreeRoot` and `MarkInfo` do not occur in the source |
| ZUGFeRD / Factur-X / Order-X as one call, profile read from BT-24 | yes | **no** — `ZUGFeRD` and `factur` do not occur in the source |
| Validation stand: veraPDF, qpdf, Mustang on every acceptance run | yes — `make check`, 37 checks, each tool against its standard: qpdf against the file syntax of ISO 32000, veraPDF against the PDF/A profile (ISO 19005) each document **claims itself** (3b/3u/3a from its own XMP), plus PDF/UA-1/-2 (ISO 14289-1/-2) and WTPDF for documents carrying a `pdfuaid` identifier, Mustangproject against ZUGFeRD/Factur-X (EN 16931, XML schema and Schematron including how the XML sits in the PDF) for every document with a hybrid attachment, and poppler's `pdfinfo` as an independent reader; the qpdf step with a control run on a deliberately broken file | **no** — no counterpart in the package |
| **Fonts** | | |
| Unicode without a codepage boundary (Identity-H, ToUnicode) | yes | **no** — `Identity-H` does not occur in the source; one 8-bit encoding per font, see above |
| Missing glyph = error with position | yes | **no** — silent `?`, measured |
| Automatic subsetting by use | yes | **no** — manual only: `createFontSpecEnc` with a self-enumerated list of at most 256 |
| Kerning (GPOS + `kern`), on by default | yes | **no** — `kern` occurs neither in the source nor in the manual |
| Ligatures (`liga`) with ToUnicode reverse mapping | yes | **no** — no GSUB reader present |
| Variable fonts at any axis position (`-axes`, `-instance`) | yes | **no** |
| Embedding TrueType (`.ttf`) | yes — FontFile2 | yes — FontFile2 (`loadBaseTrueTypeFont`), 8-bit encoding as above |
| Embedding OpenType/CFF (`.otf`) | yes — whole file as FontFile3 (`/Subtype /OpenType`) | **no** — `FontFile3` does not occur in the source |
| Embedding Type 1 (`.pfb`/`.pfa`/`.t1`) | yes — FontFile, metrics from the AFM next to it | yes — FontFile (`loadBaseType1Font` with AFM + PFB) |
| Embedding rights (`fsType`) read and reported | yes — `font info` | **no** — not read |
| **Text and typesetting** | | |
| Right-to-left scripts: Hebrew (ordering), Arabic (joining forms from GSUB), digits/brackets per UAX #9 | yes; what cannot be shaped is refused | **no** — `rtl`, `arabic`, `hebrew`, `bidi` do not occur in the source (the one hit is a comment about reportlab) |
| Paragraph with a height limit that **returns the rest** | yes — `-height` → `{y rest}` | yes — `drawTextBox` returns the rest |
| Self-paginating text across pages (`-paginate`), type area per page | yes | **no** — the caller breaks pages himself |
| Multi-column setting with balancing on the last page (`-columns`, `-balance`) | yes | **no** |
| Flowing around rectangles and circles (`-avoid`) | yes | **no** |
| Soft hyphens (U+00AD), offered as break points with an ActualText bracket | yes | **no** — `hyphen` and `00AD` do not occur in the source |
| Leader lines (`leader`) | yes | **no** |
| Text on a path, rotated glyph by glyph | yes — `textPath` | **no** |
| Page numbers "page n of m" resolved at write time | yes — `pageNumbers` | **no** |
| Justified text | yes — through word spacing (ISO 9.3.3) | yes — `drawTextBox -align justify` |
| Measuring without drawing | yes — `textWidth`, `textHeight`, `textLines`, `table layout` | yes — `getStringWidth`, `drawTextBox -dryrun` |
| Sheared text | yes — via `transform -skew` around a fixed point | yes — as a text option (`-xangle`/`-yangle` per call) |
| **Tables** | | |
| A table API at all | yes — `table` with header/body/footer | **no** — no table method in the source, none in the manual; one builds from `drawTextBox` and lines by hand |
| Column widths fixed/weighted/automatic, page breaks with header/footer repetition, rowSpan/colSpan, decimal alignment, RTL per cell, four hooks, themes | yes | **no** — moot for lack of a table |
| **Graphics, colour, images** | | |
| Gradients (axial/radial) as drawings **and** as fill patterns of any shape and of text | yes | **no** — `ShadingType` does not occur in the source; the two `Shading` spots serve the canvas import alone |
| Tiling patterns as an API (`pattern create`) | yes | **no** — `PatternType 1` exists only in the canvas import (tkpath), no API of its own |
| Transparency/opacity as an API, 16 blend modes | yes — `opacity`, `blend`, `-opacity` per shape | **no** — ExtGState only in the canvas import, no documented option |
| Form XObjects as an **isolated transparency group** | yes | **no** — `startXObject` exists, but without a group |
| Spot colours (Separation) with tint transform | yes | **no** — `Separation` does not occur in the source |
| ICC-based colours, profile once per file | yes — `icc embed`, `{icc …}` | **no** — `ICCBased` does not occur in the source |
| SVG as real vectors (and barcodes on top, via tzint) | yes | **no** — `svg` does not occur in the source |
| Image pass-through verified (progressive JPEG, Adam7 refused instead of broken) | yes | **no** — whatever arrives is assumed fine |
| PNG transparency: colour key as `/Mask` without decoding, 16-bit special path | yes | **no** — alpha yes, the colour-key path no |
| **Drawing a Tk canvas onto the page** (`canvas .c -bbox …`), including tkpath extensions | **no**, roadmap item 1 | yes |
| TIFF as an image format | **no** — JPEG and PNG | yes — through the `tiff` package |
| An arc command (`arc`: start angle, extent) | **no** — an arc takes self-computed Bézier segments; example `01.09` carries its own `arcSegments` procedure for that (`arrow` and `oval` do not count: arrow = `polygon`, oval = `ellipse`) | yes |
| Raw image data directly (`addRawImage` from pixel lists) | **no** — `-data` accepts finished JPEG/PNG bytes, not pixel lists | yes |
| **Navigation and interaction** | | |
| Link annotations: URL, page, structure element; tooltip | yes — `link` | **no** — `/URI` and `/Subtype /Link` do not occur in the source; the only `/Dest` sits in the bookmark writer, annotations exist only as FileAttachment and Widget |
| Page labels (`pageLabels`), viewer preferences (`viewerPreferences`) | yes | **no** — `PageLabels` and `ViewerPreferences` do not occur in the source |
| Bookmarks | yes — nested, `-open`, target with `-to`/`-zoom` | yes — `bookmarkAdd`, target fixed at `/XYZ null null null` |
| Attachments | yes — with `/AFRelationship`, name tree, `-data` | yes — `attachFile`/`embedFile`, without AFRelationship |
| **AcroForm fields**: creating (`addForm`: text, checkbutton) and **reading** them from foreign PDFs (`getForms`) | **no** (measured on the document stock: 0 of 216 generated documents carried fields) | yes |
| **Construction** | | |
| Extensible without touching the core: event bus (6 events), `oo::define`, `reservation`, `catalogEntry`, own XMP schemas | yes — `doc/PLUGINS.md` with examples | **no** — no extension mechanism documented |
| Errors refused at the call instead of drawn on silently | yes — checked at the call, nothing half-done in the stream | **no** — drawing on silently, measured at the `?` |
| Second `write` byte-identical, channels (`writeChannel`) | yes | **no** — `write` once at the end, channel not documented |
| Pure Tcl, no Tk | yes | yes at the core — TIFF via the `tiff` package, some image paths via `Img` (= Tk) |
| Taking over a page of a foreign PDF as a form and overlaying it (letterhead) | yes — `pdf import` (2026-08-19): both cross-reference flavours of the standard including object streams, page selection, CropBox/`/Rotate`; placed via `form place` | **no** — reading exists only for `catPdf` (concatenating whole documents) and `getForms`; putting a page as an XObject onto one's own page does not |
| **Concatenating PDFs** (`catPdf`) | **no** — a one-call concatenation is missing; page by page it works since `pdf import`, but as forms on own pages, not as a 1:1 chain | yes — with self-declared limitations |
| Compressed streams (Flate) | yes — `-compress`, on by default; ZUGFeRD XML deliberately uncompressed, refused under PDF 1.2 instead of silently ignored | yes — `-compress`, on by default (`zlib compress`); overridable per page/image/attachment |
| Encryption | **no** — roadmap item 3, blocked: no cryptography available | **no** — `encrypt` does not occur in the source |

What both can do stands in the topic blocks with yes on both sides (sheared text, justified text, the returned rest, bookmarks, attachments, compression).

## Where each belongs

For a report in a Western European language, a Tk program that wants to print its canvas, or a quick form, pdf4tcl is the smaller and long-proven dependency. As soon as one of the following words appears in the requirement, the territory tclpdf was built for begins: **invoice** (ZUGFeRD/Factur-X/Order-X), **archive** (PDF/A with a validation stand), **accessibility** (Tagged PDF, PDF/UA), **table with page breaks**, **Cyrillic/Polish/Turkish/Hebrew/Arabic**, **SVG/barcode**, **taking over a letterhead as PDF**, **spot colour/CMYK intent** — or whenever a silent error costs more than an error message.
