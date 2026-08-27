# Example assets

Fonts, images and invoice data used by the scripts in `examples/`. Kept apart
from the scripts so that `examples/` stays a plain list of what there is to
look at.

Every entry below was **measured, not assumed** — the file type, the colour
type, the embedding flag and the profile identifier were read out of the files
themselves. What a file is named is not evidence of what it contains, and an
example that quietly demonstrates the wrong thing is worse than none.

```
fonts/     DejaVu Sans, regular and bold, kept flat            (stage 2)
           google/, eighteen faces, eleven of them Noto        (stages 2 and 6)
           liberation-fonts/, twelve metric stand-ins          (stage 2)
           tsukurimashou/, OCR A and OCR B in four formats     (stage 2)
           urw-core35-fonts/, fourteen faces for PDF/A         (stage 2)
           adobe-afm/, the metrics afmData.tcl is built from   (build)
           adobe-standard-14/, internal test material only     (travels nowhere)
           licenses/, nineteen texts, one per family           (stage 2)
images/    JPEG, PNG and TIFF per code path, plus SVG          (stages 3 and 6)
xml/       two ZUGFeRD profiles and one Order-X order          (stage 5)
languages/ hyphenation patterns, German and English            (stage 1)
```

**Sizes here are decimal** — 1 KB is 1000 bytes and 1 MB is 1 000 000, the unit `stat` and `ls -l` count in. Two of the figures below used to be binary (MiB) while the rest were decimal, which made one directory look like two sizes.

The sRGB ICC profile does **not** belong here. It is not example data but part
of the package — it goes to `icc/` at the top level and is installed with it.

## None of this ships with the package

Everything in this directory exists so that the **tests and the examples** have
something to work on. It is not part of tclpdf and is not delivered with it —
verified against the build, not assumed:

| | fonts and other assets |
| --- | --- |
| `make install` | **not installed** — only the `.tcl` modules, `pkgIndex.tcl`, `license.terms` and `icc/` |
| `tclpdf<version>.zip`, `.tar.gz` | **not contained** — measured, zero font files |
| `tclpdf<version>-src.tar.gz` | contained, with the licence texts beside them |

That distinction is what keeps the licensing simple. **tclpdf is MIT; the fonts
are not.** They are third-party work under their own terms, they carry those
terms with them — in `fonts/licenses/` for the flat files, in the directory
itself for `urw-core35-fonts/` — and they reach nobody who merely installs
the package. A font only becomes the user's licensing question when the user
embeds one of their own — which is why tclpdf reads `fsType` and reports it.

**Adding an asset means checking that side too:** an example is worth nothing
if the file it needs may not be redistributed. The two ZUGFeRD invoices below
are the standing example of how to answer that — the terms turned out to be
inside the files themselves, so they travel in the source archive like
everything else here.

---

## fonts/ — 58.2 MB, of which 31.2 MB travel

Sorted by **origin** since 2026-08-17, one directory per source, so that a
licence question has one place to look:

