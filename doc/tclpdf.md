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

What is documented below is what the package provides — nothing here is planned or partial. Roughly a third of ISO 32000-1 is covered, weighted by the page count of its chapters; the remainder is almost entirely what a **reader** of foreign PDFs needs rather than a writer, plus encryption, form fields and tagged PDF.

# REQUIREMENTS

Tcl 8.6.11 or newer. The package also runs under Tcl 9 — note that this requires the open-ended form of the version requirement, since `package require Tcl 8.6` is rejected by Tcl 9 with a version conflict.

The core needs nothing beyond Tcl itself. In particular **zlib** is a built-in command rather than a package, so it must not be requested with `package require`: the dummy package of that name exists only in Tcl 8.6.

**Tk is not required and is never loaded.** Two conveniences would pull it
in and are therefore avoided: resolving colour names via `winfo rgb`, and decoding images via `image create photo`. tclpdf carries its own colour table and its own image parsers.

# OPTIONAL PACKAGES

**tdom**

: Used by the SVG module for parsing, and preferred when present: measured, tdom parses 27 to 48 times faster than the parser tclpdf brings along, and it rejects an entity expansion bomb that the built-in one would try to expand. Without tdom the package still reads SVG, through its own element tree parser — the same four accessors sit in front of both, so nothing else in the package can tell the difference.

Nothing else is optional, because nothing else is used. Encryption and barcodes are planned work; this page will name the packages they need once they exist.

# COMMANDS

## Creating a document

**tclpdf new** ?*option value* ...?

: Creates a document object and returns its command name. Options: **-unit** (`mm`, the default, or `pt`, `cm`, `in`), **-format** (a page format name such as `a4`, or a pair of numbers in the document unit), **-orientation** (`portrait` or `landscape`), **-version** (`1.0` through `1.7`, or `2.0`; default `1.7`) and **-compress** (`1` by default — content streams are deflated; `0` writes them plainly, which is for reading the output, not for shipping it).

  A size given as two numbers is taken as it stands. It is turned only if an orientation is asked for as well — `{88 55}` stays 88 by 55.

**tclpdf formats**

: The known page format names.

*doc* **configure** ?*option value* ...?

: Changes the document options after creation. It returns nothing; read a single option with **cget**. A page already added keeps the size it was given.

*doc* **cget** *option*

: One option.

*doc* **destroy**

: Releases the object. A document that was written is not needed afterwards.

## Coordinates and units

Positions are given in the document unit, and **y counts from the top of the page downwards** — the opposite of PDF's own convention, which the package converts on the way out. `-at` always names the **top left** corner of what is being placed. A form or a pattern script is no exception: inside them the origin is that object's own **top left** corner and y counts downwards, exactly as on the page — the conversion happens against the object's height instead of the page's.

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

: Reads or sets one of the five page boxes: `media`, `crop`, `bleed`, `trim` or `art`. The value is `{x y width height}` in the document unit. A box may start away from zero; the size is then the difference, and the caller's origin follows the box rather than the axis.

*doc* **page content** ?*index*?

: The content stream built for that page so far, as text. For diagnosis: it shows which operators a call actually produced, which is the only way to see a graphics state that leaks past the shape that set it.

## Text

*doc* **font** ?**-family** *f*? ?**-style** *s*? ?**-size** *n*? ?**-color** *c*? ...

