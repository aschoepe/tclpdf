# Building the Download Packages

How to create the download packages for a new release and publish them
as unversioned files (uv) in the Fossil repository.

Starting point: the new version has been checked in and tagged
(e.g. `version-1.0`). The version number lives in two places that must agree:
`AC_INIT([tclpdf],[x.y])` in `configure.ac` and `package provide tclpdf x.y`
in `tclpdf.tcl`. `tests/version.test` fails if they drift apart, so
`make test` catches it before a release is built.

## Prerequisites

* A Fossil checkout of the release check-in:

      fossil update version-1.0

* The Fossil setting `manifest` must be enabled, so that the files
  `manifest` and `manifest.uuid` exist in the checkout and are kept
  up to date on every update:

      fossil settings manifest on

* A configured build directory (`./configure` has been run at least
  once), `tclsh`, `autoconf`, `zip` and `tar` in the PATH.

## 1. Build the packages

    make release

That is all. The target resolves its prerequisites automatically:

* `configure`, `Makefile` and `pkgIndex.tcl` are regenerated if
  `configure.ac` or their templates changed (so a version bump in
  `configure.ac` propagates without a manual `./configure` run),
* `manifest.txt` — the version and build information (check-in UUID,
  check-in date, release version) — is regenerated from `manifest`,
  `manifest.uuid` and `configure.ac` by `tools/mkversion.tcl`,
* `tools/archive.sh` then creates the artifacts in `uv/`:

| File                    | Content                                              |
|-------------------------|------------------------------------------------------|
| `tclpdf<x.y>.zip`        | Installable package: Tcl sources, `pkgIndex.tcl`, `manifest.txt` |
| `tclpdf<x.y>.tar.gz`     | Same content as the zip                              |
| `tclpdf<x.y>-src.tar.gz` | Complete source tree (without build artifacts)       |
| `download.html`         | Download page, generated from `template-download.html` (skipped if that template is absent) |

The archives are created without macOS metadata (AppleDouble files,
extended attributes, `.DS_Store`).

Check the result before publishing, e.g.:

    unzip -l uv/tclpdf<x.y>.zip
    tar tzf uv/tclpdf<x.y>.tar.gz

## 2. Publish as Fossil unversioned files

    make publish

This uploads the four artifacts into the uv space of the repository
(`fossil uv add ...`), syncs them to the server (`fossil uv sync`) and
shows the resulting file list (`fossil uv list`).

The packages are then available for download at
<https://fossil.sowaswie.de/tclpdf>.

## Notes

* `make archive` still exists as the bare packaging step; `make
  release` is `archive` plus the dependency chain and a summary.
* `afmData.tcl` is generated, and reproducing it needs nothing but a
  checkout and the Adobe AFM files:

      tclsh tools/mkafm.tcl <afm-directory> > afmData.tcl

  The glyph list it needs sits in `tools/agl/glyphlist.txt`. Until
  2026-08-13 the generator took that table as a second argument and
  read it out of a pdf4tcl installation - an outside dependency that
  appeared nowhere except in an unnamed `argv` parameter. The output
  is byte-identical either way; that was how the change was accepted.
* `tools/archive.sh` is not meant to be called directly; it expects
  `PACKAGE_NAME PACKAGE_VERSION PKG_TCL_SOURCES...` as arguments and
  exits with a usage message otherwise.

## Troubleshooting

* **`can't open file manifest.uuid`** (from `mkversion.tcl`) — the
  Fossil `manifest` setting is off; enable it as described under
  Prerequisites.
* **`make: *** No rule to make target 'release'`** — the `Makefile`
  in the build directory predates this target; run `./configure`
  once to regenerate it.
* **Wrong version in the archive names** — the checkout is not on the
  release check-in (`fossil status`), or `configure.ac` does not
  carry the new version yet.