| directory | what | terms |
| --- | --- | --- |
| `fonts/` itself | DejaVu Sans, regular and bold — the face most tests and examples reach for first, kept flat for the short path | Bitstream Vera licence, `licenses/DejaVu-*` |
| `google/` | the Google Fonts faces: Roboto (static and variable), Arimo (variable, the Arial metrics — example 03.04 embeds it under the alias the barcode encoder asks for), Bitcount Prop Single (static and variable), Niconne, Permanent Marker, and eleven Noto faces — the ten of example 02.09 (Sans, Sans JP, Serif Tibetan, Sans Symbols, Sans Symbols 2, Emoji, Sans Cuneiform, Sans Egyptian Hieroglyphs, Naskh Arabic, Music) plus **Noto Color Emoji** for example 02.18 — 43.2 MB, of which 18.1 MB travel | SIL Open Font License 1.1 (Permanent Marker: Apache 2.0), one text per family in `licenses/` |
| `tsukurimashou/` | OCR A and OCR B, each as `.ttf`, `.otf`, `.pfb` and `.afm`, from the OCR package of the Tsukurimashou Project | public domain and free-use statements of the three authors, quoted in `licenses/OCR-LICENSE.txt` |
| `urw-core35-fonts/` | the fourteen URW faces that stand in for the standard 14, in four formats, with their own `NOTICE.md` and licence texts | OFL 1.1 chosen of three |
| `liberation-fonts/` | Liberation Sans, Serif and Mono, four styles each (release 2.1.5) — metric copies of Arial, Times New Roman and Courier New, the second free stand-in for the standard 14; own `NOTICE.md` with origin, hash and the measurement (2255 of 2292 advances equal to the AFM) | SIL OFL 1.1, `LICENSE` beside them |
| `adobe-afm/` | the fourteen Adobe core font metrics — build input, not example data, see below | Adobe's AFM grant, `LICENSE.txt` beside them |
| `adobe-standard-14/` | Adobe's own Type 1 and OpenType files — **internal test material only**, ignore-globbed and kept out of every archive | all rights reserved |
| `licenses/` | the licence texts of the flat and the `google/` faces, named after the family | — |

**Noto Color Emoji is here but does not travel.** `google/NotoColorEmoji-Regular.ttf`
is a 25 MB OFL face kept in the working tree for example `02.18` and the colour-font
measurements. It is listed in `.fossil-settings/ignore-glob` and excluded in
`tools/archive.sh`, so it reaches neither a commit nor any archive — the example
skips itself where the file is absent and says where to get it. Its licence text
`licenses/NotoColorEmoji-OFL.txt` does travel: a reader of the source tarball
therefore finds terms for a file that is not in it, which is the harmless
direction of that mismatch and better than the other one.

The licences live in `licenses/` rather than beside each file because the OFL
requires the text to travel with the fonts and a folder of nineteen texts,
fifteen of them named `OFL.txt`, would not say which is which; the sets (`urw-core35-fonts/`,
`adobe-afm/`) carry their own, as their sources ship them.

`adobe-afm/` is not example data at all and is the one thing here that the
**build** depends on: the fourteen Adobe core font metrics `afmData.tcl` is
generated from. It sits under `fonts/` because that is where a reader looks for
it, and it carries `LICENSE.txt`, which Adobe's terms forbid separating from the
metrics.

`urw-core35-fonts/` keeps its own licence files and its own notice, because it
is a **set** rather than a face — the fourteen URW faces that stand in for the
standard 14 when a document has to be archivable. Its own `NOTICE.md` carries
the origin, the licence choice and the two metric measurements.

Every family here was **read**, not assumed: `fsType`, the glyph count and the
character coverage come out of the files.

| File | Size | Glyphs | Chars | `fsType` | What it is for |
| --- | --- | --- | --- | --- | --- |
| `DejaVuSans.ttf` | 757 076 B | 6 253 | 5 918 | **0** | the workhorse — the only one here that covers Greek and Cyrillic |
| `DejaVuSans-Bold.ttf` | 705 684 B | 6 196 | 5 898 | **0** | its bold, so an example can show two faces staying apart |
| `google/Roboto-Regular.ttf` | 159 108 B | 1 326 | 927 | **0** | a plain text face, the counter-example to DejaVu's bulk |
| `google/BitcountPropSingle-Regular.ttf` | 331 076 B | 1 938 | 396 | **0** | a display face built from dots — visibly not a text font |
| `google/Niconne-Regular.ttf` | 42 056 B | 286 | 283 | **0** | a script face, and the one with **gaps**: no `č`, no `ą`, no Cyrillic |

`fsType 0` means installable, no restriction on embedding. No validator
enforces the field and no reader checks it — the responsibility sits with
whoever adds the file. tclpdf reads and reports it (stage 2) but does not
refuse on it.