: Sets the font state, which stays in force until changed. Without arguments it returns the current state as a dictionary, including the resolved font name.

  **-family** takes one of the fourteen standard faces (`helvetica`, `times`, `courier`, `symbol`, `zapfdingbats`), an exact PostScript name such as `Times-Italic`, or the alias of an embedded face. **-style** takes `bold`, `italic` or both. **-size** is always in points. Further options: **-spacing** (extra space between glyphs — see below), **-wordSpacing**, **-stretch** (horizontal scaling in percent), **-leading** (line spacing, default 1.2 times the size) and **-rise** (baseline shift, for super- and subscript).

  **-spacing** adds its space **between glyphs**, not between characters, because that is where the PDF operator behind it puts it. The two differ only when ligatures are in play: `office` is six characters and, in a face that has the `ffi` ligature, four glyphs — so `-spacing` opens three gaps there, not five. For classic letterspacing, where every letter stands apart, set **-ligatures 0** in the same call; a ligature says the letters belong close together, which is the opposite of what letterspacing says.

  **-ligatures** applies the standard ligatures (`liga`) of an embedded face and is **on by default**. Where a face has one, the letters of `fi`, `ff`, `ffi` and their relatives are drawn as the single glyph the designer made for them. The characters are unaffected: the `ToUnicode` map carries the ligature back to the letters it was made from, so the text is copied and searched as it was written. Only `liga` is read - not the discretionary (`dlig`) or historical (`hlig`) sets, which the feature registry has off, and not the required ligatures (`rlig`) of the Arabic scripts, which need a shaper this package does not have. Note that a ligature need not change any width: measured on DejaVu Sans, `fi` and `fl` take exactly the room the two letters took, while `ff` is narrower.

  **-kerning** applies the pair kerning of an embedded face and is **on by default**. The amounts are read from the font while writing - from its GPOS table where it has kerning lookups, otherwise from its `kern` table, which is the order ISO/IEC 14496-22 prescribes - and are written into the content stream, so neither table is embedded. Kerning changes the width of every line it touches, and the width is measured with it: `textWidth`, the line breaker and the table column widths all see the kerned figures. Set **-kerning** to 0 where a document has to come out exactly as an earlier release produced it. The fourteen standard faces are unaffected: the metrics shipped for them carry widths per byte value, not kerning pairs.

  A combining accent between two letters does not interrupt a pair. Most faces tell the reader to leave marks out of the sequence while kerning - measured here, 51 of the 73 faces on this machine that kern from GPOS do - so `A` + U+0301 + `V` is kerned as the pair `A V`, exactly as the single character U+00C1 followed by `V` has always been. The adjustment is applied in front of the second letter, which leaves the accent where the font puts it. What tclpdf does not do is position the mark itself: GPOS mark attachment is not read, so a combining glyph is drawn at the pen position with the side bearing its face gives it.

*doc* **font embed** *alias path* ?**-subset** *0*?

: Embeds a TrueType file under an alias, subset to the glyphs actually used. The alias is then usable as **-family**.

