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

: Creates a document object and returns its command name. Options: **-unit** (`mm`, the default, or `pt`, `cm`, `in`), **-format** (a page format name such as `a4`, or a pair of numbers in the document unit), **-orientation** (`portrait` or `landscape`) and **-version** (`1.0` through `1.7`, or `2.0`; default `1.7`).

  A size given as two numbers is taken as it stands. It is turned only if an orientation is asked for as well — `{88 55}` stays 88 by 55.

**tclpdf formats**

: The known page format names.

*doc* **configure** ?*option value* ...?

: Reads or changes the document options after creation. With no arguments it returns them all. A page already added keeps the size it was given.

*doc* **cget** *option*

: One option.

*doc* **destroy**

: Releases the object. A document that was written is not needed afterwards.

## Coordinates and units

Positions are given in the document unit, and **y counts from the top of the page downwards** — the opposite of PDF's own convention, which the package converts on the way out. `-at` always names the **top left** corner of what is being placed, except inside a form or a pattern script, where the origin is that object's own bottom left corner.

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

  **-family** takes one of the fourteen standard faces (`helvetica`, `times`, `courier`, `symbol`, `zapfdingbats`), an exact PostScript name such as `Times-Italic`, or the alias of an embedded face. **-style** takes `bold`, `italic` or both. **-size** is always in points. Further options: **-spacing** (extra space per character), **-wordSpacing**, **-stretch** (horizontal scaling in percent), **-leading** (line spacing, default 1.2 times the size) and **-rise** (baseline shift, for super- and subscript).

*doc* **font embed** *alias path* ?**-subset** *0*?

: Embeds a TrueType file under an alias, subset to the glyphs actually used. The alias is then usable as **-family**.

*doc* **font names**

: The aliases embedded so far.

*doc* **font info** *alias*

: What the file says about itself: `family`, `postScript`, `glyphs`, `unitsPerEm`, `characters`, and the embedding permission as `fsType` and `permission`.

*doc* **text** *string* ?**-at** *{x y}*? ?**-width** *w*? ?**-align** *a*? ...

: Draws text. **Without -width** this is one line, and `-align` refers to the given point: `left` starts there, `right` ends there, `center` is centred on it. **With -width** the string is broken into a paragraph of that width, and `-align justify` becomes available. Returns the y coordinate below the last line, so the next block can continue there.

  **-anchor** chooses what the y coordinate means: `baseline` (the default) or `top`. **-rotate** turns the text about `-at`. All font options are accepted per call without changing the state.

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

: The shapes. Common options are **-fill** and **-stroke** (a colour), **-width** (line width), **-dash** (a pattern), **-cap**, **-join** and **-opacity**. **-rule** takes `nonzero` (the default) or `evenodd` and decides which parts of a self-intersecting path count as inside. A segment of **-segments** is `{move x y}`, `{line x y}`, `{curve x1 y1 x2 y2 x y}` or `{close}`, in document coordinates.

*doc* **clip -at** *{x y}* **-size** *{w h}* ?**-rule** *evenodd*? / *doc* **clip -segments** *list* ?**-rule** *evenodd*?

: Clips everything drawn afterwards to a rectangle or to an arbitrary path, until the graphics state is restored — so it wants a **save** around it. **-segments** takes the same list as **path**. The path itself is never drawn: it ends in `W n` instead of a painting operator and only decides what of the following output stays visible. **-rule** `evenodd` is what leaves the hole in a ring open. Give either **-at** with **-size** or **-segments**, not both.

*doc* **save** / *doc* **restore**

: Push and pop the graphics state (`q` and `Q`).

*doc* **transform** ?**-translate** *{dx dy}*? ?**-rotate** *deg*? ?**-scale** *s*? ?**-at** *{x y}*?

: Multiplies the current transformation matrix. **-at** names a fixed point to turn or scale about; **-translate** is a displacement. The two are different things and must not be confused.

*doc* **opacity** *value*

: Fill and stroke opacity between 0 and 1.

*doc* **style** ?*options*?

: Sets the drawing state — the same options the shapes take, in force until changed.

## Colour