### Where they come from and under what terms

| Family | Origin | Licence |
| --- | --- | --- |
| DejaVu | <https://github.com/dejavu-fonts/dejavu-fonts/releases> | Bitstream Vera (c) 2003 Bitstream Inc., Arev glyphs (c) Tavmjong Bah, DejaVu's own changes public domain |
| Roboto | Google Fonts, `googlefonts/roboto-classic` | **OFL 1.1**, (c) 2011 The Roboto Project Authors — no reserved font name |
| Bitcount Prop Single | Google Fonts, `petrvanblokland/TYPETR-Bitcount` | **OFL 1.1**, (c) 1980 The Bitcount Project Authors — no reserved font name |
| Niconne | Google Fonts | **OFL 1.1**, (c) 2011 Vernon Adams — **reserved font name**, spelt `Niconne` in the font (name ID 0) and `Nicone` in the licence text beside it |

All four permit redistribution as part of a larger package, which is this
case, and all four require the notices to travel along. That is what
`licenses/` is for, and it must not be tidied away.

> **Both spellings are in the tree, and that is the upstream state.** `licenses/Niconne-OFL.txt:2` reserves `Nicone`; the font's own copyright string (`name` ID 0, read with `ttx -t name`) reserves `Niconne`, which is also its family name (IDs 1 and 4) and the name a subset carries into a PDF. Neither file is edited here — a licence text is quoted, not corrected.
>
> **Niconne's reserved font name — settled 2026-08-10.** A subset is strictly
> speaking a modification, and the OFL forbids a modified version from carrying
> the reserved name. The six-letter prefix a PDF puts in front of every subset
> is the customary marking for exactly that, and tclpdf writes it: read out of
> `02.04-missing-glyphs.pdf`, the `/BaseFont` is `ZGNUBI+Niconne-Regular`. The
> face is redistributed here unmodified, with its licence beside it. That is
> the author's decision, and it is recorded rather than re-argued.
>
> Noticed while checking: the six-letter tag is derived from the font NAME, not
> from the glyph set (`font.tcl`, `FontBaseName`), so two documents carrying
> different subsets of the same face get the same tag. That is deliberate —
> the same input has to give the same bytes — but ISO 32000-1 9.9.2 intends
> the tag to tell subsets apart. Worth a decision of its own some day; it does
> not touch the licensing question above.

### What was dropped, and why

From DejaVu: the Serif, Mono, Condensed and ExtraLight faces, the obliques,
`DejaVuMathTeXGyre.ttf` and the fontconfig snippets — 8.4 MB no example needs.

From the three Google packages: the `static/` folders — 54 cuts for Roboto and 27 for Bitcount, which no example reaches.

> **The variable files went and came back, and the reason is worth keeping.** They were dropped once because PDF has nowhere to put an axis coordinate — no entry in the font dictionary, none in the descriptor — so embedding one could only yield its default instance, at the price of a `gvar` table no reader can use. Measured on Bitcount, that default is not even one of the shipped styles: its `CRSV` axis defaults to **0.5** while all 18 named instances sit at 0 or 1, so the outlines of `a` differ from *every* static file including Regular. The answer to that is instancing at EMBED time — reading `gvar` and interpolating, untouched points included — and it is built (`varFont.tcl`). **Eight of the eighteen faces in `google/` are variable today**, `font embed -instance` reaches a name the designer stood behind and `-axes` any point between; example `02.10` is about nothing else, and `02.09` embeds a second cut of Noto Sans out of the same file that way.

> Measured in passing: `DejaVuMathTeXGyre.ttf` carries **`fsType=12`**, which
> sets the "preview and print" and "editable" bits at the same time — a
> combination the specification treats as mutually exclusive. Not our problem
> here, since the file is gone, but a good reminder that the flag is worth
> reading rather than trusting.

---

## images/ — 354 KB, 24 files