: **Which file to embed for a standard face.** A document that has to be
  archivable may not leave a font unembedded, and that includes the fourteen
  standard faces — PDF/A makes no exception for them. Their outlines were never
  released, so an equivalent has to take their place. The table below maps each
  of the fourteen to the file that stands in for it.

  | PDF standard 14 | URW Core 35 | Adobe Type 1 | Adobe OpenType | macOS | Windows |
  |---|---|---|---|---|---|
  | Helvetica | `NimbusSans-Regular.ttf` | `Helvetica.pfb` | `HelveticaLTStd-Roman.otf` | Helvetica | `Arial.ttf` |
  | Helvetica-Bold | `NimbusSans-Bold.ttf` | `Helvetica-Bold.pfb` | `HelveticaLTStd-Bold.otf` | Helvetica Bold | `Arialbd.ttf` |
  | Helvetica-Oblique | `NimbusSans-Oblique.ttf` | `Helvetica-Oblique.pfb` | `HelveticaLTStd-Obl.otf` | Helvetica Oblique | `Ariali.ttf` |
  | Helvetica-BoldOblique | `NimbusSans-BoldOblique.ttf` | `Helvetica-BoldOblique.pfb` | `HelveticaLTStd-BoldObl.otf` | Helvetica Bold Oblique | `Arialbi.ttf` |
  | Times-Roman | `NimbusRoman-Regular.ttf` | `Times-Roman.pfb` | `TimesLTStd-Roman.otf` | Times | `Times.ttf` |
  | Times-Bold | `NimbusRoman-Bold.ttf` | `Times-Bold.pfb` | `TimesLTStd-Bold.otf` | Times Bold | `Timesbd.ttf` |
  | Times-Italic | `NimbusRoman-Italic.ttf` | `Times-Italic.pfb` | `TimesLTStd-Italic.otf` | Times Italic | `Timesi.ttf` |
  | Times-BoldItalic | `NimbusRoman-BoldItalic.ttf` | `Times-BoldItalic.pfb` | `TimesLTStd-BoldItalic.otf` | Times Bold Italic | `Timesbi.ttf` |
  | Courier | `NimbusMonoPS-Regular.ttf` | `Courier.pfb` | `CourierStd.otf` | Courier | `Cour.ttf` |
  | Courier-Bold | `NimbusMonoPS-Bold.ttf` | `Courier-Bold.pfb` | `CourierStd-Bold.otf` | Courier Bold | `Courbd.ttf` |
  | Courier-Oblique | `NimbusMonoPS-Italic.ttf` | `Courier-Oblique.pfb` | `CourierStd-Oblique.otf` | Courier Oblique | `Couri.ttf` |
  | Courier-BoldOblique | `NimbusMonoPS-BoldItalic.ttf` | `Courier-BoldOblique.pfb` | `CourierStd-BoldOblique.otf` | Courier Bold Oblique | `Courbi.ttf` |
  | Symbol | `StandardSymbolsPS.ttf` | `Symbol.pfb` | `SymbolStd.otf` | Symbol | `Symbol.ttf` |
  | ZapfDingbats | `D050000L.ttf` | `ZapfDingbats.pfb` | `ZapfDingbatsStd.otf` | Zapf Dingbats | — |

  **Only one of those columns can be embedded as it stands.** The URW files are
  TrueType and go in unchanged. Adobe's Type 1 files cannot: this package
  embeds TrueType outlines, and `font embed` refuses them. Adobe's OpenType
  files carry CFF outlines and are refused as well; convert them to TTF first.
  The macOS entries for Helvetica, Times and Courier are TrueType
  **collections** — several faces in one file — and a single face has to be
  extracted before it can be used.

  **Two of the fourteen have no working substitute today.** The URW files for
  Symbol and ZapfDingbats carry a `(3,0)` symbol cmap and no Unicode one, so
  `font embed` refuses them. The twelve text faces are unaffected and cover
  Helvetica, Times and Courier completely.

  The URW faces are metric substitutes, and measured against the metrics this
  package ships: every one of the 2 592 advances of the twelve text faces
  matches the standard face it stands in for, across all mapped WinAnsi byte
  values. They are published under the SIL Open Font License 1.1, so they can
  be redistributed with a document workflow; Adobe's own outlines cannot.

  **tclpdf does not install any font.** Embedding one means having the file,
  and which file that is remains the caller's choice — the package reads what
  it is given. The URW set is version 2.0 of the URW++ Core 35, kept at
  <https://github.com/twardoch/urw-core35-fonts>; distributions carry the same
  fonts as a package of their own, on Debian and its derivatives as
  `fonts-urw-base35`. The copies used to write the examples sit in the source
  archive under `examples/assets/fonts/urw-core35-fonts`, with the licence
  texts beside them.

*doc* **font names**

: The aliases embedded so far.

*doc* **font info** *alias*

: What the file says about itself: `family`, `postScript`, `glyphs`, `unitsPerEm`, `characters`, and the embedding permission as `fsType` and `permission`.

*doc* **text** *string* ?**-at** *{x y}*? ?**-width** *w*? ?**-align** *a*? ...

