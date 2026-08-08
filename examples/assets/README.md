# Example assets

Fonts, images and invoice data used by the scripts in `examples/`. Kept apart
from the scripts so that `examples/` stays a plain list of what there is to
look at.

Every entry below was **measured, not assumed** — the file type, the colour
type, the embedding flag and the profile identifier were read out of the files
themselves. What a file is named is not evidence of what it contains, and an
example that quietly demonstrates the wrong thing is worse than none.

```
fonts/     one family, two weights, to embed and subset      (stage 2)
images/    JPEG and PNG covering each code path, plus SVG    (stages 3 and 6)
xml/       two ZUGFeRD profiles, to attach and to detect     (stage 5)
```

The sRGB ICC profile does **not** belong here. It is not example data but part
of the package — it goes to `icc/` at the top level and is installed with it.

---

## fonts/ — 1.4 MB

DejaVu, reduced from the 22 faces of the release to the two an example needs:
a regular and a bold of the same family. That pair is what a real document
uses — a heading in bold, the body in regular — and it is what shows that
subsetting keeps two faces apart.

| File | Size | `fsType` | Meaning |
| --- | --- | --- | --- |
| `DejaVuSans.ttf` | 757 076 B | **0** | Installable — no restriction on embedding |
| `DejaVuSans-Bold.ttf` | 705 684 B | **0** | Installable — no restriction on embedding |
| `LICENSE` | 8 816 B | — | required, see below |
| `AUTHORS` | 842 B | — | required, see below |

**Origin:** <https://github.com/dejavu-fonts/dejavu-fonts/releases>

**Licence:** Bitstream Vera Fonts Copyright (c) 2003 Bitstream, Inc., plus the
Arev glyphs (c) Tavmjong Bah; the DejaVu changes themselves are public domain.
The licence permits redistribution as part of a larger software package, which
is exactly this case — but it requires the copyright notices to travel along,
which is why `LICENSE` and `AUTHORS` stay here and must not be tidied away.

**Why `fsType` is recorded here:** it is the field in which the vendor states
what embedding is permitted, and `0` means unrestricted. No validator enforces
it and no PDF reader checks it — the responsibility sits with whoever adds the
file. tclpdf reads and reports the flag (stage 2) but does not refuse on it.

Dropped from the release: the Serif, Mono, Condensed and ExtraLight faces, the
oblique variants, `DejaVuMathTeXGyre.ttf`, the fontconfig snippets and the
coverage tables. Together 8.4 MB that no example needs.

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

**Licence: not yet established** — see `docs/TODO.md`. The FeRD distribution
carries no licence file next to the examples. Until that is settled these two
files must not go into a release archive.

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