One raster file per code path that stage 3 has to handle separately, plus the vector files for stage 6. Measured with `sips -g pixelWidth -g pixelHeight` over all ten raster files (the other fourteen are SVG): six are 640 × 480 (`sample-photo.jpg`, `sample-gray.jpg`, `sample-indexed.png`, `sample-rgba.png`, `sample-vignette.png`, `sample-scan.tiff`), `sample-stencil.png` is 300 × 300, the two colour-keyed PNGs are 96 × 96, and `erika-mustermann.jpg` is **420 × 540** — a passport photograph is upright and is not one of the generated ones.

**Origin, in one sentence per group.** Everything here was generated for this project and is free of third-party rights, with three exceptions that are named where they stand: `erika-mustermann.jpg` and `signature-mustermann.svg` are official German works in the public domain (see below), and `Tcl9logo.svg` is not ours at all.

| File | Size | What it really is | Exercises |
| --- | --- | --- | --- |
| `sample-photo.jpg` | 30 774 B | baseline JPEG (SOF0), **3 components**, YCbCr | DCTDecode pass-through — read the SOF header, never decode |
| `sample-gray.jpg` | 29 011 B | baseline JPEG (SOF0), **1 component** | the grey path, where `/DeviceGray` must be chosen instead of `/DeviceRGB` |
| `sample-indexed.png` | 11 269 B | PNG, 8 bit, **colour type 3** (palette) | `/Indexed` with the PLTE chunk carried over |
| `sample-rgba.png` | 40 215 B | PNG, 8 bit, **colour type 6** (RGBA) | the alpha path via `/SMask` — the one measured bottleneck (Paeth unfiltering) |
| `sample-stencil.png` | 1 507 B | PNG, **1 bit**, colour type 0 (greyscale), 300 × 300 | the stencil mask (`/ImageMask true`, ISO 32000-2, 8.9.6.2) — a picture with no colour space, painted in whatever fill colour is in force |
| `sample-scan.tiff` | 12 396 B | TIFF, 8 bit greyscale, 200 dpi, Deflate with predictor 2, `RowsPerStrip` 16 | the multi-strip case: a stateful compression restarts in every strip, so this one picture becomes **30** image XObjects stacked by the placement. Drawn here rather than taken from a real scan, and its sky is a smooth ramp because that is where a seam would show first |
| `sample-vignette.png` | 34 181 B | PNG, 8 bit, colour type 0 (greyscale), 640 × 480 | the mask a caller names (`-mask`) — reaches the file as the `/SMask` of another picture (11.6.5.2, Table 143: a soft-mask image is DeviceGray) |
| `sample-vector.svg` | 2 262 B | SVG 1.1 | stage 6, built — drawn by `03.03-svg.tcl` and read by `tests/svg.test` |
| `erika-mustermann.jpg` | 119 541 B | baseline JPEG (SOF0), 3 components, sRGB, **with an embedded ICC profile** (APP2, 3 160 B) — beside Exif, XMP and a Photoshop segment | the ICCBased path for pictures: the profile becomes the image colour space instead of the bare device name |
| `signature-mustermann.svg` | 14 754 B | SVG 1.1, one filled path with 10 contours | the appearance of a visible signature (stage 8) — public domain, see below |
| `sample-keyed.png` | 483 B | PNG, 8 bit, colour type 2 (truecolour), 96 × 96, with a `tRNS` chunk | the colour key: one transparent colour and no alpha channel, which reaches the file as `/Mask` with a colour range rather than as an `/SMask` |
| `sample-keyed16.png` | 5 572 B | the same picture at **16 bit** per sample, colour type 2, `tRNS` | the 16-bit key, which still passes through at 16 bits — the second timing on the page of `03.01` |
| `Tcl9logo.svg` | 4 745 B | SVG, the Tcl 9 logo | the picture of `00.02-hello-world-svg` — **not our work**, see below |
| `svg-*.svg` (eleven files) | 900–6 851 B | SVG 1.1 test patterns: `svg-paths`, `svg-arcs`, `svg-shapes`, `svg-transform`, `svg-gradient`, `svg-text`, `svg-inherit`, `svg-lexer`, `svg-reuse`, `svg-viewbox`, `svg-viewbox-origin` | stage 6, one construct group each, built so that a translation error shows in the picture without reading the source. `03.03-svg.tcl` draws the first four, `tests/structure.test` uses `svg-shapes`; the rest are pattern material |