: Draws text. **Without -width** this is one line, and `-align` refers to the given point: `left` starts there, `right` ends there, `center` is centred on it. **With -width** the string is broken into a paragraph of that width, and `-align justify` becomes available. Returns the y coordinate below the last line, so the next block can continue there.

  **-anchor** chooses what the y coordinate means: `baseline` (the default) or `top`. **-rotate** turns the text about `-at`. All font options are accepted per call without changing the state.

  **-height** *h* limits the block. What fits is drawn and the return value becomes a dictionary with `y` and `rest` — the text that did not fit, ready to be set in the next column or on the next page. Without `-height` the return value is the y coordinate as before.

  **-indent**, **-indentRight** and **-firstIndent** narrow the column; a negative first indent hangs the opening line out to the left, which is how a numbered clause is set. **-paragraphSpacing** adds room between paragraphs, on top of the leading.

  **-avoid** takes a list of shapes the text runs around: `{rect {x y} {w h}}` and `{circle {x y} r}`. Each line is narrowed by whatever reaches into it and set in the widest free segment, so a circle is followed by its outline rather than by a box around it. The shapes are not drawn — that is a separate call, and the text can just as well keep clear of something invisible.

  **-avoidMargin** *d* holds the text off every avoided shape by that distance; a shape may state one of its own as a fourth element (`{circle {x y} r 7}`), which then wins. Without it the words touch the picture, which reads as a mistake however exact the geometry is.

  **Soft hyphens are honoured.** U+00AD is not a character but a permission — this word may be broken here. Where the breaker takes the offer, a real hyphen is set at the end of the line; everywhere else the mark stays invisible, in the drawing and in the measurement alike, so the same string can be set in any width. tclpdf does **not** hyphenate by itself: that needs language data and is a feature of its own. What it does is honour the marks that text arriving from a database, an XML file or an editor already carries. Note that extracting such a line yields the hyphen as well, and that a standard face is no longer refused for carrying the mark.

*doc* **leader** *left* *right* **-at** *{x y}* **-width** *w* ?**-fill** *"."*? ?**-gap** *d*? ?**-tag** *type*? ?*font options*?

: A row with two ends and a filled middle — a table of contents, a price list, a total:

  ~~~tcl
  $doc leader "3. Embedding fonts" "24" -at {20 100} -width 120
  # 3. Embedding fonts ........................... 24
  ~~~

  Both ends are measured and the space between them is filled with as many whole copies of **-fill** as fit, holding **-gap** clear of each end (1 unit by default). The remainder stays in front of the right hand end, so the figures of several rows line up. **-fill** may be any string, and an empty one draws nothing at all — which is what a sum under a rule wants. Either end may be empty. Returns the y coordinate one line down, so rows stack without measuring again.

  It does not wrap: each end is one line. A left side too long for the width keeps its full length and the fill disappears, rather than moving the figure a reader is looking for. In a tagged document the row is **one** element and the fill is an artifact — a reader that spelled the dots out would say "dot dot dot dot" between every entry and its number. **-tag** names the element (`P` by default), and `-tag Artifact` takes the whole row out of the tree, which is what a running head is.

*doc* **textPath** *string* **-segments** *{...}* ?**-align** *a*? ?**-offset** *d*? ?**-tag** *type*? ?*font options*?

: Sets one line of text along a path, glyph by glyph, each one turned by the direction the path takes at its own position. The segments are the ones **path** takes (`move`, `line`, `curve`, `close`); **-align** places the string at the start, the middle or the end of the path, and **-offset** lifts the baseline off it — positive above, negative below. Returns the length of the path, which is what a caller measures a string against beforehand: glyphs that run past the end are dropped rather than piled up there. The path itself is not drawn.

*doc* **pageNumbers -at** *{x y}* ?**-format** *"Page %n of %m"*? ?**-from** *n*? ?**-total** *n*? ?*font options*?

: Puts a page number on every page. `%n` is the number, `%m` the total. The numbers are drawn when the document is written, not when the call is made — which is the only moment the total is known — so the call may come before the pages it numbers. **-from** leaves the leading pages unnumbered, **-total** states a total of its own for a document that is part of a larger set. Several calls are independent of each other: a number at the foot and a running title at the head are two of them.

*doc* **textWidth** *string* ?*font options*?

: The width of a string in the document unit.

*doc* **textHeight** *string* **-width** *w* ?*options*?

: The height a paragraph of that width would take.

*doc* **textLines** *string* **-width** *w* ?*options*?

: The lines a paragraph would be broken into.

## Graphics

*doc* **line -from** *{x y}* **-to** *{x y}* ?**-stroke** *c*? ?**-width** *w*?

*doc* **rect -at** *{x y}* **-size** *{w h}* ?**-radius** *r*? ?**-fill** *c*? ?**-stroke** *c*?

*doc* **circle -at** *{x y}* **-radius** *r* ?**-fill** *c*?