A colour is a name (`red`, `steelblue` — 147 of them, without Tk), a grey value, `{r g b}` between 0 and 1, `{c m y k}`, or a registered separation. Fills may also name a pattern: `{pattern sky}`.

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

  **-columns** describes the columns, **-theme** picks `striped`, `grid` or `plain`, and **-style**, **-headStyle**, **-bodyStyle** and **-footStyle** set fonts, colours and padding. **-repeatHead** and **-repeatFoot** carry those sections onto each page. **-horizontalBreak** deals a table too wide for the page over further pages, with **-repeatColumns** keeping the leading columns on each.

  `-align decimal` lines the decimal separators of a column up under each other, measured across head, body and foot together; **-decimal** picks the separator, `.` by default. Cells that are not numbers are set flush right.

  Rows tied together by a `rowSpan` are never split across a page break: the whole group moves.

  Four hooks are called while drawing: **-willDrawCell**, **-didDrawCell**, **-willDrawPage** and **-didDrawPage**. Each receives a dictionary and the document; returning 0 from `willDrawCell` skips that cell.

*doc* **table layout** ?*same options*?

: Measures without drawing — what a caller needs to decide whether a table still fits.

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

: Defines a form XObject — a drawing stored once and placed as often as wanted. Inside the script the origin is the form's own **bottom left** corner and y grows upward.

*doc* **form place** *name* **-at** *{x y}* ?**-scale** *s*? ?**-rotate** *deg*? ?**-opacity** *o*?

: Places it. Placing is a transformation, not a redraw: the object stays one object in the file.

*doc* **form names** / *doc* **form size** *name*

## SVG

*doc* **svg** *path* **-at** *{x y}* ?**-width** *w*? ?**-height** *h*?

: Draws an SVG file as **real vectors** — paths, shapes, groups, transforms, `use`, text and gradients become PDF operators, not a picture. Returns `{x y width height}` of what was drawn. Without a size the file's own dimensions apply; with one it is fitted, keeping the aspect ratio.

*doc* **svg info** *path* / *doc* **svg size** *path*

: What the file contains, and its natural size.

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

## PDF/A and ZUGFeRD

*doc* **pdfa** ?**-part** *n*? ?**-conformance** *level*? ?**-profile** *path*?

: Declares PDF/A conformance, writes the output intent with the given ICC profile and raises the file version to match. Parts 2 and 3 are accepted; part 1 is refused because it forbids the transparency this package writes, and part 4 because it needs PDF 2.0.

  Declaring conformance also turns on a check: every font in the document must be embedded, and writing fails with a message naming the offending face rather than producing a file that a validator rejects later.

*doc* **zugferd** *path* ?**-profile** *p*? ?**-icc** *path*? ?**-version** *v*?

: The one call an electronic invoice needs. It reads the profile from the invoice XML (BT-24), declares PDF/A-3B, writes the output intent with the sRGB profile shipped with the package, adds the Factur-X XMP extension schema, and attaches the file as `factur-x.xml` with `/AFRelationship /Alternative` at document level, an entry in the names tree, and a modification date. Returns the detected profile.

*doc* **zugferd state**

: What was attached and under which profile.

## Writing

*doc* **write** *path*

: Writes the document to a file. Writing does not finish the document: a second **write** of an unchanged document produces a byte-identical file, and drawing between two writes works - the second file carries the additions.

*doc* **writeChannel** *channel*

: Writes to an open channel instead of a file — a CGI response, a socket, a pipe. The caller opens and closes it; the channel is put into binary translation here, because that is what decides whether the bytes arrive unchanged. **write** and **writeChannel** may be combined freely — the same document can go to a file and into a response.

## Events

*doc* **on** *event script* / *doc* **off** *token* / *doc* **subscribers** *event*

: The document publishes events while it is written: `beforeWrite`, `resources`, `catalog`, `info` and `afterWrite`. This is how attachments, ZUGFeRD and the output intent attach themselves without the core knowing about them, and it is available to callers for the same purpose. **on** returns a token; **off** takes that token, not the event and script again, and accepts an unknown one silently. Subscribers run in registration order and are called with the emitting object followed by whatever the emitter passes on. The write-time events fire on **every** write, so a subscriber that creates objects must be idempotent: take its object numbers from **reservation** once and write over them on later runs, instead of reserving fresh ones each time.

# SEE ALSO

qpdf(1), veraPDF, pdffonts(1), pdftotext(1)

# KEYWORDS

pdf, pdf/a, zugferd, factur-x, truetype, font embedding, invoice

# COPYRIGHT

Copyright (C) 2026 Alexander Schoepe, Bochum, DE

Distributed under the MIT License; see the file `license.terms`.