The SVG uses `circle`, `clipPath`, `defs`, `g`, `linearGradient`, `path`,
`radialGradient`, `rect`, `stop` and `text` — deliberately the constructs that
decide whether SVG support is worth building: gradients map onto shading types
2 and 3, `clipPath` onto `W n`, and `text` is the one that needs a font.

`erika-mustermann.jpg` is the portrait from the same specimen — the passport photograph of the identity card of the Personalausweisverordnung, published by the Bundesministerium des Innern and in the public domain on the same grounds as the signature. Two things about it are worth knowing rather than assuming. It carries an ICC profile, so it exercises a code path the other JPEGs do not: `image embed` keeps the profile and writes `/ICCBased` instead of `/DeviceRGB`. And the sources disagree about who is in the picture: Wikimedia Commons calls the person fictitious, while the Wikipedia article on the name states that the photographs on these specimens show actual employees of the Bundesdruckerei. Nothing follows from that for the licence — an official work stays an official work — but a specimen portrait is not the place for the assumption that nobody is depicted.

`signature-mustermann.svg` is the signature of Erika Mustermann as it stands on the German identity card specimen — traced from the artwork of the Personalausweisverordnung of 1 November 2010 into filled paths. That artwork is part of an official regulation and therefore in the public domain under section 5 paragraph 1 of the German copyright act; Wikimedia Commons carries the specimen on the same grounds. Erika Mustermann is the placeholder person of German official documents and has been since 1983 — the name is a convention, not a person, and the signature is a specimen, not anyone's mark. It is a drawing here, not a photograph of a document: the file holds paths, so `examples/08.02-signature-visible.tcl` puts real vectors into the appearance stream of its signature field.

`Tcl9logo.svg` is the **logo of the Tcl project**, not a drawing made here — it is what `00.02-hello-world-svg.tcl` puts on the page, that example being the shortest program in the tree that draws a picture at all. Origin: the logo for Tcl/Tk 9.0, designed by Valerie Carroll (Carroll Graphics) in consultation with Steve Landers; the SVG is the one published at <https://cmacleod.me.uk/tcl/logo/>, unchanged. Terms: the Tcl wiki page that introduced it, <https://wiki.tcl-lang.org/page/A+logo+for+Tcl+9>, states "same license as Tcl" — the Tcl/Tk licence, <https://www.tcl-lang.org/software/tcltk/license.html>, a BSD-style licence that permits redistribution with its notice; no separate licence file ships with the logo, so none is copied here. The picture is used as the logo of the project whose language this package is written in, and nothing about it is claimed as this project's work.

**None of the six PNGs is interlaced** — read out of byte 13 of each `IHDR`, all zero. That is intentional: an interlaced PNG cannot be passed through and would have to be decoded and re-encoded, which is a different feature and not one stage 3 claims.

---

## xml/ — 27 KB, three files

Two invoices from **ZUGFeRD 2.5.2 (DE)**, chosen so that the profile detection
has something to distinguish, and one Order-X order written for this project. The identifier below is BT-24, read from
`GuidelineSpecifiedDocumentContextParameter` — the field tclpdf derives the
profile from with a single `regexp`, without needing an XML parser.