*doc* **ellipse -at** *{x y}* **-size** *{w h}* ?**-fill** *c*?

*doc* **polygon -points** *{x y x y ...}* ?**-close** *1*? ?**-fill** *c*?

*doc* **curve -from** *{x y}* **-c1** *{x y}* **-c2** *{x y}* **-to** *{x y}*

*doc* **path -segments** *list* ?**-fill** *c*? ?**-stroke** *c*? ?**-rule** *evenodd*?

: The shapes. Common options are **-fill** and **-stroke** (a colour), **-width** (line width), **-dash** (a pattern), **-cap**, **-join**, **-opacity** and **-blend**. **-rule** takes `nonzero` (the default) or `evenodd` and decides which parts of a self-intersecting path count as inside. A segment of **-segments** is `{move x y}`, `{line x y}`, `{curve x1 y1 x2 y2 x y}` or `{close}`, in document coordinates.

*doc* **clip -at** *{x y}* **-size** *{w h}* ?**-rule** *evenodd*? / *doc* **clip -segments** *list* ?**-rule** *evenodd*?

: Clips everything drawn afterwards to a rectangle or to an arbitrary path, until the graphics state is restored — so it wants a **save** around it. **-segments** takes the same list as **path**. The path itself is never drawn: it ends in `W n` instead of a painting operator and only decides what of the following output stays visible. **-rule** `evenodd` is what leaves the hole in a ring open. Give either **-at** with **-size** or **-segments**, not both.

*doc* **save** / *doc* **restore**

: Push and pop the graphics state (`q` and `Q`).

*doc* **transform** ?**-translate** *{dx dy}*? ?**-rotate** *deg*? ?**-scale** *s*? ?**-at** *{x y}*?

: Multiplies the current transformation matrix. **-at** names a fixed point to turn or scale about; **-translate** is a displacement. The two are different things and must not be confused.

*doc* **opacity** *value*

: Fill and stroke opacity between 0 and 1.

*doc* **blend** *mode*

: The blend mode: how a colour is combined with what is already on the page. One of `Normal`, `Multiply`, `Screen`, `Overlay`, `Darken`, `Lighten`, `ColorDodge`, `ColorBurn`, `HardLight`, `SoftLight`, `Difference`, `Exclusion`, `Hue`, `Saturation`, `Color` or `Luminosity`. Like the alpha it is graphics state and holds until changed; the shapes take it per call as **-blend**, which keeps it inside their own save/restore. `Compatible` is refused — it has been deprecated since PDF 1.4 and means `Normal`. PDF/A parts 2 and 3 permit every mode listed.

*doc* **style** ?*options*?

: Sets the drawing state — the same options the shapes take, in force until changed.

## Colour

A colour is a name (`red`, `steelblue` — 148 of them, without Tk), a grey value, `{r g b}` between 0 and 1, `{c m y k}`, or a registered separation. Fills may also name a pattern: `{pattern sky}`.

## Images

*doc* **image embed** *alias path*

: Reads a JPEG or PNG and prepares it for placing. JPEG data passes through untouched as `/DCTDecode`; a PNG without alpha passes through as `/FlateDecode`; only a PNG with an alpha channel is decoded, to split the channel into an `/SMask`.

*doc* **image place** *alias* **-at** *{x y}* ?**-width** *w*? ?**-height** *h*? ?**-rotate** *deg*? ?**-opacity** *o*?

: Places an embedded image. Giving only one of width and height keeps the aspect ratio. The same image placed five times is stored once.

*doc* **image draw** *path* **-at** *{x y}* ?*options*?

: Embeds and places in one call, for an image used once.

*doc* **image info** *alias* / *doc* **image size** *alias* / *doc* **image names**

: What the file is (`width`, `height`, `colorType`, `alpha`), its natural size in the document unit, and the aliases embedded so far.

## Tables

*doc* **table -at** *{x y}* **-width** *w* ?**-head** *rows*? **-body** *rows* ?**-foot** *rows*? ?*options*?

