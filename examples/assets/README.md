# Example assets

Fonts, images and invoice data used by the scripts in `examples/`. Kept apart
from the scripts so that `examples/` stays a plain list of what there is to
look at.

Every entry below was **measured, not assumed** — the file type, the colour
type, the embedding flag and the profile identifier were read out of the files
themselves. What a file is named is not evidence of what it contains, and an
example that quietly demonstrates the wrong thing is worse than none.

```
fonts/     four families, five faces, plus their licences    (stage 2)
images/    JPEG and PNG covering each code path, plus SVG    (stages 3 and 6)
xml/       two ZUGFeRD profiles, to attach and to detect     (stage 5)
```

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
terms with them in `fonts/licenses/`, and they reach nobody who merely installs
the package. A font only becomes the user's licensing question when the user
embeds one of their own — which is why tclpdf reads `fsType` and reports it.

**Adding an asset means checking that side too:** an example is worth nothing
if the file it needs may not be redistributed. The two ZUGFeRD invoices below
are the standing example of how to answer that — the terms turned out to be
inside the files themselves, so they travel in the source archive like
everything else here.

---

## fonts/ — 1.9 MB

Four families, one face each except DejaVu, which keeps a bold as well. Flat,
because every example wants a short path, with the licences in `licenses/`
named after the family they belong to — the OFL requires the text to travel
with the fonts, and a folder of five files named `OFL.txt` would not say which
is which.

Every family here was **read**, not assumed: `fsType`, the glyph count and the
character coverage come out of the files.

| File | Size | Glyphs | Chars | `fsType` | What it is for |
| --- | --- | --- | --- | --- | --- |
| `DejaVuSans.ttf` | 757 076 B | 6 253 | 5 918 | **0** | the workhorse — the only one here that covers Greek and Cyrillic |
| `DejaVuSans-Bold.ttf` | 705 684 B | 6 196 | 5 898 | **0** | its bold, so an example can show two faces staying apart |
| `Roboto-Regular.ttf` | 159 108 B | 1 326 | 927 | **0** | a plain text face, the counter-example to DejaVu's bulk |
| `BitcountPropSingle-Regular.ttf` | 331 076 B | 1 938 | 396 | **0** | a display face built from dots — visibly not a text font |
| `Niconne-Regular.ttf` | 42 056 B | 286 | 283 | **0** | a script face, and the one with **gaps**: no `č`, no `ą`, no Cyrillic |

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
| Niconne | Google Fonts | **OFL 1.1**, (c) 2011 Vernon Adams — **reserved font name**, written `Nicone` in the file |

All four permit redistribution as part of a larger package, which is this
case, and all four require the notices to travel along. That is what
`licenses/` is for, and it must not be tidied away.

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

From the three Google packages: the `static/` folders (54 faces for Roboto, 27
for Bitcount) and the **variable font files**. That took the folder from 20 MB
back to 1.9 MB, and the source archive from 8.2 MB back to about 1.5 MB.

> **Why the variable fonts went:** PDF has nowhere to put an axis coordinate —
> no entry in the font dictionary, none in the descriptor. Embedding
> `Roboto-VariableFont_wdth,wght.ttf` therefore yields the default instance and
> nothing else, at the price of a 298 KB `gvar` table that no reader can use.
> Measured on Bitcount, that default is not even one of the shipped styles: its
> `CRSV` axis defaults to **0.5** while all 18 named instances sit at 0 or 1,
> so the outlines of `a` differ from *every* static file including Regular.
> Supporting variable fonts means instancing them at embed time — reading
> `gvar` and interpolating, including untouched points. That is a stage of its
> own, and it is not this one.

> Measured in passing: `DejaVuMathTeXGyre.ttf` carries **`fsType=12`**, which
> sets the "preview and print" and "editable" bits at the same time — a
> combination the specification treats as mutually exclusive. Not our problem
> here, since the file is gone, but a good reminder that the flag is worth
> reading rather than trusting.

---

## images/ — 120 KB

Generated for this project, free of third-party rights. Four raster files, one
per code path that stage 3 has to handle separately, and one vector file for
stage 6. All raster images are 640 × 480.

| File | Size | What it really is | Exercises |
| --- | --- | --- | --- |
| `sample-photo.jpg` | 30 774 B | baseline JPEG (SOF0), **3 components**, YCbCr | DCTDecode pass-through — read the SOF header, never decode |
| `sample-gray.jpg` | 29 011 B | baseline JPEG (SOF0), **1 component** | the grey path, where `/DeviceGray` must be chosen instead of `/DeviceRGB` |
| `sample-indexed.png` | 11 269 B | PNG, 8 bit, **colour type 3** (palette) | `/Indexed` with the PLTE chunk carried over |
| `sample-rgba.png` | 40 215 B | PNG, 8 bit, **colour type 6** (RGBA) | the alpha path via `/SMask` — the one measured bottleneck (Paeth unfiltering) |
| `sample-vector.svg` | 2 262 B | SVG 1.1 | stage 6, deferred |

The SVG uses `circle`, `clipPath`, `defs`, `g`, `linearGradient`, `path`,
`radialGradient`, `rect`, `stop` and `text` — deliberately the constructs that
decide whether SVG support is worth building: gradients map onto shading types
2 and 3, `clipPath` onto `W n`, and `text` is the one that needs a font.

Neither PNG is interlaced. That is intentional: an interlaced PNG cannot be
passed through and would have to be decoded and re-encoded, which is a
different feature and not one stage 3 claims.

---

## xml/ — 20 KB

Two invoices from **ZUGFeRD 2.5.2 (DE)**, chosen so that the profile detection
has something to distinguish. The identifier below is BT-24, read from
`GuidelineSpecifiedDocumentContextParameter` — the field tclpdf derives the
profile from with a single `regexp`, without needing an XML parser.

| File | Size | BT-24 | Why this one |
| --- | --- | --- | --- |
| `zugferd-minimum.xml` | 7 929 B | `urn:factur-x.eu:1p0:minimum` | the smallest valid case — good for a first attachment example |
| `zugferd-en16931.xml` | 12 056 B | `urn:cen.eu:en16931:2017` | the profile real business invoices use |

**Origin:** the official ZUGFeRD 2.5.2 DE distribution (FeRD), directories
`Beispiele/0. MINIMUM/MINIMUM_Rechnung/` and
`Beispiele/3. EN16931/E02_2_Teilrechnung/`, renamed here after their profile
because the original names say nothing about what distinguishes them.

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

## Adding a file

Record it in the table above with: what it is (**measured**, not what the
extension claims), where it came from with a URL, and the licence by name. For
fonts, add the `fsType` value and what it permits.

tclpdf ships under the MIT licence, and everything under `examples/` ships with
it — in the archive, in the installed package and in the repository. A file
whose licence forbids that cannot stay, however convenient it is.