| File | Size | BT-24 | Why this one |
| --- | --- | --- | --- |
| `zugferd-minimum.xml` | 7 929 B | `urn:factur-x.eu:1p0:minimum` | the smallest valid case — good for a first attachment example |
| `zugferd-en16931.xml` | 12 056 B | `urn:cen.eu:en16931:2017` | the profile real business invoices use |
| `order-x-comfort.xml` | 6 815 B | `urn:order-x.eu:1p0:comfort` | the other document kind: an **order**, not an invoice, for example `05.13` — Order-X 1.0, COMFORT |

**Origin of the two invoices:** the official ZUGFeRD 2.5.2 DE distribution
(FeRD), directories `Beispiele/0. MINIMUM/MINIMUM_Rechnung/` and
`Beispiele/3. EN16931/E02_2_Teilrechnung/`, renamed here after their profile
because the original names say nothing about what distinguishes them.

**`order-x-comfort.xml` is the other case and carries no third-party terms.** It is not a copy of a published sample: it was written for this project against the Order-X 1.0 specification (Cross Industry Order, SCRDM CIO D20B), and the order it states is invented — the same order the page of `05.13` shows, which is the point of a hybrid document. It travels under the MIT licence of tclpdf like every other file written here; its own head says so.

**Licence: settled, and it travels inside the files.** There is no licence file
beside the examples in the FeRD distribution because there does not need to be:
each invoice carries the FeRD terms as an XML comment in its own head —
measured, **5 708 of the 7 929 bytes** in the MINIMUM file, 72 per cent of it.
Those terms grant free, irrevocable use of the data format including
redistribution, further development and commercial products.

**The block must not be stripped.** It is what makes these files
redistributable, and tclpdf embeds the XML byte for byte, so it reaches every
PDF built from them. When writing your OWN invoices, do not reproduce it: it
belongs to the sample file, not to the format, no schema asks for it, and at a
MINIMUM profile it would be most of the document.

The version in each head is the one the sample was cut from — `2.4.0` for
MINIMUM and `2.5.0` for EN 16931 — not the `2.5.2` of the distribution they
ship in.

The XML is read and embedded **byte for byte**. A silent line-ending
conversion in an attachment is something no validator reports — measured on the
reference corpus, 8 of 61 files differ from their published counterparts in
nothing but CRLF against LF.

---

## languages/ — 1.2 MB, and the one directory here that does **not** travel

Hyphenation patterns for `tclpdf::hyphenate`, German and American English, in
the libhyphen `.dic` format. Their own `README` carries the origin URL, the
version, the licence and the encoding of each file; read that one before
adding a third language.

They are the exception to everything the section above says about shipping.
`examples/assets/languages/` is listed in `.fossil-settings/ignore-glob` and
excluded in `tools/archive.sh`, exactly like `tools/Mustang-CLI-*.jar` — so
neither a commit nor **any** archive picks them up, the source one included.
The reason is the same one that keeps patterns out of the package itself:
`hyph_de_DE.dic` is LGPL over LPPL and `hyph_en_US.dic` BSD-style over the
plain TeX table, tclpdf is MIT, and the whole point of the loading interface is
that the licence stays with the file.

A fresh checkout therefore has this directory empty. `tests/hyphenate.test`
reports SKIP for the cases that need patterns and
`examples/01.14-hyphenation.tcl` sets its paragraphs unhyphenated and says so
on the page — nothing fails.

---

## Adding a file

Record it in the table above with: what it is (**measured**, not what the
extension claims), where it came from with a URL, and the licence by name. For
fonts, add the `fsType` value and what it permits.

tclpdf ships under the MIT licence, and everything under `examples/` travels in the **source** archive — with the three exclusions named above, which travel nowhere: `fonts/adobe-standard-14/`, `fonts/google/NotoColorEmoji-Regular.ttf` and `languages/`. (`examples/out/` and `examples/tmp/` are excluded as well, but those hold what a build produced and are not assets at all.) Nothing here reaches an installed package or either binary archive, and `make install` copies none of it. A file whose licence forbids even the source archive cannot stay, however convenient it is.