: Draws a table and returns the y coordinate below it. A row is a list of cells; a cell is a string, or a dictionary with `text` and any of `colSpan`, `rowSpan`, `align`, `valign` and style keys.

  Column widths come in three kinds, resolved in that order: fixed (`{width 34}`), weighted (`{weight 1}`) and automatic — the rest is shared according to how wide the content actually is.

  **-columns** describes the columns, **-theme** picks `striped`, `grid` or `plain`, and **-style**, **-headStyle**, **-bodyStyle** and **-footStyle** set fonts, colours and padding. The `border` style key takes `none`, `all`, `horizontal`, `vertical` or `outer`; `outer` frames the block once per page instead of ruling every cell. **-repeatHead** and **-repeatFoot** carry those sections onto each page. **-horizontalBreak** deals a table too wide for the page over further pages, with **-repeatColumns** keeping the leading columns on each.

  `-align decimal` lines the decimal separators of a column up under each other, measured across head, body and foot together; **-decimal** picks the separator, `.` by default. Cells that are not numbers are set flush right.

  Rows tied together by a `rowSpan` are never split across a page break: the whole group moves.

  Four hooks are called: **-didParseCell** once per cell before it is measured, **-willDrawCell** and **-didDrawCell** around drawing it, and **-didDrawPage** after each page. Each receives a dictionary and the document, in that order; returning 0 from `willDrawCell` skips that cell, and a dictionary returned from `didParseCell` replaces the cell.

*doc* **table layout** ?*same options*?

: Measures without drawing — what a caller needs to decide whether a table still fits.

*doc* **table themes**

: The names of the built-in themes: `plain`, `striped`, `grid`.

## Gradients and patterns

*doc* **shading axial -at** *{x y}* **-size** *{w h}* **-colors** *list* ?**-angle** *deg*?

*doc* **shading radial -at** *{x y}* **-size** *{w h}* **-colors** *list*

: Draws a gradient directly — shading types 2 and 3. More than two colours are stitched together.

*doc* **shading pattern** *name* *type* ?*options*?

: Registers a gradient as a pattern, usable afterwards as `{pattern name}` in any fill.

*doc* **shading names**

: The gradients registered so far, by name.

*doc* **pattern create** *name* **-size** *{w h}* **-script** *body*

: A tiling pattern. Inside the script the tile is drawn like a small page, and every shape command works unchanged.

*doc* **pattern names** / *doc* **pattern size** *name*

: The registered tiling patterns, and the size of one of them as `{w h}` in the document unit.

## Reusable content

*doc* **form create** *name* **-size** *{w h}* **-script** *body*

: Defines a form XObject — a drawing stored once and placed as often as wanted. Inside the script the origin is the form's own **top left** corner and y counts downwards, the same way it does on a page.

*doc* **form place** *name* **-at** *{x y}* ?**-scale** *s*? ?**-rotate** *deg*? ?**-opacity** *o*? ?**-alt** *text*?

: Places it. Placing is a transformation, not a redraw: the object stays one object in the file.

*doc* **form names** / *doc* **form size** *name*

## SVG

*doc* **svg** *path* **-at** *{x y}* ?**-width** *w*? ?**-height** *h*? ?**-size** *{w h}*? ?**-scale** *s*? ?**-opacity** *o*? ?**-alt** *text*?

*doc* **svg -data** *markup* **-at** *{x y}* ?*same options*?

: Draws an SVG as **real vectors** — paths, shapes, groups, transforms, `use`, text and gradients become PDF operators, not a picture. Returns `{x y width height}` of what was drawn. Without a size the drawing's own dimensions apply; with one it is fitted, keeping the aspect ratio. **-size** gives both extents at once, **-scale** multiplies the drawing's own size, and **-opacity** applies to the drawing as a whole.

  **-data** takes the markup from a Tcl variable instead of a file, which is what a generator wants: whatever produces the SVG hands it over directly, with no temporary file in between. Everything else is the same, including **-alt** — with a description the drawing becomes a `Figure` carrying it, without one an artifact.

  ~~~tcl
  set markup "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">\
      <circle cx=\"20\" cy=\"20\" r=\"18\" fill=\"$colour\"/></svg>"
  $doc svg -data $markup -at {20 20} -width 12 -alt "Status: $state"
  ~~~

  Note that **svg size** below takes a file name only; the size of markup in a variable is what drawing it returns.

