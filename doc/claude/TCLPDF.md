# TCLPDF

Reusable prompt for writing Tcl that creates PDFs with **tclpdf** - from the reference code of the skill `tclpdf-tcl`, not from recollection. The skill lives beside this file in `skills/tclpdf-tcl/`; this page is its long form: how to install it in a project, the prompt itself, and why it exists.

## Why a reference, not a memory

A PDF library is a large surface with a small number of load-bearing conventions, and a model that has seen jsPDF, ReportLab, FPDF and pdf4tcl carries all of their conventions at once. What comes out is plausible tclpdf that is wrong in the same few places every time: y measured from the bottom, `-at` taken for the centre of a rectangle, `-size` given in millimetres, a `-style bold` expected to apply to `Times-BoldItalic`, a table cell string that starts with `text` and is read as a dictionary, a gradient defined on the page and used inside a form, a paragraph whose return value is read as a number when it was a dictionary. None of these is a bug in the package; each is a place where the package decided differently from the library the model remembers - and tclpdf refuses most of them at the call, with a message that names the fix, so the cost is a stalled turn rather than a broken file.

The reference files hold one working snippet per documented call, kept runnable by `check.tcl` against the package as it is. The instruction to the model is therefore short: **copy the snippet, then adapt.** Where the reference and the model's memory disagree, the reference wins; where the reference and the manual disagree, the manual wins and the reference is wrong.

## Why it ships with the source

`doc/claude/` travels in the source archive, and that is the point: whoever fetches tclpdf gets a **checked** skill for writing their own PDFs along with the package it describes. Checked is meant literally - `check.tcl` runs on the recipient's machine against the assets in `examples/assets`, so the snippets are not a promise made here but something the reader can verify there, against the version they actually have. `make check` runs the same thing as section 10 of the acceptance, which is why the two cannot drift apart.

It sits under `doc/` rather than `.claude/` for the same reason: `.claude/` is this working copy's own agent configuration and is excluded from every archive, while `doc/` is what the package hands out. A project that wants the skill copies it from there into its own `.claude/skills/`.

## Installing the skill in a project

1. Copy `skills/tclpdf-tcl/` to `<project>/.claude/skills/tclpdf-tcl/` (or wherever the agent loads skills from). Nothing in it refers to a path outside the directory except through `assets.tcl` and the one guarded macOS path in `02-fonts.md` - `/System/Library/Fonts/Apple Color Emoji.ttc`, which no licence lets this package ship, so the snippet asks `file exists` first and says on its own line that it skipped itself.
2. Edit `assets.tcl`: the font, image, ICC, XML and hyphenation files the snippets refer to, the output directory, and - if the package is not installed - `lappend auto_path` to where `pkgIndex.tcl` sits. The variable names are the contract with the reference files; the values are the project's. `$hyphenPatterns` is the one that may point at nothing: the package ships no pattern files, and the reference checks before it uses them.
3. Run `tclsh check.tcl assets.tcl`. Every reference file has to PASS, `qpdf --check` has to be silent, and veraPDF has to report 0 failed checks on the files that claim PDF/A or PDF/UA. A SKIP means a tool is missing, not that a check passed. `qpdf --check` has one tolerated complaint and only one - the `/Length` warning it raises on every revision 6 encrypted file, which `check.tcl` matches by name. Four snippets say on their own console line that they did less than they could: `11-encryption-signatures.md` without `openssl` on the PATH leaves its signatures unfilled, `03-text.md` without a pattern file skips the hyphenation section, `02-fonts.md` skips the `sbix` section on every machine that is not a Mac with Apple Color Emoji, and `05-images-svg.md` skips the barcodes without `tzint`. All still PASS - what they demonstrate is the call, and where the machine cannot make the call the snippet says so instead of pretending.
4. Put that command where the project runs its checks. A snippet that stops running after a package update is a snippet a reader will copy and fail with - and so is a refusal that stops being one, which is why every `catch` and `try` in the reference carries a branch printing `NOT REFUSED`, why `check.tcl` treats that line as a failure, and why it counts the two against each other before it runs anything.

## The prompt

