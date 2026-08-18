% tclpdf(n) 1.1 | Tcl Package Documentation
% Alexander Schoepe
% 2026

# NAME

tclpdf - PDF generation for Tcl

# SYNOPSIS

**package require Tcl 8.6.11-**

**package require tclpdf 1.1**

# DESCRIPTION

**tclpdf** creates PDF documents from Tcl. It is a pure Tcl package: no compiler, no binary extension, no Tk.

What is documented below is what the package provides — nothing here is planned or partial. Roughly a third of ISO 32000-1 is covered, weighted by the page count of its chapters; the remainder is almost entirely what a **reader** of foreign PDFs needs rather than a writer, plus encryption and form fields.

# INSTALLATION

The release archives `tclpdf<version>.zip` and `tclpdf<version>.tar.gz` hold the same thing: one directory `tclpdf<version>` with the Tcl modules, `pkgIndex.tcl` and the ICC profiles in `icc/` — nothing to build. Extract it into a directory on the `auto_path` of your tclsh — the `lib` directory of the Tcl installation, or one you add with `lappend auto_path` — and `package require tclpdf` finds it. The source archive `tclpdf<version>-src.tar.gz`, and a checkout of the repository, carry the tests, the examples with their fonts, the manual sources and the tools besides; that one builds and installs the TEA way: `./configure`, `make test`, `make install`, in the source directory (see the README for the details and for `--prefix`).

# REQUIREMENTS

Tcl 8.6.11 or newer. The package also runs under Tcl 9 — note that this requires the open-ended form of the version requirement, since `package require Tcl 8.6` is rejected by Tcl 9 with a version conflict.

The core needs nothing beyond Tcl itself. In particular **zlib** is a built-in command rather than a package, so it must not be requested with `package require`: the dummy package of that name exists only in Tcl 8.6.

**Tk is not required and is never loaded.** Two conveniences would pull it in and are therefore avoided: resolving colour names via `winfo rgb`, and decoding images via `image create photo`. tclpdf carries its own colour table and its own image parsers.

# OPTIONAL PACKAGES

tclpdf loads and runs with nothing but Tcl 8.6.11 or later. One package matters, for two things:

**tdom** (0.9.0 or newer)

: **The metadata packet needs it**: the XMP is built with it, so every document that declares PDF/A, PDF/UA or ZUGFeRD needs tdom, and the module that writes those declarations refuses to load without it. A document that makes no such claim never loads that module and runs without tdom.

  The SVG module uses it for parsing where it is present, and prefers it: measured, tdom parses 27 to 48 times faster than the parser tclpdf brings along, and it rejects an entity expansion bomb that the built-in one would try to expand. Without tdom the package still reads SVG, through its own element tree parser — the same four accessors sit in front of both, so nothing else in the package can tell the difference.

There is no other optional package; barcodes need none either, because tzint encodes into SVG and `svg -data` draws it — see "Barcodes" below.

# COMMANDS

## Creating a document

**tclpdf new** ?*option value* ...?

: Creates a document object and returns its command name. Options: **-unit** (`mm`, the default, or `pt`, `cm`, `in`; `px` is also accepted and is the same as `pt`), **-format** (a page format name such as `a4`, or a pair of numbers in the document unit), **-orientation** (`portrait` or `landscape`; `hoch` and `quer` are also accepted), **-version** (`1.0` through `1.7`, or `2.0`; default `1.7`), **-compress** (`1` by default — content streams are deflated; `0` writes them plainly, which is for reading the output, not for shipping it) and **-typeArea** (the margins flowing text and breaking tables keep, `{top bottom}` or `{top bottom left right}` in the document unit; without it five percent of the page height top and bottom and of the page width at the sides — see **page typeArea**, **text -height max** and **table**; the margins are kept in the document unit and follow it: after **configure -unit pt** they are answered in points by **cget -typeArea** and **page typeArea** alike, and a **-typeArea** given in the same call as **-unit** is read in that unit). Every feature is checked against the version before it is written: an `opacity` in a document created with `-version 1.3`, a shading in a `1.2` file, an embedded font in a `1.1` file are refused with a message naming the feature and the version it needs (`opacity needs PDF 1.4 - this document is written as PDF 1.3`), rather than raised behind the caller's back — whoever set the version said what the file may contain. The version is never raised silently, with three exceptions that are claims rather than features: `pdfa` and `ua -part 1` lift the file to 1.7 and `ua -part 2` to 2.0. Below `1.2` there is no FlateDecode, so a `1.0` or `1.1` document needs `-compress 0` and can hold neither embedded fonts nor PNG pictures; the refusal comes when the first stream is written.

  A size given as two numbers is taken as it stands — `{88 55}` stays 88 by 55. It is turned only if an orientation is asked for as well, on **tclpdf new**, on **configure** or on the **page add** itself: `-format {88 55} -orientation portrait` gives 55 by 88. The default `portrait` is not a request, so a pair without any orientation is never touched.

**tclpdf formats**

: The known page format names.

*doc* **configure** ?*option value* ...?

: Changes the document options after creation. It returns nothing; read a single option with **cget**. A page already added keeps the size it was given. **-version** cannot be lowered under a feature the document already uses — after `opacity` the document refuses `configure -version 1.3`, naming the feature. Nor can it be raised over a claim that caps it — after `pdfa` the document refuses `configure -version 2.0`, naming the claim (`this document claims PDF/A-3, which is written as PDF 1.7 at most`).

*doc* **cget** *option*

: One option.

*doc* **destroy**

: Releases the object. A document that was written is not needed afterwards.

## Coordinates and units

Positions are given in the document unit, and **y counts from the top of the page downwards** — the opposite of PDF's own convention, which the package converts on the way out. `-at` names the **top left** corner of what is being placed — with one exception, `circle` and `ellipse`, where it is the centre, because that is how a circle is described. A form or a pattern script is no exception to the rule: inside them the origin is that object's own **top left** corner and y counts downwards, exactly as on the page — the conversion happens against the object's height instead of the page's.

*doc* **coords** *x y*

: The point in PDF user space, for a caller that needs it.

*doc* **distance** *value* ?*unit*?

: A length in points.

*doc* **extent** *size* ?*unit*?

: A `{width height}` pair in points.

## Pages

*doc* **page add** ?**-format** *f*? ?**-orientation** *o*? ?**-rotate** *deg*?

: Adds a page and makes it current. Without options the document defaults apply. `-rotate` must be a multiple of 90.

*doc* **page count**

: The number of pages.

*doc* **page current**

: The index of the current page, counting from zero.

*doc* **page size** ?*index*?

: `{width height}` in the document unit.

*doc* **page box** *name* ?*value*? ?*index*?

: Reads or sets one of the five page boxes: `media`, `crop`, `bleed`, `trim` or `art`. The value is `{x0 y0 x1 y1}` in the document unit — two corners, not a corner and a size. A box may start away from zero; the size is then the difference of the pairs, and the caller's origin follows the box rather than the axis. A box whose corners are not in order (`x1` must exceed `x0` and `y1` must exceed `y0`), or that reaches beyond the media box, is refused with both rectangles in the message — ISO 32000-1 14.11.2 would have the reader cut it back and 7.9.5 would have it swap the corners, both without a word, and tclpdf names the mistake instead. The media box itself must measure between 3 and 14400 pt on each side (Annex C; **page add** applies the same limit to **-format**), and cannot be shrunk under a box already set: set the media box first, or move the box that sticks out. *index* is the page, counted from 0 as **page current** counts, the current page without it — and because it comes after the value, reading a box of another page takes an empty value in between: `page box media {} 0` reads the first page's media box, `page box media 0` is refused as a box that is not four numbers.

*doc* **page typeArea** ?*index*?

