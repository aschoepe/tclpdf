# Extending tclpdf

How to add a capability to tclpdf without touching its source: a letterhead, a stamp, a house style, an extra piece of document data. The package is built from modules that attach themselves to the document class and subscribe to its events — ZUGFeRD, PDF/A, attachments and bookmarks are wired exactly this way, and third-party code can use the same two mechanisms.

## The event bus

Every document is an event emitter. A subscriber registers a command prefix and is called with the document object as its first argument, followed by the event's own arguments — it never has to capture the object from its surroundings:

```tcl
set token [$doc on beforeWrite ::myorg::stamp]
$doc off $token       ;# unsubscribe; unknown tokens are accepted silently
```

Subscribers run in registration order. The events a document fires:

| Event | When | Extra arguments |
| --- | --- | --- |
| `pageAdded` | after `page add` | the new page's index |
| `beforeWrite` | at the start of every `write` and `writeChannel` | — |
| `resources` | while the page resources are built | — |
| `catalog` | while the catalog is built | — |
| `info` | while the info dictionary is built | — |
| `afterWrite` | after the file is complete | the path; empty for `writeChannel` |

## The two contracts

**Write-time events fire on every write.** A document may be written more than once, so a subscriber that creates objects must be idempotent: reserve each object number once through `reservation` and write over it on later runs. A subscriber that allocates fresh numbers per run grows the file with every write and leaves the earlier objects unreachable — nothing reports that, the file merely gets larger.

**Errors are not caught.** The bus deliberately lets a subscriber's error reach the caller of `write`. A plugin that fails must fail audibly; an invoice attachment that failed silently would produce a file that passes every validator and carries no invoice data.

## The building blocks

These methods are the supported surface for extensions:

| Method | Purpose |
| --- | --- |
| `$doc reservation $key` | an object number that survives rebuilds — handed out once per key, stable across writes |
| `$doc streamObject $pairs $content ?$number?` | write a stream object; with a number it writes over that object instead of allocating a fresh one |
| `$doc resource $category ?$name? ?$value?` | register a resource; the category must be one of the eight of the resource dictionary (ISO 32000-2, Table 34): ExtGState, ColorSpace, Pattern, Shading, XObject, Font, ProcSet or Properties — anything else is refused by name |
| `$doc catalogEntry $key ?$value?` | set, read or clear a catalog key — how /AF, /Names and /OutputIntents get in without the core knowing them |
| `$doc state $key ?$value?` | per-document state that does not go into the PDF |
| `$doc xmpSchema $prefix $uri $tags $method` | declare an XMP schema of your own: *method*, a document method added with `oo::define`, answers its properties each time the packet is built |
| `$doc xmpRaw $xml` | append ready-made `rdf:Description` elements to the XMP packet |
| `$doc writer` | the low-level writer object, for object numbers and bodies |

The table is not the whole promise: any method the manual documents is supported API in the same sense, and `xmpSchema` and `xmpRaw` are described in full in the manual's Metadata section. Both live in the `tclpdf::xmp` module, which every conformance claim loads — without one, `package require tclpdf::xmp` first. One point from there bears repeating: the packet is built once a schema is registered or a raw contribution is added — `xmpRaw` subscribes the build just as `xmpSchema` does, so a contribution on a document that claims nothing reaches the file all the same.

A worked example — a subscriber that stores a private data stream and points a catalog key at it. Readers ignore catalog keys they do not know, so the file stays valid everywhere; the pattern is the same one the ZUGFeRD module uses for keys that matter.

**Name private keys accordingly.** ISO 32000-2 Annex E reserves unprefixed names for the standard itself: a key of your own carries either a prefix registered with the ISO maintenance agency or, without registration, `XX` — `XXMyOrgData` rather than `MyOrgData`. An unprefixed name is not refused by any reader, and that is the problem: it silently claims a place in the standard's namespace and collides with whatever is put there later.

```tcl
package require tclpdf

namespace eval ::myorg {}

proc ::myorg::write {doc} {
    # The same number on every write - this is what makes a second
    # [$doc write] come out identical instead of growing.
    set number [$doc reservation myorg::data]
    $doc streamObject {Type /XXMyOrgData} {payload bytes} $number
    $doc catalogEntry XXMyOrgData "$number 0 R"
}

set doc [tclpdf new -unit mm]
$doc page add
$doc on beforeWrite ::myorg::write
$doc write out.pdf
```

## Adding methods to the document

The topical modules attach their methods with `oo::define` on the document class, and a third-party package can do the same:

```tcl
package require tclpdf
package require tclpdf::document

oo::define ::tclpdf::document::document {
  method letterhead {} {
    my font -family helvetica -size 8
    my text "My Org Ltd - 44 Example Road" -at {20 285}
  }
}

package provide myorg::letterhead 1.0
```

After the `oo::define`, `$doc letterhead` is an ordinary method on every document. To extend a single object instead of the class, use `oo::objdefine $doc` with the same body.

Three conventions keep this safe:

- **Require `tclpdf::document`, not only `tclpdf`.** The document class is loaded on first use like every other module, so it does not exist yet when an extension runs `oo::define` at load time — the error then says the class does not refer to an object, which takes a while to read as "ask for it first".
- **Prefix your method names** (`myorgLetterhead` rather than `letterhead`) when there is any chance of meeting another extension: two packages defining the same method overwrite each other silently, last one wins.
- **Require your package explicitly.** tclpdf autoloads its own modules on first use, but it does not know about yours — the application has to `package require myorg::letterhead` before calling the method.

A worked example of all of this together — the event bus, a method added with `oo::define`, a reserved object number and a private catalog key, plus the byte-identical second write that proves the extension is idempotent — is `examples/01.07-extension.tcl` in the source distribution.

## What not to rely on

Methods whose names start with an uppercase letter are private, and everything neither in the table above nor documented in the manual is internal: it may change between releases without notice. If an extension needs something the surface above does not offer, that is worth a report — the surface is meant to grow from real cases.
