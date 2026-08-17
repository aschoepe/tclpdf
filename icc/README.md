# ICC profiles

`sRGB.icc` — the output intent profile for PDF/A-3 and therefore for ZUGFeRD; the default of `pdfa`. `ISOcoated_v2_bas.ICC` — a CMYK output intent for print work, `ISOcoated_v2_grey1c_bas.ICC` — a grey one for monochrome documents, and `sRGB2014.icc` — the ICC's own, newer sRGB profile, kept beside the default so that the two can be compared (examples 05.11 and 05.12); all below.

This is **not** example data. PDF/A requires the output intent profile to be
**embedded in every document**, so the file is part of the package: it is
installed with it and it ships in the binary archive.

## What this file is — read out of the file, not assumed

| | |
| --- | --- |
| Size | 6 922 B |
| sha256 | `2a92d4bae450b76d8b0aa42193df974d75f62738ecebf74f01c5e75b12a95796` |
| Signature | `acsp` — a valid ICC profile |
| Version | 2.3.0 |
| Class | `mntr` (display), the usual class for an sRGB output intent |
| Colour space | RGB → XYZ |
| `desc` tag | `sRGB` |
| `cprt` tag | **`no copyright, use freely`** |

Origin: the `icc-profiles-free` collection, Zlib licence. The copyright tag in
the file itself says "no copyright, use freely" — that is why this profile was
chosen, and it is what makes shipping it with an MIT-licensed package sound.

Several sRGB profiles are in circulation and they are not interchangeable:
they differ in size, in licence and in the copyright notice they would embed
into every document produced. Identify this one before trusting it:

```sh
shasum -a 256 sRGB.icc      # must match the hash above
strings sRGB.icc | grep -i copyright
```

## Evidence that this profile works

The same file, embedded as an output intent by the preliminary browser
implementation, produced **61 of 61 PASS in veraPDF** (1.30.2) and 61 of 61
valid on the Mustangproject PDF layer.

## When it changes

Never silently. The profile bytes end up inside every document, so a different
file means different output for every user, and a different copyright notice
in every invoice. If it is ever replaced, the table above has to be
re-measured — size, hash, class and both tags — and the change belongs in the
check-in comment.

## `ISOcoated_v2_bas.ICC` — the CMYK output intent (added 2026-08-17)

Not a default: `pdfa -profile icc/ISOcoated_v2_bas.ICC` selects it. It exists so
that a document whose colour is CMYK — a print job, a letterhead in process
colours — can claim PDF/A with an intent that describes its colours, and so
that this case is tested (tests/xObject.test) and shipped as an example
(examples/05.09-pdfa-cmyk.tcl) rather than depending on whatever profile the
build machine happens to have.

| | |
| --- | --- |
| Size | 1 052 608 B |
| sha256 | `7cdd1a643a1703fe62c30cd0cd2aba0fb01ae8d5a1ac985c8f8964ff73e4fae0` |
| Signature | `acsp`, version 2.1.0, class `prtr` (output), colour space `CMYK` |
| `desc` tag | `ISO Coated v2 (basICColor)` — FOGRA39 characterisation |
| `cprt` tag | `basICColor CMYKick v1.2 - Copyright (c) 2006-2007 Color Solutions, All Rights Reserved.` |
| Licence | **zlib/libpng**, granted in the file `LICENSE-ZLIB-bICC` beside it, not in the profile itself |

