% tclpdf(n) 1.0 | Tcl Package Documentation
% Alexander Schoepe
% 2026

# NAME

tclpdf - PDF generation for Tcl

# SYNOPSIS

**package require Tcl 8.6.11-**

**package require tclpdf 1.0**

# DESCRIPTION

**tclpdf** creates PDF documents from Tcl. It is a pure Tcl package: no
compiler, no binary extension, no Tk.

The package is being built in stages. This manual page documents what the
package actually provides; commands appear here as they are implemented.
The full planned scope, together with the measurements behind each decision,
is described in `docs/FEATURES.md` in the source distribution.

# REQUIREMENTS

Tcl 8.6.11 or newer. The package also runs under Tcl 9 — note that this
requires the open-ended form of the version requirement, since
`package require Tcl 8.6` is rejected by Tcl 9 with a version conflict.

The core needs nothing beyond Tcl itself. In particular **zlib** is a
built-in command rather than a package, so it must not be requested with
`package require`: the dummy package of that name exists only in Tcl 8.6.

**Tk is not required and is never loaded.** Two conveniences would pull it
in and are therefore avoided: resolving colour names via `winfo rgb`, and
decoding images via `image create photo`. tclpdf carries its own colour
table and its own image parsers.

# OPTIONAL PACKAGES

Each of the following enables exactly one feature and is needed for nothing
else. None of them is required to load tclpdf.

**tdom**

: SVG module.

**TclTLS**

: Encryption. `tls::encrypt` reaches roughly 256 MB/s where a pure-Tcl AES
  manages 0.22 MB/s, so without TclTLS encryption is unavailable rather
  than slow. Note that encryption and PDF/A are mutually exclusive: a
  conforming file must not carry an `Encrypt` entry in its trailer.

**tzint**

: Barcodes and QR codes.

# COMMANDS

The command set is documented here as the implementation progresses. See
`docs/FEATURES.md` for the planned order of work.

# SEE ALSO

qpdf(1), veraPDF, pdffonts(1), pdftotext(1)

# KEYWORDS

pdf, pdf/a, zugferd, factur-x, truetype, font embedding, invoice

# COPYRIGHT

Copyright (C) 2026 Alexander Schoepe, Bochum, DE

Distributed under the MIT License; see the file `license.terms`.