*doc* **svg info**

: What the LAST drawing skipped — the elements the module does not draw. It reports on the document, not on a file: anything written after **info** is accepted and ignored, so `svg info some.svg` says nothing about `some.svg`.

*doc* **svg size** *path*

: The natural size of an SVG file.

## Attachments, links and bookmarks

*doc* **attach** *path* ?**-name** *n*? ?**-mime** *m*? ?**-description** *d*? ?**-relationship** *r*? ?**-date** *d*? ?**-compress** *0*?

: Attaches a file. `-relationship` is the `/AFRelationship` value — `Alternative`, `Data`, `Source`, `Supplement` or `Unspecified`.

*doc* **attachments**

: What has been attached.

*doc* **link -at** *{x y}* **-size** *{w h}* ?**-url** *u*? ?**-page** *n*? ?**-to** *{x y}*? ?**-tooltip** *t*?

: A link rectangle over an area of the page, either to a URL or to a page of this document. It is drawn as nothing: the visible text is a separate call.

*doc* **bookmark** *title* ?**-page** *n*? ?**-at** *{x y}*? ?**-parent** *id*?

: Adds an outline entry and returns its id, which can be the `-parent` of further entries. Bookmarks are turned into objects when the document is written.

*doc* **bookmarks**

: The outline built so far.

## Metadata

*doc* **info** *key* ?*value*?

: Reads or sets an entry of the information dictionary: `Title`, `Author`, `Subject`, `Keywords`, `Creator`, `Producer`.

*doc* **language** ?*tag*?

: The natural language of the document as an RFC 3066 tag — `de`, `de-DE`, `en-GB`. It goes into the catalog and is what lets a screen reader pronounce the text correctly. PDF/A-3a and PDF/UA require it.

*doc* **metadata** ?*xml*?

: Reads or sets the XMP packet directly. Normally the package writes it.

*doc* **catalogEntry** *key* ?*value*?

: An entry of the document catalog, for anything the package does not offer by name.

## Structure and accessibility

*doc* **tagged** ?*0*|*1*?

: Whether the document writes a structure tree. **Off by default**, and it has to be set before anything is drawn: the brackets go into the content stream as it is written.

  A tagged document carries a second, invisible layer saying what the marks on a page *are* — a heading, a paragraph, a table cell — rather than how they look. The drawing does not change. Reading software needs it: without a tree it follows the order the content stream happens to have, which on a two column page runs across both columns. PDF/UA and PDF/A level A require it.

*doc* **structure** *type* ?**-alt** *text*? ?**-lang** *tag*? ?**-title** *text*? ?**-actualText** *text*? **-script** *body*

: Opens a structure element, runs *body* with it open and closes it again — including when the body fails, so a half open tree cannot reach the file. Returns whatever the body returned. *type* is one of the standard types of ISO 32000-1 14.8.4; an unknown one is refused at the call rather than in a validator later.

  Elements nest by nesting the calls. Grouping types — `Sect`, `Div`, `L`, `LI`, `Table`, `TR` and their kin — do not hold content themselves: text drawn inside an open `Sect` becomes a `P` **within** it, which is what the nesting rules ask for.

  **Most documents need few of these.** A table knows it is a table and a paragraph knows it is a paragraph, so those tag themselves; `structure` is for the grouping a writer cannot infer.

: **What is derived, and what has to be said.** `text` becomes a `P`, and one call is one element however many lines it breaks into. `table` becomes a `Table` with `TR`, `TH` and `TD`, and the fill and rules of its cells become artifacts. `image` becomes an artifact unless `-alt` describes it, and then a `Figure` carrying that description.

  **-alt** appears on `image place`, `image draw`, `form place` and `svg` for the same reason and with the same effect: with it the drawing becomes a `Figure` carrying that description, without it an artifact. A form or a drawing is one piece of marked content however many operators it contains — bracketing per element would scatter one illustration over dozens of leaves, and the parts of a drawing mean nothing on their own. Nothing inside a form, a pattern or a page-number XObject is marked at all: those are content streams of their own, mark numbers are unique per stream, and it is the *invocation* that carries the marking.

  What no writer can infer is whether a line of text is a heading — neither its size nor its weight says so. That is what **-tag** on `text` is for: `-tag H1`, `-tag Caption`, and so on. `-tag Artifact` takes the text out of the tree altogether, which is what a running head or a page number needs; under PDF/UA anything left unmarked counts as a defect.