Origin: basICColor GmbH's public profile set, as shipped by Debian in
`icc-profiles-free` 2.4 (`icc-profiles-basiccolor-printing2009`); the copy here is
byte-identical to the Debian source. The `cprt` tag inside the file still
carries the older all-rights-reserved notice — the redistribution grant is the
zlib licence in `LICENSE-ZLIB-bICC`, which basICColor issued for exactly these
files ("changed its public profiles licenses to the OSI compatible libz/libpng
licenses", openicc list, 2010). The two files travel together; the licence
notice may not be removed.

Why this one and not another: the ECI profiles (ISO Coated v2, PSO Coated v3)
may be used but not redistributed without written permission; Ghostscript's
`default_cmyk.icc` is AGPL; the Idealliance CGATS21 profile is redistributable
but 3.5 MB. This is the smallest one with a licence compatible with MIT.

Measured: as the output intent of a PDF/A-3b document veraPDF 1.30.2 reports
0 failed checks; the identifier tclpdf writes from its `desc` tag is
`ISO Coated v2 (basICColor)`.

## `ISOcoated_v2_grey1c_bas.ICC` — the grey output intent (added 2026-08-17)

The third intent, for a document that paints in grey only — a monochrome
archival copy, a form without colour. Under it PDF/A admits DeviceGray alone
(ISO 19005-2, 6.2.4.3), which `pdfa` checks at the write. It exists so that the
GRAY branch of that check is held against a real profile rather than a
synthetic header (tests/zugferd.test 8.9 and 8.12, example 05.10).

| | |
| --- | --- |
| Size | 936 B |
| sha256 | `2dde48d5589b93a59c4514fd292f7037d08bc1b37ef728655be4965aeee57cbe` |
| Signature | `acsp`, version 2.1.0, class `prtr`, colour space `GRAY` |
| `desc` tag | `ISO Coated v2 - GREY 1c - (basICColor)` — the grey component of the same FOGRA39 characterisation |
| `cprt` tag | `basICColor - Copyright (c) 2007 Color Solutions, All Rights Reserved.` |
| Licence | zlib/libpng, the same grant in `LICENSE-ZLIB-bICC` — the file is part of the same basICColor set as the CMYK profile above |

Origin: Debian `icc-profiles-free` 2.4, `icc-profiles-basiccolor-printing2009`,
byte-identical to the Debian source. Measured: a grey document with it as the
intent passes veraPDF 3b with 0 failed checks; the same document with an RGB
or a CMYK fill fails on 6.2.4.3-2 or -3 — exactly what `pdfa` refuses.

## `sRGB2014.icc` — the ICC's sRGB profile, beside the default (added 2026-08-17)

Not the default: `pdfa -profile icc/sRGB2014.icc` selects it. It is here so
that the choice of the default can be seen rather than believed — examples
05.11 (default `sRGB.icc`) and 05.12 (`sRGB2014.icc`) write the same page under
each and print what the profile bytes say.

| | `sRGB.icc` (default) | `sRGB2014.icc` |
| --- | --- | --- |
| Origin | OpenICC, Kai-Uwe Behrmann, 2004 | International Color Consortium, 2015 — successor of `sRGB_IEC61966-2-1_black_scaled.icc` |
| Size on disk | 6 922 B | 3 024 B |
| Size in the PDF (Flate stream) | **2 449 B** | **2 553 B** — the older profile's 1024-point curves compress well; the disk sizes mislead |
| sha256 | `2a92d4bae450b76d8b0aa42193df974d75f62738ecebf74f01c5e75b12a95796` | `384b832de3412066743b52a75ee906b6fb9fb8d9e09e936fc2c43223815c6e0a` |
| Version, class | 2.3, `mntr` | 2.0, `mntr` |
| White point tag | D65 (0.9501 1 1.0883), no `chad` | D50 (0.9642 1 0.8249) with `chad` (Bradford D65→D50), as v4 requires and v2 recommends |
| Black point | no `bkpt` | `bkpt`, scaled to zero — hence the old name |
| Other tags | `chrm`, `dmnd`, `dmdd` | `lumi`, `meas`, `tech`, `vued` |
| Primaries, tone curve | identical to within 0.0002; the same 1024-point curve | |
| `desc` | `sRGB` | `sRGB2014` |
| `cprt` | `no copyright, use freely` | `Copyright International Color Consortium, 2015` |
| Licence | Zlib | ICC — copy, embed, sell without restriction; do not alter under the name (`LICENSE-ICC.txt`) |

Measured 2026-08-17: a ZUGFeRD invoice with `sRGB2014.icc` as its intent
passes veraPDF 3b with 0 failed checks. Under relative rendering the two are
the same colours; the D50 tag with `chad` matters to the absolute colorimetric
intent only. Why the default is still the OpenICC file: it was chosen for its
licence and its 61-of-61 record and has never given a reader trouble; in the file
the two are within a hundred bytes of each other, and they differ by whose
copyright line sits in the document.