: The type area of a page — *index* is one optional page index, the current page without it — as `{x0 y0 x1 y1}` in the document unit like a page box — where flowing text and breaking tables begin and end on it. It is the page less the margins **-typeArea** gave the document, or, without that option, less five percent of the height at the top and the bottom and five percent of the width at each side: `10.5 14.85 199.5 282.15` on A4. Nothing in the file records it; it is a rule for the layout, and one question with one answer — a running head goes above `y0`, a column starts at `{x0 y0}`, and **text -height max**, **text -paginate** and a **table** without **-top**/**-bottom** stop at `y1` and resume at `y0`. Margins that meet on a page are refused when that page is asked, naming the page size and the margins.

*doc* **page content** ?*index*?

: The content stream built for that page so far, as text. For diagnosis: it shows which operators a call actually produced, which is the only way to see a graphics state that leaks past the shape that set it.

## Text

*doc* **font** ?**-family** *f*? ?**-style** *s*? ?**-size** *n*? ?**-color** *c*? ...

: Sets the font state, which stays in force until changed. Without arguments it returns the current state as a dictionary, including the resolved font name.

  **-family** takes one of the fourteen standard faces (`helvetica`, `times`, `courier`, `symbol`, `zapfdingbats`; `arial` is accepted as another name for `helvetica`), an exact PostScript name such as `Times-Italic` — which names the face itself, so a **-style** in force does not apply to it — or the alias of an embedded face. **-style** takes `bold`, `italic` or both; `oblique` is read as `italic`; any other word is refused. **-size** is always in points. Further options: **-spacing** (extra space between glyphs — see below), **-wordSpacing**, **-stretch** (horizontal scaling in percent), **-leading** (line spacing, default 1.2 times the size) and **-rise** (baseline shift, for super- and subscript).

  Every option is checked at the call that writes it, in **font** and per call alike. **-leading** must be a number above zero; an empty value restores the default of 1.2 times the size. **-spacing**, **-wordSpacing** and **-rise** take a number of points of either sign — negative spacing tightens, a negative rise is a subscript. **-kerning**, **-ligatures** and **-unshaped** take a boolean. A **-color** the colour parser does not know is refused where it is written, not at the next piece of text.
  **-spacing** adds its space **between glyphs**, not between characters, because that is where the PDF operator behind it puts it. The two differ only when ligatures are in play: `office` is six characters and, in a face that has the `ffi` ligature, four glyphs — so `-spacing` opens three gaps there, not five. For classic letterspacing, where every letter stands apart, set **-ligatures 0** in the same call; a ligature says the letters belong close together, which is the opposite of what letterspacing says.

  **-ligatures** applies the standard ligatures (`liga`) of an embedded face and is **on by default**. Where a face has one, the letters of `fi`, `ff`, `ffi` and their relatives are drawn as the single glyph the designer made for them. The characters are unaffected: the `ToUnicode` map carries the ligature back to the letters it was made from, so the text is copied and searched as it was written. Only `liga` is read - not the discretionary (`dlig`) or historical (`hlig`) sets, which the feature registry has off; the required ligatures (`rlig`) of the Arabic scripts are applied by the cursive shaping under `-direction rtl`, whether or not `-ligatures` is on. Note that a ligature need not change any width: measured on DejaVu Sans, `fi` and `fl` take exactly the room the two letters took, while `ff` is narrower.

  **-unshaped** draws text from a writing system this package cannot set correctly, and is **off by default** — which means such text is *refused* rather than drawn wrong. See "Writing systems" below.

  **-kerning** applies the pair kerning of an embedded face and is **on by default**. The amounts are read from the font while writing - from its GPOS table where it has kerning lookups, otherwise from its `kern` table, which is the order ISO/IEC 14496-22 prescribes - and are written into the content stream, so neither table is embedded. Kerning changes the width of every line it touches, and the width is measured with it: `textWidth`, the line breaker and the table column widths all see the kerned figures. Set **-kerning** to 0 where a document has to come out exactly as an earlier release produced it. The fourteen standard faces are unaffected: the metrics shipped for them carry widths per byte value, not kerning pairs.

  A combining accent between two letters does not interrupt a pair. Most faces tell the reader to leave marks out of the sequence while kerning - measured here, 51 of the 73 faces on this machine that kern from GPOS do - so `A` + U+0301 + `V` is kerned as the pair `A V`, exactly as the single character U+00C1 followed by `V` has always been. The adjustment is applied in front of the second letter, which leaves the accent where the font puts it. What tclpdf does not do is position the mark itself: GPOS mark attachment is not read, so a combining glyph is drawn at the pen position with the side bearing its face gives it.

  **What that means in practice.** Text that arrives composed — `Ü` as `U+00DC`, `Á` as `U+00C1` — is unaffected, because the face has a finished glyph for it and there is no mark to place. That covers every European language, and it is what databases, XML and the web deliver. Text that arrives **decomposed** — `Ü` as `U+0055` followed by `U+0308` — comes out with its accents visibly displaced, and so do combinations Unicode has no composed form for at all, such as a letter carrying both a macron and an acute. Where such text has to be set, normalise it to NFC before it reaches the package.

### Writing systems

tclpdf maps one character to one glyph and sets them in the order they arrive — left to right, or right to left where `-direction rtl` says so. For most scripts that is the entire job, and they are set correctly: Latin, Greek, Cyrillic, the CJK scripts, the Tibetan letters, Cuneiform, Egyptian Hieroglyphs, symbol and emoji faces.

Some scripts need more. What that "more" is decides whether tclpdf can set them at all — two of the four things it can do, the rest it **refuses to draw** rather than draw something wrong:

| needs | scripts | available |
|---|---|---|
| right-to-left ordering | Hebrew, Thaana, Samaritan; and the non-cursive right-to-left scripts of the supplementary planes — Cypriot, Imperial Aramaic, Palmyrene, Nabataean, Hatran, Phoenician, Lydian, Sidetic, Meroitic Hieroglyphs and Meroitic Cursive, Kharoshthi, Old South and Old North Arabian, Avestan, Inscriptional Parthian and Inscriptional Pahlavi, Old Turkic, Old Hungarian, Garay, Yezidi, Old Sogdian, Elymaic, Mende Kikakui, the Indic and Ottoman Siyaq numbers and the Arabic mathematical alphabets | **yes — `-direction rtl`** |
| contextual forms — the glyph depends on its neighbours — **and** right-to-left ordering | Arabic (including Extended-B and Extended-C) | **yes, in a face that carries whole letters — `-direction rtl`** |
| contextual shaping and right-to-left ordering | Syriac (and Syriac Supplement), N'Ko, Mandaic, Manichaean, Psalter Pahlavi, Hanifi Rohingya, Sogdian, Old Uyghur, Chorasmian, Adlam | no |
| contextual shaping | Mongolian, Phags-pa | no |
| mark placement | Hebrew nikud (U+0591–U+05C7), the Arabic harakat, the Thaana fili, the Samaritan points, the Tibetan vowel signs and subjoined letters (U+0F71–U+0FBC and the other marks of the block; the letters themselves set), and the combining marks of the supplementary-plane scripts above — the Kharoshthi vowel signs and virama among them | no |
| reordering and conjunct forms | Devanagari, Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada, Malayalam, Sinhala, Myanmar, Khmer | no |
| mark placement and reordering | Thai, Lao | no |

**Ordering is the one this package can supply.** Hebrew letters, Thaana and Samaritan bases carry no contextual forms: the glyph the character map gives is the glyph a reader expects, and only the order has to be turned round. The archaic right-to-left scripts of the supplementary planes are the same case — the joining table of the Unicode database knows none of them, Meroitic Cursive included, which is cursive in name only — and their combining marks stay refused like the nikud. `-direction rtl` turns it — after the ligatures and the kerning have been worked out on the logical run, so the pairs looked up are the ones the type designer meant, and `textWidth` answers the same number in both directions. Without the option such text is still refused, and the message names the way out; example `02.09-writing-systems` sets a line of the one such block a face of its pages carries, the Arabic mathematical letters in DejaVu Sans.

**Arabic is set with its contextual forms**, and that needs the right face as well as the option. Each character is asked which of the four shapes it stands in — isolated, initial, medial or final — by the cursive joining algorithm of the Unicode Standard, section 9.2, with the joining types taken from the Unicode Character Database. The shape itself then comes out of the face, through the GSUB features `ccmp`, then the positional `isol`, `fina`, `medi` and `init` — each glyph takes exactly one of the four, the one its position asks for — and `rlig` last, applied in that order. The result is checked glyph by glyph against HarfBuzz: `tests/forms.test` shapes six words with `hb-shape` and compares the glyph numbers, and skips itself where HarfBuzz is not installed.

**Which faces.** A face has to carry the three positional features, and its letters have to be whole glyphs. Some Arabic faces — Noto Naskh Arabic is the one shipped with the examples — write a letter as an undotted skeleton plus a separate dot glyph and place the dot with GPOS mark attachment, which this package does not read: the dots would land beside their letters, and measured on that face the two dots of *teh marbuta* belong a third of an em lower than they would be drawn. Such a face is **refused**, and the message says which of the two things is missing. DejaVu Sans carries whole Arabic letters and sets the same line correctly; example `02.09-writing-systems` shows both.

**What is still missing in Arabic.** Two things, and both are visible rather than silent. Required ligatures that a face reaches through *chaining* lookups (GSUB types 5 and 6) are not applied — where a face writes its lam-alef as an ordinary ligature lookup, as DejaVu Sans does, the ligature comes out; where it chains to it, the two letters come out joined but as separate shapes. The same applies to the wider medial variants some faces select that way. And the harakat, the Arabic vowel signs, are marks: a line carrying them is refused for the same reason nikud is.

**Nikud stays refused**, and deliberately: the points are combining marks, GPOS mark attachment is not read (see `-kerning` above), and a vowel point drawn at the pen position sits beside its letter instead of under it. The letters of a line without points are unaffected.

**Numbers keep their own order.** A right-to-left line is not simply reversed — a run of digits inside it runs left to right, because it does in every script that uses digits. `الفاتورة 4711` sets the invoice number as `4711` and not as `1174`, which is what the plain reversal produced and what nobody looking at the page could tell was wrong. Which characters belong to a number is not a list of this package's own but the Unicode Character Database (`DerivedBidiClass.txt`, Unicode 17.0.0), reduced to the classes of UAX #9 that rules W1–W7 fold into a number: the digits — European, Arabic-Indic (`٠`–`٩`), Extended Arabic-Indic, superscripts and the rest of EN and AN — keep their order; a Common Separator (CS: comma, full stop, colon, slash, no-break space, Arabic comma …) belongs to the number **between two digits**; a European Terminator (ET: percent and per mille, degree, the currency signs `€ $ £ ¥ ¢ ₹ …`, number sign, plus-minus …) belongs to it **directly beside one**. After an Arabic letter a European digit counts as an Arabic one (rule W2; after a Hebrew letter, or at the start of the line, it stays European), and an Arabic number is stricter: a separator joins it only between two Arabic digits (W4), and no terminator or sign joins it at all (W5 applies to European digits) — so `الفاتورة 4711 - 1.234,50 € (19%)` keeps `4711` and `1.234,50` whole and sets the `%` and the brackets where the line runs, and `-17,5°` after an Arabic word is a sign, a number and a degree sign, as fribidi and UAX #9 have it. One thing is deliberately not the plain rule: a plus or minus beside a European digit is treated like a terminator, so that `-5` and `+3%` in a Hebrew line keep their sign — measured against fribidi over 31 invoice lines, that sign is the only difference. The Arabic decimal and thousands separators (U+066B, U+066C) are AN in Unicode, part of the number wherever they touch it. This is the corner of the Unicode bidirectional algorithm (UAX #9, rules W2, W4 and W5) that one run of digits needs, and nothing beyond it.

**Paired brackets are mirrored.** `(` is the *opening* bracket, and the opening bracket of a line that runs the other way is drawn with the glyph of `)` — Unicode calls this mirroring (UAX #9, section 3.4) and it is a property of the display, not a different character. It applies to `( )`, `[ ]`, `{ }`, `< >`, `« »` and `‹ ›`; the German quotation marks `‚ '` look like a pair and are **not** mirrored, and neither is a slash. Because the `ToUnicode` map speaks about glyphs and the glyph of `)` is the glyph of `)` wherever it is used, each mirrored glyph is drawn inside a `Span` carrying the character it stands for as `ActualText`, so that the line still extracts as it was written. Measured with poppler 26.08.0: without that span `(שלום)` comes back as `)שלום(`.

**A mixed line is refused.** A line that mixes the two directions — an Arabic sentence with a Latin word in it, a Hebrew heading with a Cyrillic name — needs the full bidirectional algorithm to decide which run goes where, and tclpdf does not implement it. Such a call is therefore **refused**, naming the first character that runs the wrong way and what to do instead:

  ~~~
  tclpdf: U+0052 (position 0) is left-to-right in a -direction rtl line
  - a mixed line needs the bidi algorithm, which tclpdf does not have;
  set the runs as separate calls, one per direction
  ~~~

  It used to be accepted and to come out with the Latin words backwards — `gnunhceR … rellüM` — which is the kind of line that looks like text and is not. Everything that is *not* strongly left-to-right may stand in such a line: right-to-left letters, digits, spaces, punctuation, brackets, currency and symbols. `-unshaped 1` turns the refusal off along with the others, for the caller who knows what it does.

  The mirror image is unchanged: a right-to-left script in a left-to-right line is refused as it always was, and that message names `-direction rtl` as the way out.

**Which calls take -direction.** `text`, `textWidth` and `textLines`, and with them the paragraph forms of `text`; `textPath`, where the glyphs run backwards along the path and `-align` is mirrored with it; `leader`, where the two ends change places and the fill is measured from the other side; `pageNumbers`, so that `صفحة 3 من 10` comes out with its numbers the right way round; and the table, where `direction` is a style key and a cell key like `align` — a right-to-left description column and a left-to-right amount column on the same row are two cells, not two tables. A decimal column does not mirror: it holds numbers, and numbers are set left to right in either direction.

The refusal is the same rule the package applies to a character the face has no glyph for: a reader shows the wrong text, a validator says nothing, and only this end can notice. Arabic drawn without shaping comes out as isolated letter forms — it looks like text and is not.

**-unshaped 1** turns the refusal off altogether and draws the characters as isolated glyphs in the order they were given. It is not the answer for a script that needs only ordering — `-direction rtl` is, and it is the better one — nor for Arabic in a face that can be shaped. What is left for it is the case where the forms or the mark positions cannot be had and the caller decides that isolated glyphs are better than nothing; combined with `-direction rtl` such a line at least runs the right way, which is what example `02.09-writing-systems` shows for the Arabic face whose dots would be misplaced.

**What extraction gives back**, measured with poppler `pdftotext` 26.08.0. A line reading `שלום עולם`, set with `-direction rtl`, extracts by default as `U+202B` `שלום עולם` `U+202C` — the string as it was written, wrapped in the two directional marks, because the reader reconstructs the logical order from the Unicode values in the `ToUnicode` map. `pdftotext -raw`, which reports the drawn order on purpose, gives the two words the other way round with the letters of each word in logical order. The same string drawn with `-unshaped 1` instead — a logical run set left to right — comes back from the default `pdftotext` **reversed**, as `םלוע םולש`. So the option that makes a right-to-left line extract as it was written is `-direction rtl`, and the one that does not is `-unshaped 1`.

*doc* **font embed** *alias path* ?**-subset** *0*? ?**-metrics** *path*? ?**-axes** *{tag value …}*? ?**-instance** *name*?

: Embeds a font file under an alias, which is then usable as **-family**. The file says what it is; the extension is not consulted. (PDF 1.2; a CFF face PDF 1.6.)

: **TrueType** (`.ttf`) is subset to the glyphs actually used, addressed by glyph number, and gets kerning and ligatures from the font's own tables. **OpenType with CFF outlines** (`.otf`) goes in whole, as `/FontFile3` with `/Subtype /OpenType` and a `/CIDFontType0` descendant — the Type 0 font is named `<name>-Identity-H` as ISO 32000-1 9.7.6.1 asks, the CIDFont and the descriptor carry the plain name — everything else about it, the character mapping and the widths included, is read exactly as for TrueType. A **CID-keyed** CFF face — one whose Top DICT carries the `ROS` operator, as CJK faces from Adobe and Apple do — is refused by `font embed`, naming the file: ISO 32000-1 9.7.4.2 lets a CIDFontType0 address glyphs by glyph index only when its program is name-keyed; for a CID-keyed program the CID goes through the program's charset, and wherever that is not the identity a conforming reader would draw a different glyph than the one measured here, with no validator noticing. Convert such a face to TrueType or to a name-keyed CFF first. **Type 1** (`.pfb`, `.pfa`, `.t1`) goes in whole as well and is addressed by single bytes through WinAnsiEncoding — see below.

: **Why a CFF face is not subsetted.** Subsetting rewrites the `loca` and `glyf` tables, and a CFF font has neither: its outlines are charstrings in a table this package reads no further than the Top DICT. So the whole file is embedded, around 40 to 100 KB depending on the face. Where the same face exists as `.ttf`, that form is the better choice for a document that uses it for a heading and nothing else — a subset of a few words is a fraction of either. `-subset` is accepted and has no effect; the face carries no subset prefix, because nothing was subsetted.

: **What the descriptor says** comes from the file (ISO 32000-1 Table 122): the italic angle from `post` — `-12` for Nimbus Sans Oblique, where a constant 0 stood before — the cap height from `OS/2` where the table is recent enough to carry one, else the top of the H (DejaVu Sans, OS/2 version 1: 729 where the ascender is 928), the ascender only for a face without an H or a CFF face without the field; and the flags with the italic bit set where either says so; for an instance on a `slnt` axis the axis value is the italic angle, and `slnt` ≠ 0 or `ital` ≥ 0.5 sets the italic flag. `StemV`, which TrueType has no field for, is estimated from the weight class as `50 + (weight / 65)²` — 87 for a regular face, 165 for a bold one, the rule tFPDF and mPDF write; for an instance of a variable face the `wght` axis is the weight class. A wrong `StemV` affects hinting hints, not the glyphs.

: **A character the face has no glyph for is an error, not a blank.** `text`, `textWidth`, a table cell and text inside an SVG all refuse the string, and the message names the face, the character as `U+XXXX` and its position: `the font "free" has no glyph for U+2714 (position 0) - it cannot be written with this face`. This end is the only one that can notice: a reader shows a blank or a box, a validator says nothing, and the recipient reads an invoice with a gap where the check mark was. Do not take a font viewer's word for what a face contains. A viewer that is asked for a character the face lacks substitutes the glyph from another face and shows the result without saying so — measured with FreeSans, whose viewer window shows U+2714 (✔) although the file has no glyph for it (`hb-shape FreeSans.ttf --unicodes U+2714` answers `.notdef`). A PDF has no such fallback: the embedded font is all a reader has. What tells the truth is the file itself — `hb-shape`, or simply setting the string here and reading the message — and `fc-list ':charset=2714'` names the installed faces that carry the character; for the dingbats and symbols DejaVu Sans and Noto Sans Symbols 2 do.

: **Type 1 needs its metrics beside it.** The widths of a Type 1 face are inside its encrypted charstrings, so they come from the AFM instead: `font embed` looks for the same base name with `.afm`, and **-metrics** names it where it sits elsewhere. Without metrics the face is refused rather than embedded with no widths. A glyph the AFM lists and the program lacks is refused like any missing character (Adobe's Helvetica.afm lists `Euro`, Helvetica.pfb has no such charstring — it used to set a blank). `-axes` and `-instance` on a Type 1 program are refused, as is `-metrics` on a TrueType or OpenType face.

  Embedding a Type 1 program is a copy — the file already consists of the three pieces PDF asks for as `Length1`, `Length2` and `Length3`. The encrypted section is decrypted only to read the names of the glyphs the program holds — nothing is rewritten and nothing is subsetted: the face goes in whole, which for a text face is 25 to 105 KB. `-subset` does not apply. The one thing that is not copied as it stands is the hexadecimal form of a `.pfa`: PDF wants the encrypted piece as bytes (ISO 32000-1 9.9.1), so the hex is decoded on reading, and a `.pfa` then embeds the same font file as the `.t1` or `.pfb` of that face — measured, byte for byte, and veraPDF passes it where the pass-through failed 6.2.11.4. Kerning and ligatures do not either; a Type 1 program carries neither GPOS nor GSUB, and the kern pairs an AFM may list are not read.

  The reach of such a face is the 224 positions of WinAnsiEncoding, as with the standard fourteen — a character outside it is an error, not a blank. Two of those positions are aliases the encoding itself defines (ISO 32000-1 Annex D): 0xA0, the no-break space U+00A0, is a second code for the space glyph and is set — and measured — as wide as a space, so `12 €` keeps its unit on the line; and 0xAD is a second code for the hyphen, which is why a soft hyphen never reaches the font. The no-break space is written as byte 0xA0, not turned into a space; readers extract it as U+0020 for a standard or Type 1 face all the same (measured with pdftotext). Inside a paragraph it is neither a break point nor a stretchable gap — see "Where a line breaks" under **text**. Where a document needs more, TrueType is the format to embed.

: **Variable fonts** carry one set of outlines plus a rule for bending them, and **-axes** or **-instance** says where on that rule to embed. `-axes {wght 620 wdth 87}` names axis values directly; `-instance "Condensed Bold"` names a point the designer named, taken from the font's own name table. The two combine — `-instance` sets the starting point and `-axes` overrides single axes of it. Without either, the face is embedded at its default position, which is what sits in its outline table.

  **Each point on the axes is its own embedded font**, because PDF has nowhere to put an axis value: not in the font dictionary, not in the descriptor. The outlines are therefore computed while embedding and go into the file as a fixed instance. Nine weights on a page mean nine subsets, and each is named for what it is: a named instance carries the PostScript name the font gives it — `Roboto-Bold`, `Roboto-CondensedLight` — whether it was asked for by name or by the axis values that are that instance, and any other point is named by its axis values the way Adobe Technical Note 5902 lays down, `Roboto_620wght`, `Roboto_620wght_87.5wdth`. The face's own name, `Roboto-Regular`, names its default and nothing else. The subset tag in front of the name is derived from what was subsetted — the name, the glyphs used, the point on the axes — so two subsets of one file in one document carry different tags, as ISO 32000-1 9.6.4 asks, and two writes of one document carry the same. `pdffonts` on example `02.10-variable-fonts` shows twenty-four instances of one file, each under its own name and tag; it used to show twenty-four times `SZGNUB+Roboto-Regular`.

  `-subset 0` on an instance still embeds every glyph — but as the instance, not as the variable file. The file itself, `fvar`, `gvar` and all, would hand a reader the default outlines under the instance's widths, Regular shapes spaced as Bold; measured with veraPDF, 22 width mismatches under 6.2.11.5. So all glyphs go through the instancer, the variation tables stay behind, and no subset tag is written because nothing is missing.

  The advance widths vary with the axes and are read from the same source as the outlines, so `textWidth`, the line breaker and the table columns all measure the instance that is actually drawn. An axis the font does not have, or a named instance it does not offer, is an error that lists the ones it does, and a value outside an axis's range is refused with the range (`wght runs from 100 to 900`) rather than clamped. `-axes` on a face without an `fvar` table is refused rather than ignored.

  What varies and what does not: outlines, component offsets and advance widths do — the advance of an empty glyph included, so a space is 490 units wide in Roboto Thin and 510 in Black, as fontTools' instancer has it. The bounding box and left side bearing of a composite glyph follow its moved components: after instancing, the box is rebuilt from the outlines the composite now places (as fontTools' `recalcBounds` does) and the bearing set to its new xMin, as `head` flag bit 1 promises. Measured over the seven variable faces in the examples at their weight maximum, carrying the file's box over would have left 6 207 of 6 275 composites off by ten units or more — Roboto Black's A-dieresis by 90 on the right, its r-caron by 123 on the left. Neither poppler nor CoreGraphics render the difference, because both place a glyph at xMin minus bearing and the two stale values agreed with each other; the embedded font describes what it draws all the same. The bounding box of an instance follows the moved outlines as well: the head table of the embedded subset and `/FontBBox` in the font descriptor (ISO 32000-1 9.8.1, Table 122) both state the box of the instanced face, computed as the union of every moved glyph — measured at the axis corners of the seven variable faces in the examples, the file's box was off by up to 351 units (NotoSerifTibetan at wght 900), and Roboto Black reaches 130 units further right than the file declares. The four summary fields of `hhea` — advanceWidthMax, minLeftSideBearing, minRightSideBearing and xMaxExtent — follow the same rule: for an instance they are computed from the moved glyphs by the format's own definition (the maximum advance over every glyph, the bearings and the extent over the glyphs with contours only, as fontTools' `recalc` does) — measured at the axis corners of the seven variable faces, the file's numbers were off by up to 377 units (NotoSans's minRightSideBearing at wght 100 wdth 62.5), and Roboto Black's advanceWidthMax is 2475 where the file says 2378. A face embedded without axes keeps the file's box in both places and the file's `hhea` summary, byte for byte. Hinting programs are carried through unchanged. The advances are read off the phantom points of `gvar`, which every glyph carries; the `HVAR` table, which every variable face in the examples ships, repeats the same deltas for readers that do not walk `gvar` and is not read — an instancer that pins every axis drops it after applying the phantom points, and measured against fontTools glyph for glyph, the two sources agree.

: **Which file to embed for a standard face.** A document that has to be archivable may not leave a font unembedded, and that includes the fourteen standard faces — PDF/A makes no exception for them. Their outlines were never released, so an equivalent has to take their place. The table below maps each of the fourteen to the file that stands in for it: Adobe's Type 1 and OpenType files, the URW Core 35, and what Windows ships. macOS ships the five families under the standard names themselves — the PostScript names inside `Helvetica.ttc`, `Times.ttc`, `Courier.ttc` and `Symbol.ttf` are the fourteen, only the display names spell the style out (`Helvetica Bold Oblique`, `Times Bold Italic`) — so the first column is the macOS column as well, with one exception: `ZapfDingbats.ttf` carries the PostScript name `ZapfDingbatsITC`.

  | PDF standard 14 / macOS | Adobe Type 1 | Adobe OpenType | URW Core 35 | Windows |
  |--------------------|--------------------|--------------------|--------------------|--------------------|
  | Helvetica | `Helvetica.pfb` | `HelveticaLTStd-Roman.otf` | `NimbusSans-Regular.ttf` | `Arial.ttf` |
  | Helvetica-Bold | `Helvetica-Bold.pfb` | `HelveticaLTStd-Bold.otf` | `NimbusSans-Bold.ttf` | `Arialbd.ttf` |
  | Helvetica-Oblique | `Helvetica-Oblique.pfb` | `HelveticaLTStd-Obl.otf` | `NimbusSans-Oblique.ttf` | `Ariali.ttf` |
  | Helvetica-BoldOblique | `Helvetica-BoldOblique.pfb` | `HelveticaLTStd-BoldObl.otf` | `NimbusSans-BoldOblique.ttf` | `Arialbi.ttf` |
  | Times-Roman | `Times-Roman.pfb` | `TimesLTStd-Roman.otf` | `NimbusRoman-Regular.ttf` | `Times.ttf` |
  | Times-Bold | `Times-Bold.pfb` | `TimesLTStd-Bold.otf` | `NimbusRoman-Bold.ttf` | `Timesbd.ttf` |
  | Times-Italic | `Times-Italic.pfb` | `TimesLTStd-Italic.otf` | `NimbusRoman-Italic.ttf` | `Timesi.ttf` |
  | Times-BoldItalic | `Times-BoldItalic.pfb` | `TimesLTStd-BoldItalic.otf` | `NimbusRoman-BoldItalic.ttf` | `Timesbi.ttf` |
  | Courier | `Courier.pfb` | `CourierStd.otf` | `NimbusMonoPS-Regular.ttf` | `Cour.ttf` |
  | Courier-Bold | `Courier-Bold.pfb` | `CourierStd-Bold.otf` | `NimbusMonoPS-Bold.ttf` | `Courbd.ttf` |
  | Courier-Oblique | `Courier-Oblique.pfb` | `CourierStd-Oblique.otf` | `NimbusMonoPS-Italic.ttf` | `Couri.ttf` |
  | Courier-BoldOblique | `Courier-BoldOblique.pfb` | `CourierStd-BoldOblique.otf` | `NimbusMonoPS-BoldItalic.ttf` | `Courbi.ttf` |
  | Symbol | `Symbol.pfb` | `SymbolStd.otf` | `StandardSymbolsPS.ttf` | `Symbol.ttf` |
  | ZapfDingbats | `ZapfDingbats.pfb` | `ZapfDingbatsStd.otf` | `D050000L.ttf` | — |

  **A second free set: the Liberation fonts.** Where a document need not match the standard fourteen metrically, any embeddable face will do; where it must — a form laid out for Helvetica, a table measured with Times — two free sets keep the measure, from two lineages. The URW Core 35 above are metric copies of the PostScript faces themselves (measured: 2592 of 2592 advances equal). Red Hat's Liberation Sans, Serif and Mono (SIL Open Font License 1.1, <https://github.com/liberationfonts/liberation-fonts>; the copies used here sit under `examples/assets/fonts/liberation-fonts/`, release 2.1.5, four styles each) are metric copies of Arial, Times New Roman and Courier New, and those were drawn to the measure of Helvetica, Times and Courier bar a handful of symbols; measured over every WinAnsi position the AFM prices, at 1000/em, half a unit of tolerance (`tests/font.test`, `font-13.1`, holds the numbers):

  | Liberation | stands in for | advances equal | differs at |
  |----------------------|----------------------|----------------------|----------------------|
  | Sans, four styles | Helvetica, -Bold, -Oblique, -BoldOblique | 211 of 216 each | `¯ ± µ · ÷` |
  | Serif, four styles | Times-Roman, -Bold, -Italic, -BoldItalic | 211, 211, 212, 213 of 216 | `¯ ± µ · ÷` (fewer in the italics) |
  | Mono, four styles | Courier, -Bold, -Oblique, -BoldOblique | 216 of 216 each | — |

  2555 of 2592 advances equal (216 per face, the count the URW figure uses); the 37 that differ are five symbols — macron, plus-minus, micro sign, middle dot, division sign — where Arial and Times New Roman never were Helvetica and Times. Running text sets to the same measure in URW and in Liberation alike; a form laid out on those five characters wants URW. Neither set is installed with the package; both travel in the source archive with their licences, and example 02.03 sets Liberation Sans beside the other families.

  **And at Google Fonts.** The Liberation designs are there as well, under the names the licence reserves alongside Liberation — Arimo, Tinos and Cousine — and with them one face for the symbols; four families to look at, out of a collection that is a good source for everything that need not keep the measure:

  | Google Fonts | stands in for | why |
  |----------------------|----------------------|----------------------|
  | Arimo | Helvetica, Arial | a sans drawn to the metrics of Arial — Liberation Sans |
  | Tinos | Times-Roman, Times New Roman | a serif drawn to the metrics of Times New Roman — Liberation Serif |
  | Cousine | Courier, Courier New | a monospace drawn to the metrics of Courier New — Liberation Mono |
  | Noto Sans Symbols 2 | Symbol, ZapfDingbats | covers most of the same characters, at widths of its own |

  Noto Sans, Noto Serif and Noto Sans Mono, good faces otherwise, keep proportions of their own (measured: 0 of 191 Noto Sans advances equal Helvetica's) and are not stand-ins. For Symbol and ZapfDingbats there is no one-to-one equivalent at Google Fonts; the URW `StandardSymbolsPS` and `D050000L` above are the metric matches, and `font embed` refuses them today for their symbol-only cmap, see the next paragraphs.

  **Three of those files can be embedded as they stand.** The URW files are TrueType and go in unchanged; Adobe's Type 1 files go in whole, provided their AFM is beside them; Adobe's OpenType files go in whole as CFF. The macOS faces for Helvetica, Times and Courier are TrueType **collections** — several faces in one file — and a single face still has to be extracted before it can be used.

  **Two of the fourteen have no working substitute today.** The URW files for Symbol and ZapfDingbats carry a `(3,0)` symbol cmap and no Unicode one, so `font embed` refuses them. The `.otf` files of the two embed and set the Latin positions with their glyphs (measured: 190 and 203 characters reachable), but a reader extracts Latin letters for them — use them for the page, not for copyable text; the `.t1` files embed as well but reach only the glyphs whose names are WinAnsi names (measured: 41 of the Symbol face — digits, punctuation, `± × ÷ µ °` — and none but the space of the Dingbats face). The twelve text faces are unaffected and cover Helvetica, Times and Courier completely.

  The URW faces are metric substitutes, and measured against the metrics this package ships: every one of the 2 592 advances of the twelve text faces matches the standard face it stands in for, across all mapped WinAnsi byte values. They are published under the SIL Open Font License 1.1, so they can be redistributed with a document workflow; Adobe's own outlines cannot.

  **tclpdf does not install any font.** Embedding one means having the file, and which file that is remains the caller's choice — the package reads what it is given. The URW set is version 2.0 of the URW++ Core 35, kept at <https://github.com/twardoch/urw-core35-fonts>; distributions carry the same fonts as a package of their own, on Debian and its derivatives as `fonts-urw-base35`. The copies used to write the examples sit in the source archive under `examples/assets/fonts/urw-core35-fonts`, with the licence texts beside them.

*doc* **font names**

: The aliases embedded so far.

*doc* **font info** *alias*

: What the file says about itself: `family`, `postScript`, `glyphs`, `unitsPerEm`, `characters`, and the embedding permission as `fsType` and `permission`. `postScript` is the name the face is embedded under: for an instance of a variable font (`-instance`, `-axes`) that is the instance's PostScript name — `Roboto-Bold`, `Roboto_620wght` — not the default the file itself is named for. `permission` also names a no-subsetting (fsType bit 8) or bitmap-only (bit 9) restriction, and answers `unknown` for a face without an OS/2 table.

*doc* **text** *string* ?**-at** *{x y}*? ?**-width** *w*? ?**-align** *a*? ?**-direction** *ltr|rtl*? ...

: Draws text. **Without -width** this is one line, and `-align` refers to the given point: `left` starts there, `right` ends there, `center` — `centre` is accepted too — is centred on it; the call returns nothing. Without **-width** the string is one line: a line feed in it is refused; a paragraph is asked for with `-width`. **With -width** the string is broken into a paragraph of that width, `-align justify` becomes available, and the call returns the y coordinate below the last line, so the next block can continue there.

  **-anchor** chooses what the y coordinate means: `baseline` (the default) or `top`; any other value is refused. **-rotate** turns the text about `-at`. All font options are accepted per call without changing the state; a `-size` or `-stretch` of zero or less is refused, here and in **font**, rather than making the text vanish. `-width` must be a positive number.

  **-direction** is `ltr` or `rtl` and says which way the line runs. It is an option of the *line*, not of the font state: the same face sets a right-to-left line and a left-to-right heading beside it, so `font` does not take it. Under `rtl` the glyph run is turned round before it is written — with a run of digits keeping its own order inside it and a paired bracket drawn mirrored — and `-align` is mirrored with it: `left` means the edge the line *starts* at in reading order, which is the right hand one, so `-at` marks the right edge of a line that is otherwise unaligned. `center` and `justify` mean the same thing either way. A line that also holds strongly left-to-right text is refused rather than set backwards, and so is `rtl` on one of the standard fourteen faces or an embedded Type 1 face: those are addressed through WinAnsiEncoding, which has no right-to-left letter, so the option could only have done nothing. Which scripts this makes drawable, and what the two rules above do exactly, is described under "Writing systems" below.

  **-height** *h* limits the block. What fits is drawn and the return value becomes a dictionary with `y` and `rest` — the text that did not fit, ready to be set in the next column or on the next page. `rest` is the tail of the string as it was given, from the first character that was not set: soft hyphens are still soft, a word broken by character is still one word, and the paragraph breaks are where they were. `y` is the baseline under the last line drawn — the paragraph spacing of a paragraph held back is not counted. Without `-height` the return value is the y coordinate as before — and without `-height` a paragraph knows nothing about the page: it runs on below the type area and below the page if it is long enough, and only the y it returns says so.

  **-height max** is the height that is left: from `-at` down to the bottom of the type area of the current page (see **page typeArea**), less the ascent of an `-anchor top` block, so that the block ends inside the area rather than one line under it. The answer is the same dictionary — `y` is the last visible line, `rest` the text for the next page — and a block placed under the area draws nothing and hands everything back, answering the `y` it was given. It cannot be combined with **-rotate**: a turned block does not run down the page.

  **-paginate** *bool* keeps the loop that `-height` leaves to the caller: what fits goes on this page, a page is added with the document defaults (as **page add** without options would), the text goes on from the top of the type area of the new page — hanging from it as with `-anchor top`, whatever the anchor of the first block was — and so on until nothing is left. Every page it adds fires `pageAdded`, so a running head hung on that event lands on every continuation page; **-avoid** holds on the first page only, its shapes being positions on that page. A paragraph broken by the page keeps its **-firstIndent** for paragraphs, not for pages: the first line on a continuation page is indented only when it opens a paragraph. The return value is `{y rest page column}` — `y` under the last line, `rest` always empty (it is there so that a caller reading `-height`'s answer reads this one the same way), `page` the index of the page the text ended on, `column` the column it ended in, `0` without **-columns**. In a tagged document the run stays *one* paragraph, with a marked-content reference on every page it touches (ISO 32000-1, 14.7.4.2) — the shape a table breaking over pages has, one Table with children on every page — and an artifact is declared again on every page. Needs **-width**, refuses **-rotate** and a numeric **-height** (the page is filled to the bottom of the area, which is `-height max`), and refuses a page it added itself when not one line fits into it rather than paginating for ever; on the page the block is placed on, an `-at` below the last line means the text begins on the next page.

  **-columns** *n* sets the block in *n* columns side by side inside **-width**, **-gutter** *g* apart (five millimetres unless said otherwise), each column filled to the bottom of the type area before the next begins, and the page added only after the last one — so it wants **-height max** or **-paginate**, which are what fill a column. With `-height max` alone the columns of the current page are filled and the rest is handed back with `column` = the last one; with `-paginate` the columns of every page. **-balance** *bool* evens out the page the text ends on: instead of full columns and a short last one, the columns are cut to one height, found by measuring the block without drawing it and grown a line at a time until the last column takes the last line — so they end on a baseline together, up to *n*−1 lines apart when the line count does not divide. It needs `-columns` of 2 or more and cannot be combined with **-avoid**, whose shapes would make each column break differently from the measurement. A page that is filled anyway has nothing to balance and is not.

  **-indent**, **-indentRight** and **-firstIndent** narrow the column; a negative first indent hangs the opening line out to the left, which is how a numbered clause is set. **-paragraphSpacing** adds room between paragraphs, on top of the leading.

  **-avoid** takes a list of shapes the text runs around: `{rect {x y} {w h}}` and `{circle {x y} r}`. Each line is narrowed by whatever reaches into it and set in the widest free segment, so a circle is followed by its outline rather than by a box around it. A line whose free segment is narrower than the widest character of the text is left empty and the text goes on below the shape — a shape wider than the column pushes the text down rather than letting it run through one letter at a time. The indents apply as they do without shapes, and the shapes are measured against the lines where they actually stand — with `-anchor top` the first baseline sits one ascender below `-at`, and a shape starting on that edge narrows the first line already. The shapes are not drawn — that is a separate call, and the text can just as well keep clear of something invisible.

  **-avoidMargin** *d* holds the text off every avoided shape by that distance; a shape may state one of its own as a fourth element (`{circle {x y} r 7}`), which then wins. Without it the words touch the picture, which reads as a mistake however exact the geometry is.

  **-tag** *type* names what the text *is* in a tagged document — `P` unless said otherwise, `H1` for a heading, `Artifact` for what is outside the tree; **-expansion** *text* marks the string as an abbreviation and gives its expanded form. Both are described under "Structure and accessibility" below.

  **Soft hyphens are honoured.** U+00AD is not a character but a permission — this word may be broken here. Where the breaker takes the offer, a real hyphen is set at the end of the line; everywhere else the mark stays invisible, in the drawing and in the measurement alike, so the same string can be set in any width. tclpdf does **not** hyphenate by itself: that needs language data and is a feature of its own. What it does is honour the marks that text arriving from a database, an XML file or an editor already carries. Note that extracting such a line yields the hyphen as well, and that a standard face is no longer refused for carrying the mark.

**Where a line breaks.** A line breaks at ASCII white space — the space, a tab, a carriage return; a tab or a stray CR is set as the space that joins two words — and after the spaces UAX #14 lets a line break at: the Ogham space mark U+1680, en quad to hair space (U+2000–U+2006, U+2008–U+200A), the medium mathematical space U+205F and the ideographic space U+3000 (class BA), and the zero width space U+200B (class ZW). Where a line ends on one of these the character is dropped like a space; inside a line it is a character of the text — measured and set with its own glyph width, refused by a face that has no glyph for it, the standard fourteen among them — and never stretched. The zero width space is the exception: like the soft hyphen it never reaches a font, so it breaks where it stands, shows nothing and is set by every face. The byte order mark U+FEFF is dropped the same way — nothing to draw, no glyph asked of the face, by the standard fourteen as by an embedded face — instead of being refused as an Arabic mark or as a character outside WinAnsiEncoding. The no-break spaces U+00A0, U+2007 and U+202F are glue (class GL): the breaker never breaks at them, so `12 €` stays on one line with its unit. Every other space of Unicode — U+2028, U+2029 and U+0085 among them — is a character of the word it stands in. Justification distributes the gap over the U+0020 characters of the line only, because that is what word spacing reaches (ISO 32000-1 9.3.3): in a justified line a no-break space keeps the width of a space and a thin space stays thin while the word spaces around them grow. The rest a height limit hands back is the tail of the string, so a thin space inside it is still a thin space. Example `01.10` sets the same amounts with a no-break and with a thin space side by side.

*doc* **leader** *left* *right* **-at** *{x y}* **-width** *w* ?**-fill** *"."*? ?**-gap** *d*? ?**-tag** *type*? ?*font options*?

: A row with two ends and a filled middle — a table of contents, a price list, a total:

  ~~~tcl
  $doc leader "3. Embedding fonts" "24" -at {20 100} -width 120
  # 3. Embedding fonts ........................... 24
  ~~~

  Both ends are measured and the space between them is filled with as many whole copies of **-fill** as fit — measured as the run is drawn, so `-spacing` and `-wordSpacing` are counted between the copies — holding **-gap** clear of each end (1 unit by default). The remainder stays in front of the right hand end, so the figures of several rows line up. **-fill** may be any string, and an empty one draws nothing at all — which is what a sum under a rule wants. Either end may be empty. Returns the y coordinate one line down, so rows stack without measuring again.

  **-direction rtl** turns the row round: the first argument is the *leading* end and belongs at the right edge, the second at the left, and the fill is measured from the other side. The alignment of each end follows, so a right-to-left row needs nothing but the option.

  It does not wrap: each end is one line. A left side too long for the width keeps its full length and the fill disappears, rather than moving the figure a reader is looking for. In a tagged document the row is **one** element and the fill is an artifact — a reader that spelled the dots out would say "dot dot dot dot" between every entry and its number. **-tag** names the element (`P` by default), and `-tag Artifact` — or the kind as a list, `-tag {Artifact Pagination Header}`, as `text` takes it — takes the whole row, ends and fill, out of the tree, which is what a running head is. **-width** is a positive number, **-gap** a distance of 0 or more.

*doc* **textPath** *string* **-segments** *{...}* ?**-align** *a*? ?**-offset** *d*? ?**-tag** *type*? ?*font options*?

: Sets one line of text along a path, glyph by glyph, each one turned by the direction the path takes at its own position. The segments are the ones **path** takes (`move`, `line`, `curve`, `close`); **-align** — `left`, `center` or `right`, and `centre` for `center` — places the string at the start, the middle or the end of the path, and **-offset** lifts the baseline off it — positive above, negative below (a number; anything else is refused). Returns the length of the path, which is what a caller measures a string against beforehand: glyphs that run past the end are dropped rather than piled up there. The path itself is not drawn.

  **-direction rtl** runs the glyphs backwards along the path and mirrors **-align** with them, exactly as it does on a straight baseline — including the numbers inside such a line, which keep their own order there too.

*doc* **pageNumbers -at** *{x y}* ?**-format** *"Page %n of %m"*? ?**-align** *a*? ?**-from** *n*? ?**-total** *n*? ?*font options*?

: Puts a page number on every page. `%n` is the number, `%m` the total. **-align** places the number on **-at** as `text` places a line: `left` (the default) starts there, `right` ends there, `center` is centred on it. It takes the *line* options as well as the font ones, so `-format "صفحة %n من %m" -direction rtl` sets a right-to-left page number with the two figures the right way round. The numbers are drawn when the document is written, not when the call is made — which is the only moment the total is known — so the call may come before the pages it numbers. **-from** leaves the leading pages unnumbered, **-total** states a total of its own for a document that is part of a larger set. **-total** is a whole number of 1 or more and **-align** one of `left`, `right`, `center`; both are refused at the call. Several calls are independent of each other: a number at the foot and a running title at the head are two of them.

*doc* **textWidth** *string* ?*font options*?

: The width of a string in the document unit.

*doc* **textHeight** *string* **-width** *w* ?*options*?

: The height a paragraph of that width would take — exactly what **text** advances by with the same options: the difference between the y it returns and the y it was given, indents, paragraph spacing, the ascender of `-anchor top` and the lines a shape pushes down included. It takes the options **text** takes, so one option list serves measuring and drawing; what only the drawing uses (`-align`, `-rotate`, `-tag`, `-expansion`) is accepted and changes nothing, and so are `-height`, `-paginate`, `-columns`, `-gutter` and `-balance` — a measurement has no page to fill; an unknown option is an error. With `-avoid` the call needs `-at`, because the shapes are page positions.

*doc* **textLines** *string* **-width** *w* ?*options*?

: The lines a paragraph would be broken into, with the same options and the same rules. Both calls also take the width as their first argument: `textLines $s 80` is the same as `textLines $s -width 80`.

## Graphics

*doc* **line -from** *{x y}* **-to** *{x y}* ?**-stroke** *c*? ?**-width** *w*?

*doc* **rect -at** *{x y}* **-size** *{w h}* ?**-radius** *r*? ?**-fill** *c*? ?**-stroke** *c*?

*doc* **circle -at** *{x y}* **-radius** *r* ?**-fill** *c*?

*doc* **ellipse -at** *{x y}* **-size** *{w h}* ?**-fill** *c*?

*doc* **polygon -points** *{x y x y ...}* ?**-close** *1*? ?**-fill** *c*?

*doc* **curve -from** *{x y}* **-c1** *{x y}* **-c2** *{x y}* **-to** *{x y}*

*doc* **path -segments** *list* ?**-fill** *c*? ?**-stroke** *c*? ?**-rule** *evenodd*?

: The shapes. Common options are **-fill** and **-stroke** (a colour), **-width** (line width, 0 or more — 0 is the thinnest line the device can draw), **-dash** (a pattern: a list of lengths of 0 or more, not all of them zero; `none` or `solid` for an unbroken line), **-cap** (`butt`, `round` or `square`), **-join** (`miter`, `round` or `bevel`), **-miter** (the miter limit: how far a pointed join may reach before it is cut to a bevel; 1 or more, and 1 bevels every join), **-opacity** and **-blend**. **-radius** is a length of 0 or more; on a rectangle it rounds the corners and 0 leaves them square. **-rule** takes `nonzero` (the default) or `evenodd` and decides which parts of a self-intersecting path count as inside; anything else is refused. **-from**, **-to**, **-at**, **-c1**, **-c2** are exactly two numbers. A segment of **-segments** is `{move x y}`, `{line x y}`, `{curve x1 y1 x2 y2 x y}` or `{close}`, in document coordinates, and a path begins with a `move`. **-close** joins the end of a `polygon`, a `curve` or a `path` back to its start; a polygon is closed by default, the other two are not. `circle` and `ellipse` are one command under two names: either takes **-radius** for a circle or **-size** *{w h}* for an ellipse, and **-at** is the centre. A shape that is refused — a point that is not a number, an unknown segment, an odd count of **-points** — leaves nothing behind in the page: the check comes before the first byte is written.

*doc* **clip -at** *{x y}* **-size** *{w h}* ?**-rule** *evenodd*? / *doc* **clip -segments** *list* ?**-rule** *evenodd*?

: Clips everything drawn afterwards to a rectangle or to an arbitrary path, until the graphics state is restored — so it wants a **save** around it. **-segments** takes the same list as **path**. The path itself is never drawn: it ends in `W n` instead of a painting operator and only decides what of the following output stays visible. **-rule** `evenodd` is what leaves the hole in a ring open; as on the shapes it takes `nonzero` or `evenodd` and nothing else. Give either **-at** with **-size** or **-segments**, not both.

*doc* **save** / *doc* **restore**

: Push and pop the graphics state (`q` and `Q`). A **restore** with no **save** open in the same stream is refused and writes nothing.

*doc* **transform** ?**-translate** *{dx dy}*? ?**-rotate** *deg*? ?**-scale** *s*? ?**-skew** *{a b}*? ?**-at** *{x y}*? ?**-matrix** *{a b c d e f}*?

: Multiplies the current transformation matrix. **-at** names a fixed point to turn, scale or skew about; **-translate** is a displacement. The two are different things and must not be confused. The parts compose as if called one after another — translate, then rotate, then skew, then scale — the way a sequence of `cm` operators does: a shape drawn afterwards is scaled first, skewed, turned, and displaced last, so the displacement is in unscaled, unturned document units, as it is in Canvas or SVG (`-translate {10 0} -rotate 90` moves 10 mm to the right, not 10 mm down). **-scale** is one factor or `{sx sy}`, none of them zero — a negative one mirrors.

  **-skew** shears by two angles in degrees: the first tilts vertically — y follows x — and the second horizontally, which is the slant an italic-looking stamp needs. **-matrix** takes the six numbers of a PDF matrix — exactly six, and not singular: a `cm` whose a·d − b·c is zero folds everything drawn after it onto a line, so it is refused before it is written — and multiplies them in as they stand, ignoring every other option: the values are the raw `cm` operands — points, origin at the bottom left, y upwards — for the caller who already has a matrix rather than wants one built.

*doc* **opacity** *value* ?*fill*|*stroke*|*both*?

: Fill and stroke opacity between 0 and 1. The second word limits it to one of the two — `both`, the default, sets fill and stroke alike. (PDF 1.4.)

*doc* **blend** *mode*

: The blend mode: how a colour is combined with what is already on the page. One of `Normal`, `Multiply`, `Screen`, `Overlay`, `Darken`, `Lighten`, `ColorDodge`, `ColorBurn`, `HardLight`, `SoftLight`, `Difference`, `Exclusion`, `Hue`, `Saturation`, `Color` or `Luminosity`. Like the alpha it is graphics state and holds until changed; the shapes take it per call as **-blend**, which keeps it inside their own save/restore. `Compatible` is refused — it has been deprecated since PDF 1.4 and means `Normal`. PDF/A parts 2 and 3 permit every mode listed. (PDF 1.4.)

*doc* **style** ?*options*?

: Sets the drawing state — the same options the shapes take, in force until changed: a `-width`, `-dash`, `-cap`, `-join`, `-miter`, `-opacity`, `-blend`, `-fill` or `-stroke` set here holds for every shape that does not name its own. The colours are the part worth spelling out: after `style -fill red -stroke blue` a bare `rect` is filled red and stroked blue, a `rect -fill green` is filled green and still stroked blue — a shape paints the sides `style` coloured plus the ones it names itself — and a `line`, which has no fill, is stroked blue instead of the black it draws in on its own; a `text` between them leaves them in force: it brackets its own colour. The state is that of the *stream*: **save** and **restore** take it back with the `Q`, a form or a pattern being built neither sees the page's colours nor leaks its own, and a new page starts fresh.

## Colour

A colour is a name (`red`, `steelblue` — 148 of them, without Tk), a hexadecimal triplet (`#ffd700`, or `#fd7`), a grey value, `{r g b}` between 0 and 1, `{c m y k}`, or a separation. Three and four numbers are told apart by their count; the space may be named instead — `{gray 0.5}` (`grey` as well), `{rgb 1 0.84 0}`, `{cmyk 0 0.16 1 0}` — which is the unambiguous form. Fills may also name a pattern: `{pattern sky}`. A name or hex triplet whose three components are equal — `black`, `white`, `gray`, `silver`, `#808080` — is written as DeviceGray, not as three equal RGB numbers: the picture is the same, but PDF/A allows DeviceRGB only under an RGB output intent (ISO 19005-2, 6.2.4.3) and DeviceGray under any, so the achromatic names stay usable in a document whose intent is CMYK — and `pdfa` refuses at the write whatever does not fit the intent, naming the call. Where colours have to share one space, as the stops of a shading do, a grey stop is promoted to the space of the coloured ones — `{white steelblue}` is an RGB gradient. Components outside 0..1 are clamped to the range, not refused.

A separation is a spot colour — a varnish, a security ink, a Pantone shade: `{separation Name alternate ?tint?}`. *Name* is the plate as the press will know it — a separation needs a name, and `All` and `None`, the special colourants of ISO 32000-1 8.6.6.4, are written as they stand; *alternate* is an ordinary colour in one of the three device spaces — grey, RGB or CMYK, never another separation or a pattern — what a reader that has no such ink shows instead; *tint* is the coverage from 0 to 1 and defaults to 1. `{separation Varnish {cmyk 0 0 0 0.2} 0.8}` paints 80 % of a plate called Varnish. The colour space object and its tint transform are written on first use, once per name, and fill and stroke may both use it; a name that appears again must carry the same alternate, since one plate is one ink. Under PDF/A the alternate follows the output intent like every other colour (ISO 19005-2, 6.2.4.4): a CMYK alternate needs a CMYK profile, an RGB one an RGB profile, grey passes anywhere — see `pdfa` for the check.

## Images

*doc* **image embed** *alias* ?*path*? ?**-data** *bytes*? ?**-type** *auto|jpeg|png*?

: Reads a JPEG or PNG and prepares it for placing. JPEG data passes through untouched as `/DCTDecode`; a PNG without alpha passes through as `/FlateDecode`. A PNG whose transparency is a single colour — a greyscale or truecolor file with a `tRNS` chunk, or a palette whose entries are either opaque or fully transparent and whose transparent entries form one contiguous run of indices — keeps that transparency as a `/Mask` colour-key array on the same pass-through, at the file's own bit depth; the reader keys the colour out, nothing is decoded. The one exception is a 16-bit greyscale or truecolor file: a `/Mask` array at sixteen bits is what the format asks for, but readers were measured to ignore it — poppler compares the ranges as if the image were 8-bit, and CoreGraphics renders the picture opaque too — so there the key is decoded once into an `/SMask` of 0 and 255; the picture itself still passes through at 16 bits, only the mask is computed. Only a PNG with an alpha channel, a palette with partially transparent entries or with transparent entries in more than one run, or such a 16-bit key is decoded to build an `/SMask`. (A PNG with a transparent colour needs PDF 1.3, one with an alpha channel or a computed soft mask 1.4, sixteen bits per component 1.5.) A progressive JPEG and an interlaced (Adam7) PNG are refused with the reason: JPEG data is embedded as it is and only baseline and extended-sequential files are taken — re-save as baseline; an interlaced PNG re-save without interlacing.

: **-data** takes the bytes instead of a file name — for an image that never was a file: a canvas posted from a browser, a plot from a subprocess, a value out of a database. The format is decided by the leading bytes in both cases, so nothing else changes; `image info` then reports an empty `path`. **A PNG with an alpha channel is by far the most expensive way in** — the channel has to be split out in pure Tcl, measured at about a hundred times the cost of the pass-through. Where transparency is not needed, JPEG or a PNG without alpha is the cheaper choice, and for a browser canvas that means `toDataURL("image/jpeg")`.

*doc* **image place** *alias* **-at** *{x y}* ?**-width** *w*? ?**-height** *h*? ?**-size** *{w h}*? ?**-scale** *s*? ?**-dpi** *n*? ?**-rotate** *deg*? ?**-opacity** *o*? ?**-alt** *text*? ?**-artifact** *bool*?

: Places an embedded image. Giving only one of width and height keeps the aspect ratio; **-size** sets both extents at once and keeps nothing. Without any of them the natural size applies, and **-dpi** decides it: a pixel is 1/dpi of an inch, and the default 72 makes one pixel one point — `-dpi 300` places a scan at the size it was scanned from. **-scale** multiplies that natural size and yields to any explicit width, height or size. **-width**, **-height**, the two lengths of **-size**, **-scale** and **-dpi** are numbers above zero — zero would fold the picture onto a line and a negative one place it mirrored beyond its corner, so both are refused; **image size** refuses the same values. **-at** is exactly two numbers, **-rotate** a number of degrees. The same image placed five times is stored once.

*doc* **image draw** ?*path*? ?**-data** *bytes*? **-at** *{x y}* ?*options*? ?**-alt** *text*? ?**-artifact** *bool*?

: Embeds and places in one call, for an image used once. It takes **-data** as well; with no file name to key the cache on, the bytes themselves are the key, so the same picture drawn twice still travels once. The options are those of **image place**, **-alt** and **-artifact** among them — what they do is described under *Structure and accessibility*.

*doc* **image info** *alias* / *doc* **image size** *alias* / *doc* **image names**

: What the file is, its size, and the aliases embedded so far. **image info** answers `type`, `path`, `bytes`, `width`, `height` and `bitDepth` for both formats; a PNG adds `colorType`, `alpha` and `transparency` — how the picture's transparency reaches the file: `none`, `colourKey` (a `/Mask` array, the picture still passed through) or `softMask` (an `/SMask`: an alpha channel, a palette with partial entries or with transparent entries in more than one run, or a 16-bit colour key), a JPEG adds `components` (1 grey, 3 RGB, 4 CMYK) and `alpha` 0. **image size** is the size a placement would come out at, in the document unit, and takes the same sizing options as **place** — what a caller needs to lay out around a picture. **image names** lists the aliases.

## Tables

*doc* **table -at** *{x y}* ?**-width** *w*? ?**-head** *rows*? **-body** *rows* ?**-foot** *rows*? ?*options*?

: Draws a table and returns the y coordinate below it. **-width** is the width of the table in the document unit; without it the table takes the page width less twice the larger of its left edge and 10 — 170 mm for a table at `-at {20 y}` on A4. A row is a list of cells; a cell is a string, or a dictionary with `text` and any of `colSpan`, `rowSpan`, `align`, `valign`, `direction` and style keys. `align`, `valign` and `direction` may equally be written inside `style`; on the cell itself they win over column, section and theme.

  `direction` is `ltr` or `rtl` and says which way that cell's text runs — a property of the cell rather than of the table, because an invoice has a right-to-left description column and a left-to-right amount column on the same row. Under `rtl` the cell's `align` is mirrored with it, so the default `left` sets the text flush with the right hand edge of the cell. See "Writing systems" for what a right-to-left line does and does not do.

  A row is as tall as its tallest cell. Where one cell carries running text over several lines and its neighbours hold a single line each, `valign` says where in the row those single lines sit — `top` by default, or `middle` or `bottom`. In a table whose rows are all one line it makes no difference, which is why the default is the one that leaves such a table alone.

  **Unknown keys are an error**, in a cell, in a style, and in a column description — as they already were among the `-options`. A dictionary written over defaults otherwise refuses nothing: a mistyped key is carried along, read by nobody, and the caller sees the default and no message. The values are checked as well: `align`, `valign` and `border` outside the lists below, a negative `padding` or `lineWidth`, a `leading` of 0 are refused, as is a `colSpan` reaching over a column no row has a cell in (unless **-columns** describes it) and a `rowSpan` reaching past the last row of its section.

  A cell is read as a dictionary when its **first** word is one of the cell keys and it has an even word count; anything else is the cell's text. Tcl draws no line between a string and a dictionary, so this is a decision rather than a detection, and it leaves one ambiguous case: a plain string that begins with `text`, `align`, `colSpan`, `rowSpan`, `valign` or `style` and happens to have an even word count is read as a dictionary. It then names the offending key rather than silently keeping a fragment of the sentence. Write such a string as a cell dictionary — `{text "text is set here"}` — and it is unambiguous.

  Column widths come in three kinds, resolved in that order: fixed (`{width 34}`), weighted (`{weight 1}`) and automatic — the rest is shared according to how wide the content actually is. Both keys take a number; there is no percent width, a share of the table is what `weight` is for. Fixed widths that add up to more than the table are refused, and so are fixed widths that use the table up while a further column has no width of its own — that column would come out zero wide.

  **-columns** describes the columns, **-theme** picks `striped`, `grid` or `plain` — their lines and grey fills are single DeviceGray values, the one space every PDF/A output intent allows (a grey given as an RGB triplet was the one failed check of a PDF/A file with a CMYK intent); the only colour a theme brings is the blue head of `striped`, an RGB value that is right in every plain PDF and under the default sRGB intent, and that a document with a CMYK or grey output intent (**pdfa -profile**) overrides with **-headStyle** `{fill {cmyk …}}`, or the write is refused under `pdfa`, naming a `rect` on that page (the table draws its cells through `rect`) — and **-style**, **-headStyle**, **-bodyStyle** and **-footStyle** set fonts, colours and padding. **-alternateFill** colours every second body row — the stripe the `striped` theme brings, replaceable with any colour; the other themes have none. **-minRowHeight** is the least height a row may take, for rows whose content alone would leave them shallower. The `border` style key takes `none`, `all`, `horizontal`, `vertical` or `outer`; `outer` frames the block once per page instead of ruling every cell. **-repeatHead** and **-repeatFoot** carry those sections onto each page. **-horizontalBreak** deals a table too wide for the page over further pages, with **-repeatColumns** keeping the leading columns on each.

  **-top** and **-bottom** are the type area a breaking table works within, which is not the same thing as where it sits. **-at** says where this table starts on its first page; **-top** says where it resumes on every page after that, and **-bottom** how far down it may run. Both default to the type area of the page the table is on (**page typeArea**) — with **-typeArea** the margins the document was given, without it five percent of the page height, 14.85 mm and 282.15 mm on A4 — read again on every page it continues on, so a table that starts on a landscape page and runs on to portrait ones keeps each page's own margins; and neither is taken from **-at**, because where a table happens to begin says nothing about where the page ends. Set **-top** to clear a running head, and **-bottom** to clear a footer. **-top** and **-bottom** are numbers; **-bottom** has to lie on the page and below **-top**, or the call is refused. A table is broken between rows and only there: a head, a row, or the rows a `rowSpan` ties together that — with the head and foot drawn around them on a page — do not fit between **-top** and **-bottom** are refused before anything is drawn, naming the heights and the band. A table whose head and first row (or head and foot, without body rows) do not fit below **-at** starts on the next page instead of leaving the head alone at the foot of the page, and the foot after the last row is kept inside **-bottom** the same way. **-minRowHeight** takes a height of 0 or more, **-repeatColumns** a whole number of 0 or more.

  `-align decimal` lines the decimal separators of a column up under each other, measured across head, body and foot together; **-decimal** picks the separator, `.` by default. A cell without the separator is aligned as if it ended at the separator, so integers line up with the integer parts of the other cells — `100` stands under the `1234` of `1234.56`, which is where a column of figures wants it — and a cell that is not a number at all sits there too.

  Rows tied together by a `rowSpan` are never split across a page break: the whole group moves.

  **Style keys.** A style is a dictionary of the keys below, and the same keys are read at every level: **-style** for the whole table, **-headStyle**, **-bodyStyle** and **-footStyle** for a section, a column description, and the `style` of a cell — laid over each other in that order, so the most specific wins. A theme is nothing but a set of these.

  | key | values | default |
  |---|---|---|
  | `family` | what **font -family** takes | `helvetica` |
  | `fontStyle` | what **font -style** takes: `bold`, `italic`, both, or empty | empty |
  | `size` | the font size, in points | `9` |
  | `leading` | line spacing as a factor of the size | `1.15` |
  | `padding` | space inside the cell, in the document unit | `1.5` |
  | `fill` | the cell background — a colour, or empty for none | empty |
  | `color` | the text colour | `black` |
  | `align` | `left`, `right`, `center` or `decimal` | `left` |
  | `valign` | `top`, `middle` or `bottom` | `top` |
  | `direction` | `ltr` or `rtl` | `ltr` |
  | `border` | `none`, `all`, `horizontal`, `vertical` or `outer` | `horizontal` |
  | `lineColor` | the colour of the rules | `{0.6 0.6 0.6}` |
  | `lineWidth` | the width of the rules, in the document unit | `0.1` |

  A **column** description in **-columns** takes the same keys plus `width` and `weight`, described above — `{width 20 align decimal}` is a fixed column of amounts. A **cell** dictionary takes `text`, `colSpan`, `rowSpan`, `align`, `valign`, `direction` and `style`, the last holding any of the keys above.

  Four hooks are called: **-didParseCell** once per cell before it is measured, **-willDrawCell** and **-didDrawCell** around drawing it, and **-didDrawPage** after each page. Each receives a dictionary and the document, in that order; returning 0 from `willDrawCell` skips that cell, and a dictionary returned from `didParseCell` replaces the cell.

  The dictionary a cell hook receives is the cell as the table holds it: the cell keys above, filled in — `text`, `colSpan`, `rowSpan`, `align`, `valign`, `direction`, `style` — plus `row`, `column` and `section` (`head`, `body` or `foot`), which is what `didParseCell` sees. `willDrawCell` and `didDrawCell` see the measured cell on top of that: `lines` (the text as broken), `width`, `height`, `leading`, `resolved` (the assembled style), `x` and `y` (the top left corner on the page), `spanHeight` for a cell spanning rows, and `decimal` and `tail` for the separator and the room its tail takes. `didDrawPage` receives `page`, the index of the page just finished, and `y`, where the table stopped on it — except after a page turn that a horizontal break forced, where only `page` is known.

*doc* **table layout** ?*same options*?

: Measures without drawing — what a caller needs to decide whether a table still fits.

*doc* **table themes**

: The names of the built-in themes: `plain`, `striped`, `grid`.

## Gradients and patterns

*doc* **shading axial -at** *{x y}* **-size** *{w h}* **-colors** *list* ?**-angle** *deg*? ?**-from** *{x y}*? ?**-to** *{x y}*?

*doc* **shading radial -at** *{x y}* **-size** *{w h}* **-colors** *list* ?**-center** *{x y}*? ?**-radius** *r*? ?**-innerRadius** *r*? ?**-focus** *{x y}*?

: Draws a gradient directly — shading types 2 and 3, clipped to the rectangle of **-at** and **-size**, which both forms require. More than two colours are stitched together. (PDF 1.3.)

  For an axial gradient, **-angle** turns the run: 0 is left to right, counting clockwise, so 90 runs top to bottom; the end points are derived from the rectangle. **-from** and **-to** name the two end points directly instead and win over **-angle** — for a run that starts or ends inside the rectangle, or one that does not pass through its centre.

  A radial gradient runs from an inner to an outer circle. **-center** and **-radius** describe the outer one — by default the middle of the rectangle and half its longer side. **-innerRadius** (default 0) is the radius of the inner circle and **-focus** its centre, the same as **-center** unless given; moved off it, the highlight of a sphere sits away from the middle. Both radii are lengths of 0 or more.

  **-stops** positions the colours: one value per colour, between 0 and 1 and strictly ascending — two equal stops are refused, as is a count that does not match **-colors**. Only the inner values have an effect — the first and the last colour sit at the ends regardless — so it matters from three colours on. Without it the colours are spaced evenly.

  **-extend** is a pair of booleans, `{1 1}` by default: whether the first and the last colour continue beyond the ends of the gradient or stop there. **-at**, **-size**, **-from**, **-to**, **-center**, **-focus** are exactly two numbers and **-extend** two booleans, checked before the shading is written.

  **-matrix** is accepted by both direct forms as well, and there it changes only how the coordinates are read: with it, **-from**, **-to**, **-center**, **-focus** and the radii are taken as they stand, in the space the matrix maps from, rather than converted from document coordinates — the gradient itself is painted in whatever transformation is active. Writing the matrix into the file is what the pattern form below does. The value is checked like every **-matrix** — six numbers, not singular — even though it is not written.

*doc* **shading pattern** *name* *type* ?*options*? ?**-matrix** *{a b c d e f}*?

: Registers a gradient as a pattern, usable afterwards as `{pattern name}` in any fill. *type* is `axial` or `radial`, and the options are the ones above.

  **-matrix** maps the gradient into the page. A pattern is bound to the default space of the content stream that carries it — the page here, a form’s own space inside a form — and ignores whatever transformation is active when the shape is painted (ISO 32000-2, 8.7.2) — filled under a transform, the shape lands in the right place and the gradient inside it somewhere else. A caller drawing under a transform passes that transform here — six numbers, not singular, checked before the shading itself is written; the coordinates are then read in the space the matrix maps from. A gradient placed without **-matrix** therefore belongs to the stream it was placed in: using it in another one — placed on the page, filled inside a `form create` script, or the other way round — is refused, because the right matrix would depend on where the form is placed and a form may be placed more than once, which is the one thing PDF does not carry over (the note beside 8.7.2). Define the gradient where it is used, or pass **-matrix** and say which space the numbers are in.

*doc* **shading names**

: The gradients registered so far, by name.

*doc* **pattern create** *name* **-size** *{w h}* ?**-step** *{sx sy}*? ?**-unit** *u*? ?**-matrix** *{a b c d e f}*? ?**-origin** *{x y}*? **-script** *body*

: A tiling pattern. Inside the script the tile is drawn like a small page, and every shape command works unchanged. (PDF 1.2.)

  **-step** is how far apart the tiles sit, the tile size unless given: equal, they touch; larger, and the background shows through between them — a sparse watermark rather than a hatch. Neither the size nor a step may be zero (ISO 32000-1 Table 75). **-unit** reads **-size** and **-step** in another unit than the document's.

  Pattern space hangs off the **content stream**, not off the shape being filled: a tiling pattern is bound to the default space of the stream that carries it — the page, or a form’s own space inside a form — and ignores whatever transformation is active when the shape is painted (ISO 32000-2, 8.7.2). Without a matrix the tiles are laid from the page's bottom left corner, and a rectangle anywhere else gets them cut at whatever phase falls on its edge. **-origin** anchors the tile grid at a point in document coordinates — the unit, y from the top, like **-at** — so a tile begins flush at that point; give the corner of the shape and the first tile sits square in it. **-matrix** takes the six numbers of a PDF matrix — exactly six, and not singular — and writes them as they stand: the raw pattern matrix (Table 75), points, origin at the bottom left, y upwards, for turning or scaling the tile or for a caller who already has the matrix. Both together are refused — a matrix carries its own translation. The matrix belongs to the pattern **object**, which is written once: the same hatch anchored at two corners is two patterns under two names. A tile anchored with **-origin** belongs to the stream it was created in and is refused in another one, the same way a gradient is; a tile with neither **-origin** nor **-matrix** has no place of its own and crosses freely — it lays from the corner of whatever space it lands in, which is what a hatch is for. **pattern size** answers the tile in pattern space, unscaled — a matrix that doubles the tile does not double the answer.

*doc* **pattern names** / *doc* **pattern size** *name*

: The registered tiling patterns, and the size of one of them as `{w h}` in the document unit, before any **-matrix**.

## Reusable content

*doc* **form create** *name* **-size** *{w h}* ?**-unit** *u*? **-script** *body*

: Defines a form XObject — a drawing stored once and placed as often as wanted. Inside the script the origin is the form's own **top left** corner and y counts downwards, the same way it does on a page. **-unit** reads **-size** in another unit than the document's. **-size** is two lengths above zero, checked before the script runs.

*doc* **form place** *name* **-at** *{x y}* ?**-scale** *s*? ?**-rotate** *deg*? ?**-opacity** *o*? ?**-alt** *text*? ?**-artifact** *bool*?

: Places it. **-scale** is a factor above zero, **-rotate** an angle in degrees, **-at** exactly two numbers; each is checked before anything is written. Placing is a transformation, not a redraw: the object stays one object in the file. Every form is written as an isolated transparency group (ISO 32000-1, 11.6.6), so **-opacity** fades the placement as one object: where shapes inside the form overlap, the one on top hides the one below at the given opacity, rather than each shape being faded on its own and the overlap coming out darker; and an opacity set inside the form applies within the group, so a translucent element there is faded by the placement too. The group names no colour space of its own: it composites in the colour space of the page it is placed on, which under PDF/A is the one the output intent describes. A group declaring `DeviceRGB` would count as a use of DeviceRGB, which ISO 19005-2 (6.2.4.3) allows only under an RGB output intent — so a document with a CMYK or grey intent (**pdfa -profile**) stays valid whatever profile it carries, and it makes no difference whether **pdfa** is called before or after **form create**. Documents set to a **-version** before `1.4` have no groups, and -opacity then applies per object.

*doc* **form names** / *doc* **form size** *name*

## SVG

*doc* **svg** *path* **-at** *{x y}* ?**-width** *w*? ?**-height** *h*? ?**-size** *{w h}*? ?**-scale** *s*? ?**-opacity** *o*? ?**-alt** *text*? ?**-artifact** *bool*?

*doc* **svg -data** *markup* **-at** *{x y}* ?*same options*?

: Draws an SVG as **real vectors** — paths, shapes, groups, transforms, `use`, text and gradients become PDF operators, not a picture. Returns `{x y width height}` of what was drawn. Without a size the drawing's own dimensions apply; with one it is fitted, keeping the aspect ratio. **-size** gives both extents at once, **-scale** multiplies the drawing's own size, and **-opacity** applies to the drawing as a whole. **-width**, **-height**, **-size** and **-scale** take values above zero; **-at** is exactly two numbers. `opacity`, `fill-opacity` and `stroke-opacity` are honoured; on a shape, `opacity` multiplies with the per-side values. A group element (`g`, `svg`, `a`, `switch`, `use`) with `opacity` below one becomes a **transparency group**: its children composite among themselves first and the alpha applies once to the result, so overlapping children stay exactly as light as a single one. That needs PDF 1.4; below it the alpha is refused with the version in the message, and it is PDF/A-clean under every output intent.

  **-data** takes the markup from a Tcl variable instead of a file, which is what a generator wants: whatever produces the SVG hands it over directly, with no temporary file in between. Everything else is the same, including **-alt** and **-artifact** — with a description the drawing becomes a `Figure` carrying it, without one an artifact, and **-artifact 1** says that this is what was meant.

  ~~~tcl
  set markup "<svg xmlns=\"http://www.w3.org/2000/svg\"\
      width=\"40\" height=\"40\">\
      <circle cx=\"20\" cy=\"20\" r=\"18\" fill=\"$colour\"/></svg>"
  $doc svg -data $markup -at {20 20} -width 12 -alt "Status: $state"
  ~~~

  Note that **svg size** below takes a file name only; the size of markup in a variable is what drawing it returns.

  **Text in a drawing uses the same faces as `text` does.** `font-family` is a comma-separated wish list and the first name that resolves wins; an **embedded** face resolves under the alias it was embedded as, so `font-family="house"` finds it after `font embed house …`. That settles three things at once: the drawing may use any character the face has rather than the 224 positions of WinAnsi — `Łódź` and `Москва` are ordinary labels, not errors —, it can be set in the house face, and it can be part of an **archivable** document, which embeds every font it finds. Kerning and ligatures apply as they do elsewhere.

  A list nobody can satisfy ends at `helvetica` rather than failing, which is what a drawing wants; in a PDF/A document that face is not embedded and `write` then refuses the document, so it is worth naming a face the document has. `font-weight` and `font-style` are not read — a face is chosen by name.

*doc* **svg info**

: What the LAST drawing skipped — the elements the module does not draw. It reports on the document, not on a file: anything written after **info** is accepted and ignored, so `svg info some.svg` says nothing about `some.svg`.

*doc* **svg size** *path*

: The natural size of an SVG file.

### Barcodes

tclpdf has no barcode encoder and does not need one. **tzint**, the Tcl binding for libzint, encodes into SVG, and `svg -data` draws that as real vectors — a MaxiCode keeps its hexagons and rings, and the digits under an EAN stay characters that can be copied. No temporary file is involved: the markup goes from one variable into the drawing.

tzint is **not a dependency**. It is a C extension and therefore platform bound; nothing in tclpdf requires it, and a document that never draws a barcode never notices it.

~~~tcl
package require tzint
::tzint::Encode svg markup "1234567890128" -barcode ean13
$doc svg -data $markup -at {20 20} -height 16 -alt "EAN-13 1234567890128"
~~~

Two things about the encoder are worth knowing, because neither is obvious and both cost an afternoon:

**The status is three-valued.** `0` means silence, **`1` to `4` are warnings with a perfectly good symbol**, and only `5` and up mean nothing was produced. Code that tests for "not zero" throws usable barcodes away — and on an error the target variable is not cleared but **left as it was**, so code that looks at the variable instead of the status quietly draws the previous barcode again. Both were measured: a Euro sign is a warning for `qrcode` and an error for `code128`.

~~~tcl
set rc [::tzint::Encode svg markup $data -barcode qrcode -stat info]
if {$rc >= 5} {
    error "no barcode: [dict get $info error]"
}
~~~

**An EPC-QR (GiroCode) needs `-eci 26`.** The dataset states its own character set in line 3, and without the option the encoder picks one itself — the symbol scans, but its encoding is not the one the data claims. `-security 2` is the error correction level the specification asks for.

For an **archivable** document the clear text line needs an embedded face, and the encoder names the one it wants: tzint writes `font-family="OCRB, monospace"` into its markup, so embedding a face under the alias `OCRB` is enough — the digits are then set in real OCR-B, stay text rather than becoming picture, and the markup is not touched. Where that face is not to hand, `-notext 1` leaves the line out and `text` sets it.

## Attachments, links and bookmarks

*doc* **attach** *path* ?**-name** *n*? ?**-mime** *m*? ?**-description** *d*? ?**-relationship** *r*? ?**-date** *d*? ?**-compress** *1*?

*doc* **attach -data** *bytes* **-name** *n* ?*same options*?

: Attaches a file. `-relationship` is the `/AFRelationship` value — `Alternative`, `Data`, `Source`, `Supplement` or `Unspecified`. (PDF 1.3.)

  **-mime** is the media type written as `/Subtype`, `application/octet-stream` unless given, and takes only `type/subtype`; **-description** goes into `/Desc`; **-date** is the modification date in `/Params`, a PDF date like `info CreationDate` takes; **-compress** is on by default. **-name** may not contain `/` or `\`; a name outside printable ASCII is written to `/UF` as text and to `/F` with such characters replaced by `_`. **-data** may be empty; it must be bytes (encode text first).

  **-data** takes the bytes instead of a file — for an attachment that never was one. **-name** is then required, because there is no file name to fall back on; without it the call is refused.

*doc* **attachments**

: What has been attached.

*doc* **link -at** *{x y}* **-size** *{w h}* ?**-url** *u*? ?**-page** *n*? ?**-structure** *name*? ?**-to** *{x y}*? ?**-zoom** *z*? ?**-tooltip** *t*?

: A link rectangle over an area of the page — to a URL, to a page of this document, or to a named structure element. It is drawn as nothing: the visible text is a separate call. (PDF 1.1.)

  **-page** is the page index, counted from 0 as `page current` counts — not the number printed on the page. The page need not exist yet: a link on the first page may point at a contents page added last, and the target is resolved when the document is written — a page that never came is then reported, naming the link. A negative index is refused at once. `bookmark -page` works the same way.

  **-url** is written in 7-bit ASCII as the format demands: whatever is outside it — an umlaut, a space — becomes `%XX` from its UTF-8 bytes, and a `%` already in the address is left alone, so an encoded URL is not encoded twice.

  For a page destination, **-to** names the point to land on and **-zoom** the magnification the reader applies there (`1` is 100 %); without **-zoom** the reader keeps the one it has, and without **-to** the whole page is fitted and **-zoom** does not apply.

  **-structure** takes the **-name** of a `structure` element and writes a structure destination (12.3.2.3), which names the element rather than a place on a page and therefore still lands on the right thing after the content above it has moved. PDF/UA-2 asks for internal targets to be written that way. It is written as a GoTo action carrying both the structure destination (/SD) and a page destination (/D) to the element's first page — /XYZ at the top of its first content, or /Fit when no position is known — so a reader that does not understand structure destinations still lands on the right page. It needs a tagged document and a 2.0 file (`ua -part 2` gives both). `bookmark` takes the same option.

  **-tooltip** becomes the annotation's `Contents`, which PDF/UA requires on every link (7.18.5): it is what a reader announces instead of just saying "link". Under PDF/UA the link annotation must also sit inside a `structure Link` (part 2: `Link` or `Reference`).

*doc* **bookmark** *title* ?**-page** *n*? ?**-at** *{x y}*? ?**-parent** *id*? ?**-open** *1*? ?**-structure** *name*?

: Adds an outline entry and returns its id, which can be the `-parent` of further entries. **-page** counts from 0, as `page current` counts, and defaults to the current page; as with `link -page`, the page need not exist yet — the target is resolved when the document is written, and a page that never came is then reported, naming the bookmark; a negative index is refused at once. Bookmarks are turned into objects when the document is written. **-open** decides whether the entry shows its children unfolded, and is on by default; `-open 0` collapses a branch until the reader asks for it. Each entry's `/Count` is the number of descendants a reader shows for it, not the number of its children, and the root counts everything visible at all levels (ISO 32000-1 12.3.3). The catalog then carries `/PageMode /UseOutlines`, so a reader opens the outline pane — unless a `catalogEntry PageMode` was set already.

*doc* **bookmarks**

: The outline built so far.

*doc* **destination** *page* ?*{x y}*? ?*zoom*? ?*asker*?

: A destination in PDF syntax (ISO 32000-1 12.3.2) — where a link or a bookmark points. `link -page` and `bookmark` build theirs through it; calling it directly is for a place the package does not write itself, and **catalogEntry** is the standing one: `catalogEntry OpenAction [$doc destination 1]` makes a reader open the document on the second page. *page* counts from 0 as `page current` counts — not the number printed on the page.

  Without a point the whole page is fitted (`/Fit`) and *zoom* does not apply. With *{x y}* — in the document unit, from the top left corner as every coordinate here — the reader lands on that point (`/XYZ`), and *zoom* is the magnification it applies there, `1` being 100 %; without *zoom* the reader keeps the one it has. The same three choices `link -to` and `-zoom` offer, because they end up here.

  For a page that exists the call returns the destination array itself; a *page* beyond the last is allowed and returns a reference to an object filled when the document is written — a link on the first page may point at a contents page added last. A page that never came is then reported, and the report names the *asker* when one was given — `link` and `bookmark` pass theirs, a direct caller may pass a word like `OpenAction` — and says `a destination` otherwise. A negative or non-numeric *page* is refused at once.

## Metadata

*doc* **info** *key* ?*value*?

: Reads or sets an entry of the information dictionary: the text keys `Title`, `Author`, `Subject`, `Keywords`, `Creator`, `Producer`; the two dates `CreationDate` and `ModDate`, which take a PDF date such as `D:20260818120000+02'00'` (ISO 32000-1, 7.9.4) and are refused otherwise; and `Trapped`, a name — `True`, `False` or `Unknown` (PDF 1.3). Each of the text keys goes into the XMP packet as well, under the property ISO 32000-1 Table 317 pairs it with: `Title` as `dc:title`, `Author` as `dc:creator`, `Subject` as `dc:description`, `Keywords` as `pdf:Keywords`, `Creator` — the application that made the document — as `xmp:CreatorTool`, and `Producer` — the writer, `tclpdf` unless replaced — as `pdf:Producer`. Without a `Creator` the creating tool in the packet is the producer. `CreationDate` and `ModDate` are mirrored into the packet as `xmp:CreateDate` and `xmp:ModifyDate`; `Trapped` is not — the predefined PDF schema of ISO 19005 has no `pdf:Trapped`, and veraPDF fails a PDF/A file that carries it.

*doc* **language** ?*tag*?

: The natural language of the document as an RFC 3066 tag — `de`, `de-DE`, `en-GB`. It goes into the catalog and is what lets a screen reader pronounce the text correctly. PDF/A-3a and PDF/UA require it. (PDF 1.4.)

*doc* **metadata** ?*xml*?

: Reads or sets the XMP packet directly. Normally the package writes it: set by the caller it is kept as given — as text, answered back unchanged, and encoded to UTF-8 once when the file is written, so `metadata [$doc metadata]` is a no-op; otherwise the packet is rebuilt on every write from the document's current title, language and declarations, so it never lags behind the Info dictionary. (PDF 1.4.)

*doc* **xmpSchema** *prefix uri tags method*

: Registers a schema that writes an `rdf:Description` of its own into the XMP packet each time the packet is built — the mechanism by which PDF/A and PDF/UA put their identification there, open to an extension with properties of its own to declare. *prefix* and *uri* name the schema and *tags* lists every property name it may write; a property answered but not listed fails the write. *method* names a method of the document object — an extension adds one with `oo::define`, see `doc/PLUGINS.md` in the source distribution — that is called when the packet is built and answers the properties as a list of *{kind tag value}* entries: kind `text` writes the value as the element's text, kind `bag` takes a list of tag-value pair lists and writes an `rdf:Bag` whose items carry them as resources. A method rather than the values themselves, because the values may change after registration — `pdfa -part 3` can follow — and a callback reads the state as it is at write time, so a second **write** stays truthful. An empty answer omits the description. Registration order is packet order, and registering a *prefix* again replaces its entry rather than adding a second one. Returns nothing.

  Both commands live in the `tclpdf::xmp` module, which every conformance claim loads; without one, `package require tclpdf::xmp` first — it needs tdom, as the packet does.

*doc* **xmpRaw** *xml*

: Adds ready-made XML to the packet, for what does not fit the tag-and-value form of **xmpSchema**: whole `rdf:Description` elements, appended under the packet's `rdf:RDF` as given — a PDF/A extension schema is a page of RDF no accessor could usefully model, and `pdfa extension` rides on this call. The `rdf` prefix may be used without declaring it, since the element around it always has; every other namespace the fragment must declare itself. The XML is parsed when the packet is built, and a malformed contribution fails the **write** naming itself rather than travelling on to a validator. The packet is built once a schema is registered — every conformance claim registers one — and a raw contribution alone does not cause that. Returns nothing.

*doc* **catalogEntry** *key* ?*value*?

: An entry of the document catalog, for anything the package does not offer by name.

## Structure and accessibility

*doc* **tagged** ?*0*|*1*?

: Whether the document writes a structure tree. **Off by default**, and it has to be set before anything is drawn — once a page has content, `tagged 1` is refused: the brackets go into the content stream as it is written. (PDF 1.4.)

  A tagged document carries a second, invisible layer saying what the marks on a page *are* — a heading, a paragraph, a table cell — rather than how they look. The drawing does not change. Reading software needs it: without a tree it follows the order the content stream happens to have, which on a two column page runs across both columns. PDF/UA and PDF/A level A require it.

*doc* **structure** *type* ?**-name** *name*? ?**-id** *string*? ?**-alt** *text*? ?**-lang** *tag*? ?**-title** *text*? ?**-actualText** *text*? ?**-expansion** *text*? ?**-scope** *side*? ?**-numbering** *style*? ?**-bbox** {*x y w h*}? ?**-colSpan** *n*? ?**-rowSpan** *n*? **-script** *body*

: Opens a structure element, runs *body* with it open and closes it again — including when the body fails, so a half open tree cannot reach the file. Returns whatever the body returned. *type* is one of the standard types of ISO 32000-1 14.8.4; an unknown one is refused at the call rather than in a validator later.

  Elements nest by nesting the calls. Grouping types — `Sect`, `Div`, `L`, `LI`, `Table`, `TR` and their kin — do not hold content themselves: text drawn inside an open `Sect` becomes a `P` **within** it, which is what the nesting rules ask for.

  **Most documents need few of these.** A table knows it is a table and a paragraph knows it is a paragraph, so those tag themselves; `structure` is for the grouping a writer cannot infer.

: **What is derived, and what has to be said.** `text` becomes a `P`, and one call is one element however many lines it breaks into. `table` becomes a `Table` with `TR`, `TH` and `TD`, and the fill and rules of its cells become artifacts. `image` becomes an artifact unless `-alt` describes it, and then a `Figure` carrying that description — or unless it is placed inside an open `Figure` (**structure Figure -alt … -script**), whose content it then is: the Figure's `-alt` covers it, and neither `-alt` nor `-artifact` is needed. Inside a form or a pattern `-alt` on an image, drawing or form placement opens no element; the invocation's `-alt` describes it.

  **-alt** appears on `image place`, `image draw`, `form place` and `svg` for the same reason and with the same effect: with it the drawing becomes a `Figure` carrying that description, without it an artifact. **-artifact 1** on the same four calls says that the artifact is intended — this one is decoration, and no description is missing. The two contradict each other and are refused together. The difference matters because an artifact is the one way real content passes a reader entirely, and PDF/UA allows it only for decoration: a graphic that became an artifact with neither option was never judged either way, and the document keeps a note of it — an artifact by default is what most pictures are, an artifact by intent is what a validator cannot ask for and a caller can say. In an untagged document neither option changes anything. A form or a drawing is one piece of marked content however many operators it contains — bracketing per element would scatter one illustration over dozens of leaves, and the parts of a drawing mean nothing on their own. Nothing inside a form, a pattern or a page-number XObject is marked at all: those are content streams of their own, mark numbers are unique per stream, and it is the *invocation* that carries the marking.

  A hyphen the line breaker inserted at a soft-hyphen offer is bracketed as a break rather than left to look like part of the word: it sits in a `Span` with an empty `ActualText`, so extracted text gives the word back whole (14.8.2.6). A hyphen the text brought with it is untouched — `E-Mail` stays `E-Mail`. Only in a tagged document.

  What no writer can infer is whether a line of text is a heading — neither its size nor its weight says so. That is what **-tag** on `text` is for: `-tag H1`, `-tag Caption`, and so on. Inside an open leaf element `-tag` names a child: `-tag Span` inside a `structure P` is a Span in that P, `-tag Caption` inside a `Figure` its caption; a type the open element may not hold (`-tag H1` inside a `P`) is refused naming both. `-tag P`, the default, marks the text as the open element's own. A grouping type (`Table`, `L`, `Sect`, …) is refused on `-tag`: open it with `structure`. `-tag Artifact` takes the text out of the tree altogether, which is what a running head or a page number needs; under PDF/UA anything left unmarked counts as a defect.

  The numbered headings are one of two forms. `H1` to `Hn` state the level themselves — a *strongly* structured document, and the form to write when the levels are known. The generic `H` leaves the level to the nesting: one `Sect` inside another, each opening with an `H`, and the depth of the element is the level — a *weakly* structured document (ISO 32000-1 14.8.4.4.2), which is what a converter honestly writes when its source nests sections without numbering them. A tree uses one form or the other, never both — mixed, the nesting and the numbers can disagree and no reader can choose. Under a `ua` claim the mixture is refused when the document is written (Matterhorn 14-006; measured, veraPDF fails it against ua1 under clause 7.4.4 and passes either form alone), and part 2 refuses the generic `H` altogether — ISO 32000-2 knows only the numbered headings. Example `05.14` writes a weakly structured document.

  **-expansion** *text* is the expanded form of an abbreviation (ISO 32000 14.9.5) — PDF/UA asks that abbreviations be expanded (7.20), and a reader that is asked reads the expansion out. On `structure` it goes onto the element as `/E`; on `text` — `text "EU" -expansion "European Union"` — the word becomes a `Span` carrying it, inside the paragraph that is open, or inside the one the call would have made. It needs a tagged document and is refused without one, and it cannot go on an artifact.

: **Attributes.** Five options write standard attributes onto the element, each one only where the standard allows it — used elsewhere they would be written and then ignored, so they are refused at the call instead.

  **-scope** takes `Row`, `Column` or `Both` and belongs on a `TH`; it says which way a header cell heads. A table sets it by itself: its head row heads columns. **-numbering** belongs on an `L` and takes `None`, `Disc`, `Circle`, `Square`, `Decimal`, `UpperRoman`, `LowerRoman`, `UpperAlpha`, `LowerAlpha` (ISO 32000-1 Table 347); in a 2.0 file also `Unordered`, `Description` and `Ordered` (ISO 32000-2 Table 369), which a 1.7 file refuses; PDF/UA makes it mandatory for an ordered list, and no writer can derive it — the label is drawn text, and `1.` and `-` look the same from here. **-bbox** belongs on a `Figure`, `Formula` or `Table` and takes the same four numbers as a rectangle; it is not required by the letter of the standard, but the reading tools rely on it. A picture placed with **-alt** gets one by itself. **-colSpan** and **-rowSpan** belong on a cell and are written by the table itself where it spans.

: **Types beyond 1.7.** ISO 32000-2 adds `Title`, `Aside`, `DocumentFragment`, `Sub`, `FENote`, `Em`, `Strong` and the headings `H7` to `H10`. They are accepted only in a 2.0 file — in a 1.7 one they would validate as non-standard types with no role map — and `ua -part 2` is the ordinary way to get one. As soon as one of them is used, the tree names the 2.0 structure namespace (`/NS` on every element that lives in it, and `/Namespaces` on the root) whether or not PDF/UA-2 is claimed; the twelve 1.7-only types keep the default. Twelve older types (`Art`, `BlockQuote`, `TOC`, `TOCI`, `Index`, `Private`, `Quote`, `Note`, `Reference`, `BibEntry`, `Code` and the generic `H` — the 2.0 namespace knows only the numbered headings) exist *only* in the 1.7 namespace and keep it even inside a 2.0 tree. Inline types — `Span`, `Quote`, `BibEntry`, `Em`, `Strong`, `Sub`, `Ruby`, `Warichu` — need an element that holds text around them (a `P`, a heading, a cell, a `Figure`); at the top level or straight in a `Sect` they are refused (ISO 32005 Table 5). `Reference` is refused at the top level only. **-lang** takes a language tag as `language` does (RFC 3066) and refuses anything else. **-script** may be an empty body — an element with nothing in it is a legitimate placeholder — but a missing `-script` is refused.

  A leaf type such as `P` or `H1` holds text and **inline** markup — `Span`, `Em`, `Strong`, `Link`, `Figure` and their kin — but no block element: a `P` inside a `P` is the standing example of what Annex L forbids.

: **Naming an element.** **-name** gives the element a name that a link or a bookmark points at with **-structure**. A structure destination names the *element* rather than a place on a page (12.3.2.3), so it still lands on the right thing after the content above it has grown — PDF/UA-2 asks for internal targets to be written that way. It is written as a GoTo action carrying both the structure destination (/SD) and a page destination (/D) to the element's first page — /XYZ at the top of its first content, or /Fit when no position is known — so a reader that does not understand structure destinations still lands on the right page. The name has to be unique and may be used before it is declared, which a link pointing forward at a later section needs. An unknown one is reported when the document is written, naming it.

  **-id** is something else: the element identifier of ISO 32000-1 14.7.2, a string written as `/ID` on the element and entered in the `IDTree` of the structure tree root, by which a reader — not this package — looks the element up. It has to be unique in the document. A `Note` gets one on its own when none is given (`Note` followed by its position in the tree), because PDF/UA-1 asks every note for one (7.9); every other element has one only when asked.

: **Artifacts name their kind.** What is not in the tree is bracketed as an artifact, and the bracket says which sort it is: `Pagination` for a page number, `Layout` for everything else this package produces. PDF/UA-2 requires the naming; earlier versions permit it, so it is written either way and a document does not have to be redrawn when it is upgraded.

  **-tag** takes the kind as well, as a list: `-tag {Artifact Pagination Header}` marks a running head, `{Artifact Pagination Footer}` a running foot, which is what PDF/UA asks for (7.8). The kinds are the four of ISO 32000-1 Table 330 — `Pagination`, `Layout`, `Page` and `Background` — and only `Pagination` takes a subtype: `Header`, `Footer` or `Watermark` (Table 331). Anything else is refused at the call. `pageNumbers` works it out by itself — above the middle of the page it is a head, below it a foot — because that is the one place that knows.

## PDF/UA

*doc* **ua** ?*0*|*1*? | *doc* **ua** ?**-part** *1*|*2*? ?**-revision** *year*? ?**-wtpdf** *levels*?

: Declares PDF/UA conformance — the promise that the document can be used by someone who cannot see the page. The boolean form means part 1 (ISO 14289-1) and is what a letter, an invoice or a briefing needs; part 2 (ISO 14289-2) is a PDF 2.0 format and is asked for by name. Part 1 lifts the file to PDF 1.7 and part 2 to 2.0, through `configure`, and the version cannot be lowered again afterwards. Part 1 does not cap the version — a document may move on to part 2 — but a part-1 claim on a file that was raised to 2.0 is refused when the file is written (ISO 14289-1, 6.1: the header is `%PDF-1.n`), naming part 2 as the way out. `ua 0` withdraws the claim and everything it contributed — the schema, `DisplayDocTitle` where `ua` set it, the namespace demand; the file version stays raised.

  **Off by default and explicit**, as `pdfa` is. The claim is legally meaningful in public procurement, so nothing should acquire it as a side effect — and a document using the standard 14 faces cannot make it at all.

: **What it insists on, checked when the file is written.** A title (`info Title`), a language (`language`), every font embedded — the standard 14 included, which is stricter than PDF/A and rules out Symbol and ZapfDingbats entirely, as neither has an embeddable representative. Headings starting at `H1` with no level skipped, and one kind of heading throughout: a tree that mixes the generic `H` with numbered ones is neither weakly nor strongly structured and is refused (ISO 14289-1, 7.4.4; Matterhorn 14-006). Tables whose rows all cover the same number of columns, spans counted — a `colSpan` covers as many columns as it says and a `rowSpan` covers its column in the rows below (Matterhorn 15-003, UA-2 8.2.5.26); a table whose rows still differ is refused. A description on every link, which is what `link -tooltip` writes, and every link annotation inside a `Link` element (part 2: `Link` or `Reference`). Every picture, drawing and form placement either described with **-alt** or declared decoration with **-artifact 1** — one that became an artifact with neither was never judged, and an artifact may carry nothing a reader needs (7.1). Lists whose numbering and labels agree (7.6): an `L` with **-numbering** other than `None` needs a `Lbl` in every `LI`, and items carrying a `Lbl` need the `L` to say what they are — `Decimal`, `Disc`, … or `None`. `DisplayDocTitle` still on: **ua** sets it, and a later `viewerPreferences -displayDocTitle 0` is refused rather than written. Part 2 adds a `Desc` on every attachment and forbids the generic `H` and `Note` (use `FENote`).

  All of them are reported at once rather than one per run, and each message names the call to change. Writing fails; no file is left behind.

: **What it contributes by itself**: the `pdfuaid` schema in the XMP, `ViewerPreferences` with `DisplayDocTitle`, and for part 2 the 2.0 structure namespace and the file version. None of them moves a mark on a page. In a document that also declares PDF/A, the PDF/A extension schema describing `pdfuaid` is written as well — without it PDF/A refuses a schema it does not know.

  **-revision** is the year of the edition claimed, four digits, and goes into the metadata as `pdfuaid:rev` for part 2 (ISO 14289-2 Table 1); the default is 2024, the year part 2 was published. Anything that is not a four-digit year is refused at the call.

  **-wtpdf** adds a Well-Tagged PDF declaration and takes `reuse`, `accessibility` or both. It goes with part 2 only. The identifier is written in two spellings: WTPDF 1.0 gives the URI with a slash before the fragment, veraPDF 1.30 tests for the form without one, and a document that has to satisfy both carries both — which the declaration mechanism expressly allows.

: **PDF/UA-2 and PDF/A-3 cannot be combined.** Part 2 needs PDF 2.0, PDF/A-3 is a 1.7 format, and so an accessible ZUGFeRD invoice is `ua 1` together with `pdfa -part 3`. Declaring both is refused at the call that creates the contradiction.

*doc* **ua state**

: What has been declared, as a dictionary: `part`, `revision`, `wtpdf`, `registered`. Empty before **ua** was called. `ua state` answers `part`, `revision`, `wtpdf` and `registered`; none of them is an option of `ua` — `ua -registered 1` is refused as unknown.

## Viewer preferences

*doc* **viewerPreferences** ?**-key** *value* ...?

: How a reader should present the document (ISO 32000 12.2). Without arguments it answers with what has been set so far. (PDF 1.2; `-direction` 1.3, `-displayDocTitle` 1.4, the value `UseOC` 1.5, `-printScaling` 1.6, `-duplex`, `-pickTrayByPDFSize` and `-numCopies` 1.7.)

  Calls accumulate: each one sets the keys it names and leaves the rest alone, so a document can state its window wishes in one place and its printing wishes in another.

  Booleans: **-hideToolbar**, **-hideMenubar**, **-hideWindowUI**, **-fitWindow**, **-centerWindow**, **-displayDocTitle**, **-pickTrayByPDFSize**. Names: **-nonFullScreenPageMode** (`UseNone`, `UseOutlines`, `UseThumbs`, `UseOC`), **-direction** (`L2R`, `R2L`), **-printScaling** (`None`, `AppDefault`), **-duplex** (`Simplex`, `DuplexFlipShortEdge`, `DuplexFlipLongEdge`). And **-numCopies**, an integer from 2 to 5 — the values ISO 32000-1 Table 150 says a reader supports; anything else is refused rather than written to be ignored.

  A misspelled value is refused at the call. It has to be: a reader that meets one falls back to its default silently and nothing anywhere reports a problem — the document simply prints on one side for the rest of its life.

  `ViewArea`, `ViewClip`, `PrintArea` and `PrintClip` are deliberately absent, and so is `PrintPageRange`. The four are deprecated in PDF 2.0 and no reader tested here acts on them.

## Page labels

*doc* **pageLabels** / *doc* **pageLabels -from** *index* ?**-style** *s*? ?**-prefix** *text*? ?**-start** *n*?

: What a reader calls each page (ISO 32000 12.4.2). A page has two numbers — the index the file counts it by and the number printed on it — and a reader shows the first unless the file says otherwise; then "go to page 3" lands on the third sheet while the sheet reading "3" is the sixth. One call is one range: it begins at the page **-from**, an index counted from 0 like everywhere else, and runs until the next range begins. Several calls make several ranges, in whatever order they come; a second call for the same index replaces the first. Without arguments it answers the ranges set so far, as a dictionary from index to `style`, `prefix` and `start`, in page order. (PDF 1.3.)

  **-style** takes `D` (decimal, the default), `R` and `r` (roman), `A` and `a` (letters), or `none` for a range that carries a prefix and no number — a cover called "Cover". **-prefix** is put before the number, **-start** is the number the range begins with, a positive integer, 1 unless said otherwise. A misspelled style is refused at the call, because a reader that meets one ignores it silently.

  The tree has to begin at index 0. A document that labels only its body from page 4 on has said nothing about the pages before, so a range without a style is put in front — the standard's own way of saying "no number here" — rather than writing a tree a reader may refuse.

  Labels and printed numbers have to agree: Matterhorn 15-001 counts a visible page number that differs from the page label as an accessibility failure, and it is one no validator can see, because the printed number is drawn text. Nothing here is automatic — a document that prints its numbers with `pageNumbers -from 3` should say `pageLabels -from 0 -start 3` as well, so that the reader's page field shows what the sheet shows.

## PDF/A and ZUGFeRD

*doc* **pdfa** ?**-part** *n*? ?**-conformance** *level*? ?**-profile** *path*? ?**-identifier** *text*?

: Declares PDF/A conformance, writes the output intent with the given ICC profile and raises the file version to match — through `configure`, so `cget -version` answers 1.7 afterwards, and the version can be neither lowered nor raised to 2.0 again — PDF/A-2 and -3 are PDF 1.7 formats (ISO 19005-2/-3, 6.1.2: the header is `%PDF-1.n`), so `configure -version 2.0` after `pdfa` is refused naming the claim, as `pdfa` after `-version 2.0` is. Parts 2 and 3 are accepted; part 1 is refused because it forbids the transparency this package writes, and part 4 because it needs PDF 2.0. Part 2 admits no embedded file that is not itself PDF/A (ISO 19005-2, 6.8): `pdfa -part 2` on a document with attachments is refused, and so is `attach` under a part-2 claim — use part 3.

  Without **-profile** the sRGB profile shipped with the package is used, so every PDF/A file carries an output intent — this package paints in DeviceRGB, and ISO 19005 requires the intent for that. The output condition identifier is read from the profile's own `desc` tag, falls back to the file name, and **-identifier** overrides it; the shipped profile is named `sRGB IEC61966-2.1`, the colour space it implements, as it always was. A profile that does not exist is refused at the call. So is a file that is no ICC profile (no `acsp` signature) or one describing a space other than grey, RGB or CMYK. The path is normalized on the way in; `pdfa state` answers the normalized path. A second profile ships beside it for print work in process colours: `icc/ISOcoated_v2_bas.ICC` (basICColor's ISO Coated v2, FOGRA39, zlib licence — the file `LICENSE-ZLIB-bICC` next to it is the grant), a CMYK output intent that a document painting in `{cmyk …}` names with **-profile** — and `icc/ISOcoated_v2_grey1c_bas.ICC`, its grey component, for a document that paints in grey alone (example `05.10`); and `icc/sRGB2014.icc`, the ICC's own sRGB profile of 2015, beside the default so that the two can be compared — examples `05.11` and `05.12` write the same page under each and print the profile facts; same primaries and tone curve, D50 white point with a `chad` tag against the older D65 without one, and in the file both compress to much the same size; the intent may describe grey, RGB or CMYK, and the package's own objects — the transparency groups of forms among them — name no colour space that could contradict it. Example `05.09` writes such a file.

  **-conformance** takes `B` (the default), `U` or `A`. Level B promises the document looks the same in fifteen years; level U adds that its text can be extracted and searched reliably, which rests on the ToUnicode map written for every embedded face anyway — so `U` is the stronger claim at no cost and is worth asking for. Level A adds the structure tree, so it needs `tagged 1` before anything is drawn; asked for without it, `pdfa` names the missing call rather than writing a file that claims 3a and fails validation.

  Declaring conformance also turns on a check: every font in the document must be embedded, and writing fails with a message naming the offending face rather than producing a file that a validator rejects later. The same is true of colour: ISO 19005-2, 6.2.4.3 admits DeviceGray under any output intent, DeviceRGB only under an RGB one and DeviceCMYK only under a CMYK one, and the rule reaches every road a colour takes — fills and strokes, text, a picture's colour space (an Indexed PNG counts as RGB, a CMYK JPEG as CMYK), a shading, the content of a tiling pattern or a form, and the alternate of a separation (6.2.4.4). The package keeps a record of which spaces the document uses and where, whether or not `pdfa` was declared, and holds it against the profile when the file is written: a `{cmyk …}` fill under the shipped sRGB profile, or a `steelblue` under `icc/ISOcoated_v2_bas.ICC`, is refused with the calls and pages that used it — `used by rect on page 1, text on page 2` — and the two ways out named: paint in the intent's space or in grey, or give a profile of the space you paint in. Every offending space is listed at once, and the check does not depend on whether `pdfa` came before or after the drawing. Measured against veraPDF: what is refused here is exactly what fails there.

*doc* **pdfa state**

: What has been set, as a dictionary: `part`, `conformance`, `profile`, `identifier`, `extensions` and `registered`. Empty before **pdfa** was called. `registered` and `extensions` are state, not options — `pdfa -registered` is refused as unknown.

*doc* **pdfa extension** *xml*

: Adds an extension schema to the XMP packet — the way a profile such as ZUGFeRD announces its own properties. `zugferd` uses it. It needs a `pdfa` call before it; without one it is refused rather than declaring PDF/A-3B by itself.

*doc* **zugferd** *path* ?**-name** *n*? ?**-profile** *p*? ?**-type** *t*? ?**-icc** *path*? ?**-version** *v*? ?**-relationship** *r*? ?**-description** *d*? ?**-compress** *0*?

: The one call an electronic invoice — or an Order-X order, see below — needs. It reads the profile from the invoice XML (BT-24), declares PDF/A-3B, writes the output intent with the sRGB profile shipped with the package, adds the Factur-X XMP extension schema, and attaches the file as `factur-x.xml` at document level with the `/AFRelationship` the profile prescribes — `Data` for MINIMUM and BASIC WL, `Alternative` for every fuller profile; `-relationship` overrides — plus an entry in the names tree and a modification date. Returns the detected profile.

  **-name** is the name a reader looks the attachment up by, and the standards allow exactly four: `factur-x.xml`, `zugferd-invoice.xml` and `xrechnung.xml` for an invoice, `order-x.xml` for an order. Without the option the file's own name is kept where it is one the document's family allows, and `factur-x.xml` — `order-x.xml` for an order — is taken otherwise; any other **-name** is refused, and so is a name of the other family: an invoice is never `order-x.xml`, an order nothing else. **-type** goes into `fx:DocumentType`: `INVOICE`, `ORDER`, `ORDER_RESPONSE` or `ORDER_CHANGE`; anything else is refused. Without the option the type follows BT-24 — `ORDER` for an Order-X identifier, `INVOICE` for every other — and a response or change has to be named. **-description** replaces the attachment description, which is "*profile* `invoice data`" — "*profile* `order data`" for an order — unless given. **-compress** Flate-compresses the embedded XML and is **off by default**, so the invoice sits in the file byte for byte as it arrived.

  **Order-X** (Order-X 1.0, 4.1.1 and 4.1.2) rides on the same call: BT-24 `urn:order-x.eu:1p0:basic`, `:comfort` or `:extended` is read as `BASIC`, `COMFORT` or `EXTENDED`, the document becomes an `ORDER` unless **-type** says `ORDER_RESPONSE` or `ORDER_CHANGE`, the XML is embedded as `order-x.xml` — the one name the standard allows — with `/AFRelationship` `Data` by default, and the extension schema is written under the Order-X namespace URI, `urn:factur-x:pdfa:CrossIndustryDocument:1p0#`, without the `:invoice` of Factur-X. **-relationship** may say `Source` or `Alternative` instead, the two other values 4.1.1 permits for `order-x.xml`; `Supplement` and `Unspecified` are for the other attachments and refused here. Levels, types and names are bound to their family — invoice: `MINIMUM`, `BASIC WL`, `BASIC`, `EN 16931`, `EXTENDED`, `XRECHNUNG` under `INVOICE`; order: `BASIC`, `COMFORT`, `EXTENDED` under the three order types — and a **-profile** or a BT-24 identifier of the other family is refused naming both, so that a Factur-X BASIC invoice cannot go out labelled an order at BASIC or the other way round.

  **PDF/A-3B is fixed at this call** — the level every invoice reaches without a structure tree, and the least the standards ask for. A document that wants more says so afterwards: `pdfa -conformance U` after `zugferd` raises the claim to 3U with the Factur-X extension in place, and `A` needs `tagged 1` besides — measured, the file then validates against the higher profile. **-icc** names another output intent profile in place of the shipped sRGB one — a CMYK profile for an invoice painted in process colours, see `pdfa -profile` — and the colours are held against it at write time like everywhere else. **-profile** overrides the level read from BT-24 (`MINIMUM`, `BASIC WL`, `BASIC`, `EN 16931`, `EXTENDED`, or `XRECHNUNG`, which is what an XRechnung identifier is read as; `BASIC`, `COMFORT` or `EXTENDED` for an order), for an XML whose identifier the reader does not recognise — any other word is refused, because it would go into the XMP as a conformance level nobody validates against; with **-profile** given BT-24 is still read for the family where it names one, so an Order-X XML stays an order, and with **-profile** and **-type** both given it is not read at all; **-version** is the `fx:Version` written to the XMP, `1.0` unless given, and takes digits and dots only. Every option is checked before the document is changed; a refused `zugferd` leaves no PDF/A claim, no schema and no attachment behind.

*doc* **zugferd profile** *xml*

: The conformance level named in BT-24 of an invoice or order XML — the XML itself as a string of bytes, not a path — read without writing anything: `EN 16931` for the EN 16931 identifier, `COMFORT` for `urn:order-x.eu:1p0:comfort`. Refuses XML that carries no such identifier or one the reader does not know.

*doc* **zugferd state**

: What was attached and under which profile: `name`, `profile`, `type`, `version`, `relationship` — the `/AFRelationship` that was written, prescribed by the profile or given — and `bytes`. Empty before the call.

## Writing

Two calls write the document, and neither finishes it.

**PDF 2.0 differences that are written for you.** A 2.0 file spells the zone offset of a date without the trailing apostrophe (7.9.4), and the version decides it — declaring `ua -part 2` is enough. `ProcSet`, `CharSet` and `CIDSet`, all deprecated in 2.0, are written by no version of this package.

*doc* **write** *path*

: Writes the document to a file. Writing does not finish the document: a second **write** of an unchanged document produces a byte-identical file, and drawing between two writes works - the second file carries the additions.

*doc* **writeChannel** *channel*

: Writes to an open channel instead of a file — a CGI response, a socket, a pipe. The caller opens and closes it; the channel is put into binary translation here, because that is what decides whether the bytes arrive unchanged. The cross-reference offsets are counted from the `%PDF-` header as they are written, not asked of the channel, so a pipe or a socket — where `tell` answers −1 — and a channel that already carries a CGI header get a correct table. **write** and **writeChannel** may be combined freely — the same document can go to a file and into a response.

## Events

*doc* **on** *event script* / *doc* **off** *token* / *doc* **subscribers** *event*

: The document publishes events while it is written: `beforeWrite`, `resources`, `catalog`, `info` and `afterWrite`, plus `pageAdded` after each `page add` — the ones **text -paginate** and a breaking **table** add included. This is how attachments, ZUGFeRD and the output intent attach themselves without the core knowing about them, and it is available to callers for the same purpose. **on** returns a token and refuses an event that is not one of these six, naming them; **events** answers the list. **off** takes that token, not the event and script again, and accepts an unknown one silently. Subscribers run in registration order and are called with the emitting object followed by whatever the emitter passes on. The write-time events fire on **every** write, so a subscriber that creates objects must be idempotent: take its object numbers from **reservation** once and write over them on later runs, instead of reserving fresh ones each time. How to build an extension on top of this — the supported methods, the contracts and two worked examples — is the subject of `doc/PLUGINS.md` in the source distribution.

# SEE ALSO

tdom, qpdf(1), veraPDF, pdffonts(1), pdftotext(1), tzint

tdom builds the XMP metadata packet — every document that declares PDF/A, PDF/UA or ZUGFeRD needs it — and, where present, parses SVG in place of the built-in parser; see "Optional packages" at the top.

tzint is a Tcl binding to the Zint barcode library. It produces SVG, which `svg -data` draws — so barcodes need no code in this package and are not a dependency of it. See the `Barcodes` section above.

# KEYWORDS

pdf, pdf/a, pdf/ua, zugferd, factur-x, truetype, font embedding, invoice, accessibility, barcode

# COPYRIGHT

Copyright (C) 2026 Alexander Schoepe, Bochum, DE

Distributed under the MIT License; see the file `license.terms`.