## PDF/A and ZUGFeRD

*doc* **pdfa** ?**-part** *n*? ?**-conformance** *level*? ?**-profile** *path*?

: Declares PDF/A conformance, writes the output intent with the given ICC profile and raises the file version to match. Parts 2 and 3 are accepted; part 1 is refused because it forbids the transparency this package writes, and part 4 because it needs PDF 2.0.

  **-conformance** takes `B` (the default), `U` or `A`. Level B promises the document looks the same in fifteen years; level U adds that its text can be extracted and searched reliably, which rests on the ToUnicode map written for every embedded face anyway — so `U` is the stronger claim at no cost and is worth asking for. Level A adds the structure tree, so it needs `tagged 1` before anything is drawn; asked for without it, `pdfa` names the missing call rather than writing a file that claims 3a and fails validation.

  Declaring conformance also turns on a check: every font in the document must be embedded, and writing fails with a message naming the offending face rather than producing a file that a validator rejects later.

*doc* **pdfa state**

: What has been set, as a dictionary: `part`, `conformance`, `profile`, `identifier`, `extensions` and `registered`. Empty before **pdfa** was called.

*doc* **pdfa extension** *xml*

: Adds an extension schema to the XMP packet — the way a profile such as ZUGFeRD announces its own properties. `zugferd` uses it.

*doc* **zugferd** *path* ?**-profile** *p*? ?**-icc** *path*? ?**-version** *v*?

: The one call an electronic invoice needs. It reads the profile from the invoice XML (BT-24), declares PDF/A-3B, writes the output intent with the sRGB profile shipped with the package, adds the Factur-X XMP extension schema, and attaches the file as `factur-x.xml` with `/AFRelationship /Alternative` at document level, an entry in the names tree, and a modification date. Returns the detected profile.

*doc* **zugferd profile** *xml*

: The conformance level named in BT-24 of an invoice XML, read without writing anything. Refuses XML that carries no such identifier.

*doc* **zugferd state**

: What was attached and under which profile.

## Writing

*doc* **write** *path*

: Writes the document to a file. Writing does not finish the document: a second **write** of an unchanged document produces a byte-identical file, and drawing between two writes works - the second file carries the additions.

*doc* **writeChannel** *channel*

: Writes to an open channel instead of a file — a CGI response, a socket, a pipe. The caller opens and closes it; the channel is put into binary translation here, because that is what decides whether the bytes arrive unchanged. **write** and **writeChannel** may be combined freely — the same document can go to a file and into a response.

## Events

*doc* **on** *event script* / *doc* **off** *token* / *doc* **subscribers** *event*

: The document publishes events while it is written: `beforeWrite`, `resources`, `catalog`, `info` and `afterWrite`, plus `pageAdded` after each `page add`. This is how attachments, ZUGFeRD and the output intent attach themselves without the core knowing about them, and it is available to callers for the same purpose. **on** returns a token; **off** takes that token, not the event and script again, and accepts an unknown one silently. Subscribers run in registration order and are called with the emitting object followed by whatever the emitter passes on. The write-time events fire on **every** write, so a subscriber that creates objects must be idempotent: take its object numbers from **reservation** once and write over them on later runs, instead of reserving fresh ones each time. How to build an extension on top of this — the supported methods, the contracts and two worked examples — is the subject of `doc/PLUGINS.md` in the source distribution.

# SEE ALSO

qpdf(1), veraPDF, pdffonts(1), pdftotext(1)

# KEYWORDS

pdf, pdf/a, zugferd, factur-x, truetype, font embedding, invoice

# COPYRIGHT

Copyright (C) 2026 Alexander Schoepe, Bochum, DE

Distributed under the MIT License; see the file `license.terms`.