```
You are writing Tcl that creates PDF documents with the tclpdf package.

Before writing any tclpdf call, open the skill "tclpdf-tcl" and take the
snippet for that call from its reference files (reference/01-document.md
through reference/13-form-fields.md). Copy the snippet, then adapt it.
Do not write a tclpdf call from memory of jsPDF, ReportLab, FPDF, pdf4tcl
or any other PDF library - the option names, the coordinate origin, the
unit of -size and the refusals differ, and the same mistakes come back
every time (SKILL.md, "Traps").

The rules that decide most calls:
- $doc is created with [tclpdf new -unit mm] (mm, A4, portrait, PDF 1.7);
  [$doc page add] before drawing; [$doc write path] at the end.
- y counts from the TOP; -at is the top left corner - except circle and
  ellipse and arc, where it is the centre. Font -size is always in POINTS.
- [font] sets state that stays; every text call also takes the options
  per call. text without -width is one line and returns nothing; with
  -width it is a paragraph and returns the y below; with -height it
  returns a dictionary {y rest}; with -paginate 1 it adds pages itself.
- Everything is checked at the call and refused with a message that names
  the fix. When a call is refused, read the message and change the call -
  do not catch the error and carry on, do not lower the claim.
- save/restore bracket clip, transform, opacity, blend and style.
- A pattern belongs to the content stream it was made in: define a
  gradient INSIDE the form that uses it; under a transform pass the
  returned matrix as -matrix.
- Tagged PDF: [$doc tagged 1] before anything is drawn; -tag H1 for
  headings; -alt or -artifact 1 on every picture; structure Type -script
  for grouping.
- Claims are explicit: pdfa, ua, zugferd. They need every face embedded
  (the standard fourteen are out), a title and a language, colours that
  fit the output intent, and tdom for the XMP packet.
- encrypt and sign are declared the same way and are refused together;
  encrypt comes before anything is DRAWN and before language and link
  (an empty page add may already stand), needs -version 2.0, and
  excludes every PDF/A claim. tclpdf never holds a key: a signature
  comes from a -signer command prefix that answers a CMS object in DER.
- A VISIBLE signature is a form field: under tagged 1 it gets a Form
  element and an object reference, sign -tooltip writes its /TU and
  sign -contents its /Contents, and a PDF/UA claim asks for them. An
  INVISIBLE one - the default, /Rect [0 0 0 0] - is an artifact and is
  asked nothing. ::tclpdf::sign add refuses a file that claims PDF/UA
  (TCLPDF SIGN STATE ua): sign the document as it is written instead.
- Whatever addresses a FINISHED file - pdf import, ::tclpdf::pdf info,
  ::tclpdf::update open, ::tclpdf::sign digest/embed/add - refuses an
  encrypted one (pdf info is the exception), and each of the package
  commands needs its own package require: tclpdf::importInfo,
  tclpdf::update, tclpdf::sign, tclpdf::hyphenate.
- tclpdf ships no hyphenation patterns; the caller loads a libhyphen .dic
  with ::tclpdf::hyphenate load before -hyphenate can be asked for.

When the document claims PDF/A, PDF/UA or is a hybrid invoice, say how it
is validated: qpdf --check, verapdf -f <the claimed flavour> or --flavour
ua1/ua2, and Mustang for ZUGFeRD/Factur-X/Order-X; pdfsig for a signed
file and qpdf --show-encryption for an encrypted one. "It opens in a
viewer" is not a check.

The manual (tclpdf.md / tclpdf.n) is the authority where the reference
and your memory disagree; the reference is the authority where the manual
is silent about the idiom. Name the file and section you copied from when
the user asks why a call looks the way it does.
```

## What the skill is not

It is not the manual: it does not describe options exhaustively, it shows one working call per feature and points at the manual for the rest. It is not a validator: nothing in it replaces `qpdf`, veraPDF, Mustang and `pdfsig`, and it says so at every claim. It holds no key and verifies no signature either - what a signature is worth is decided by the trust store of whoever opens the document. And it is not a way round the refusals: tclpdf refusing a call is the design - a missing glyph, a colour the output intent does not admit, a mixed-direction line - and the right answer to a refusal is a different call, never `catch`.

## Keeping it current

The reference follows the manual. When a call gains an option, when a refusal changes its wording, when a new module lands, the corresponding reference file gets its snippet and `check.tcl` proves it runs. Two rules make that cheap: every reference file is **one** script top to bottom, so a change is tested by running the file; and the snippets refer to assets only through the variables of `assets.tcl`, so nothing in them is bound to one machine.

The trap list in `SKILL.md` is the other half. It grows from what actually went wrong - a call written wrong twice is a trap, whether or not it is in the manual - and it shrinks when the package changes so that a mistake can no longer be made.
