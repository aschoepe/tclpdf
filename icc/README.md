# ICC profile

`sRGB.icc` — the output intent profile for PDF/A-3 and therefore for ZUGFeRD.

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
