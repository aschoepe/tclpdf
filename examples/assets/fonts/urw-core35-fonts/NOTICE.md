# URW Core 35, and what tclpdf keeps of it

Fourteen faces out of thirty-eight, in all four formats. What was removed and
why is below; the fonts themselves are untouched.

## Where these files come from

<https://github.com/twardoch/urw-core35-fonts>, an archive of URW++'s
Version 2.0 originals. `README.md` next to this file is the one that came with
them - it describes the contents as URW++ Version 2.00 and records the licence
history, including that URW++ released **the same Version 2.0 fonts in 2017
under LPPL 1.3c and under SIL Open Font License 1.1, without a Reserved Font
Name clause**, in addition to the AGPL v3 release of 2016.

The same fonts are packaged by the distributions - on Debian and its
derivatives as `fonts-urw-base35`
(<https://packages.debian.org/stable/fonts/fonts-urw-base35>), described there
as "metric-compatible with the 35 PostScript Level 2 Base Fonts". Anyone who
would rather not take font files out of a repository has that route, and it is
the shorter one on a Linux machine.

One caveat worth knowing rather than discovering later: that repository
describes itself in two ways. Its GitHub description says "Fork of defunct
URWTypeFoundry/Core_35"; its README says "Nothing here is a fork or a re-hint.
These are the files as URW++ released them." The URW-owned repository no longer
exists, so the claim of unmodified originals cannot be checked against its
source.

## Licence

`LICENSE.md` states the terms and is kept verbatim: "Each licensee may choose
any one of these licenses to apply" - AGPL v3 with a font-embedding exemption,
LPPL 1.3c, or OFL 1.1. Copyright 2013, 2014, 2015 by (URW)++ Design &
Development.

**tclpdf takes the OFL 1.1.** It is the licence written for bundling typefaces
with software, it is what the other fonts beside this directory already use,
and without a Reserved Font Name nothing here has to be renamed. All four
licence files are kept anyway, because the choice belongs to whoever receives
the files, not to whoever passed them on.

Measured, not assumed: `fsType` is **8** in all fourteen - editable embedding,
no restriction that would stand in the way.

## Why fourteen and not thirty-eight

These are the faces PDF calls the standard 14 (ISO 32000-1 9.6.2.2), and they
are a subset of the base 35: Helvetica, Times and Courier with four styles
each, plus Symbol and ZapfDingbats. The remaining twenty-four - Palatino,
Bookman, Avant Garde, Century Schoolbook, Helvetica Narrow, Zapf Chancery -
have no counterpart in PDF and nothing here would reach for them.

| Standard 14 | URW file |
| --- | --- |
| Helvetica, -Bold, -Oblique, -BoldOblique | `NimbusSans-Regular`, `-Bold`, `-Oblique`, `-BoldOblique` |
| Times-Roman, -Bold, -Italic, -BoldItalic | `NimbusRoman-Regular`, `-Bold`, `-Italic`, `-BoldItalic` |
| Courier, -Bold, -Oblique, -BoldOblique | `NimbusMonoPS-Regular`, `-Bold`, `-Italic`, `-BoldItalic` |
| Symbol | `StandardSymbolsPS` |
| ZapfDingbats | `D050000L` |

## Why all four formats

`.ttf` is what tclpdf can embed today. The other three are here because each
has a named reader waiting for it, and because having one face in four formats
is what makes those readers checkable at all:

* `.otf` carries the same outlines as CFF - stock for the day the package
  reads them.
* `.t1` is the same again as Type 1. It was dropped once, when Type 1
  embedding was on no list; it is on one now, and these files are better test
  material than any other in the tree, because the same face sits beside them
  as TrueType and as metrics. A Type 1 reader has to arrive at the widths the
  TrueType path already produces - that is an invariant nothing else offers.
* `.afm` is the manufacturer's own metric. It is what the comparison below was
  measured against, and re-running that comparison needs the files, not the
  result.

Dropped: `Core_35.pdf` (1.6 MB of specimen pages), the CI configuration, and a
validation script - none of it is font data. Also dropped are the twenty-four
faces the standard fourteen do not need.

## The point of having them: measured, both ways

The claim these fonts carry is metric compatibility with the Adobe originals.
That was checked twice, because the two halves can fail independently.

**The AFM files against `afmData.tcl`**: the generator `tools/mkafm.tcl` was
run a second time with the URW files in place of Adobe's, so the encoding path
was identical and only the source differed. Result: **2 983 of 2 984 mapped
byte positions identical**. Twelve of the fourteen faces agree on all 216
positions; ZapfDingbats on all 202. The single difference is Symbol at code
128, where URW has `apple` at width 790 and Adobe has nothing - a glyph more,
not a glyph missing.

**The TrueType advances against the standard faces**: measured through tclpdf
itself, every WinAnsi byte at size 1000, kerning and ligatures off on both
sides. Result: **2 592 of 2 592 advances identical**. The tolerance is half a
unit and it is needed: these files carry 2 048 units per em, so a width of 600
lands on 600.098 after the round trip. Nothing exceeded 0.2.

Each text face holds 859 glyphs and 854 characters - the same count for all
twelve, read out of `maxp` as well as through the package.

## What does not work yet

**Symbol and ZapfDingbats cannot be embedded.** `StandardSymbolsPS.ttf` and
`D050000L.ttf` carry only a `(3,0)` symbol cmap, and tclpdf requires a Unicode
one - `font embed` refuses them with "the font has no usable Unicode cmap".
The twelve text faces have `(0,3)`, `(1,0)` and `(3,1)` and embed without a
word.

This matters for exactly one case: a PDF/A document that uses Symbol or
ZapfDingbats cannot be made archivable by embedding these files. The other
twelve cover Helvetica, Times and Courier completely.
