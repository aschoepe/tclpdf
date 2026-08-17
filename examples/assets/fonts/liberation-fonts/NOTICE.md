# Liberation Fonts 2.1.5 — origin, licence, what was measured

The twelve `.ttf` files here are the release archive
`liberation-fonts-ttf-2.1.5.tar.gz` of the Liberation Fonts project,
<https://github.com/liberationfonts/liberation-fonts/releases/tag/2.1.5>,
downloaded 2026-08-17, sha256 of the archive
`7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0`, unpacked
without change; `LICENSE`, `AUTHORS` and `README.md` are the project's own
files from the same archive. Not taken: `ChangeLog`, `TODO`.

## Licence

SIL Open Font License 1.1 (`LICENSE`), with the Reserved Font Names
**Liberation** (Red Hat, Inc.) and **Arimo, Tinos, Cousine** (Google) — the
files are the Liberation 2.x designs, which derive from those three. The OFL
allows use, embedding and redistribution; a *modified* font may not carry a
reserved name. A subset embedded into a PDF is not a distributed font under a
new name — see `examples/assets/README.md`, where the same question was
settled for Niconne.

## Why they are here

They stand in for the standard 14 the way the URW Core 35 do, from a different
lineage: URW are metric copies of the PostScript faces (Helvetica, Times,
Courier), Liberation are metric copies of Arial, Times New Roman and Courier
New — the Microsoft core fonts that are themselves metric-compatible with the
PostScript three except for a handful of symbols. That difference is what the
measurement below shows.

## Measured — advance widths against the Adobe AFM (2026-08-17)

Every WinAnsi position with a width in the AFM (191 per face) compared with
the face's advance, scaled to 1000/em; "equal" means within half a unit
(`tests/font.test`, `font-13.x`, keeps these numbers):

| Liberation | stands in for | equal | differs at |
| --- | --- | --- | --- |
| Sans Regular / Bold / Italic / BoldItalic | Helvetica, -Bold, -Oblique, -BoldOblique | 186 / 186 / 186 / 186 | `¯ ± µ · ÷` |
| Serif Regular / Bold / Italic / BoldItalic | Times-Roman, -Bold, -Italic, -BoldItalic | 186 / 186 / 187 / 188 | `¯ ± µ · ÷` (Italic without `·`, BoldItalic without `µ ·`) |
| Mono Regular / Bold / Italic / BoldItalic | Courier, -Bold, -Oblique, -BoldOblique | 191 / 191 / 191 / 191 | — |

2255 of 2292 advances equal; the 37 that differ are five symbols where Arial
and Times New Roman were never Helvetica and Times: macron, plus-minus, micro
sign, middle dot, division sign. Running text sets to the same measure; a form
laid out on those five characters does not. For a metric copy of the
PostScript faces themselves, `urw-core35-fonts/` (measured 2592 of 2592).
