# A finished file: importing a page, continuing it, reading what it says

Three things a document object cannot do, because their subject is a **file somebody else wrote**. `pdf import` is a document method; the other two are package commands addressed by path - and each needs its own `package require`, because a script that only reads a file never creates a document.

```tcl
package require tclpdf
package require tclpdf::importInfo    ;# ::tclpdf::pdf info|pages|fonts|fields|metadata
package require tclpdf::update        ;# ::tclpdf::update open
package require tclpdf::pdfObj        ;# the object syntax an update writes with

# The "foreign" file this page reads, imports and continues. Any PDF would do;
# this one is written here so the page carries no file of its own.
set doc [tclpdf new -unit mm]
$doc info Title "Letterhead"
$doc page add
$doc rect -at {0 0} -size {210 26} -fill {0.37 0.02 0.23}
$doc font -family helvetica -style bold -size 16
$doc text "MUSTERFIRMA" -at {20 16} -color white
$doc font -style {} -size 8
$doc text "Musterstrasse 1 - 44795 Bochum" -at {20 22} -color white
$doc page add
$doc font -size 10 -color black
$doc text "The second page of the same file." -at {20 40}
$doc write [file join $out ref-12-letterhead.pdf]
$doc destroy
```

## Taking a page over as a form

```tcl
set doc [tclpdf new -unit mm]
$doc page add

# The page is registered under an alias exactly as [form create] registers
# one, and [form place] puts it down - as often as wanted, scaled, rotated,
# faded - while the page is stored ONCE. -page counts from 1; without it the
# first page comes. The classic use is a letterhead: one import, one place.
$doc pdf import head [file join $out ref-12-letterhead.pdf] -page 1
puts "the imported page measures [lmap n [$doc form size head] {format %.1f $n}] mm"
$doc form place head -at {0 0}

$doc font embed body $ttf
$doc font -family body -size 10
$doc text "Written ON the letterhead instead of rebuilding it." -at {20 60} -width 170
$doc form place head -at {150 240} -scale 0.2 -opacity 0.5     ;# a thumbnail of the same object

$doc write [file join $out ref-12-import.pdf]
$doc destroy
```

What travels: everything the page's resources reach - fonts, images, ICC profiles, extended graphics states - copied object by object with their bytes and their `/Filter` entries untouched, so an exotic image filter is no obstacle. Only the **content** streams are decoded, which is why their filters must be ones this package reads: Flate, ASCII85, ASCIIHex or none. Boxes and `/Rotate` are honoured - the form's extent is the CropBox intersected with the MediaBox, which is what a viewer shows, and a `/Rotate` becomes the form's matrix, so the placement stands upright with width and height swapped in `form size`.

Refused, naming the file: an **encrypted** file (this package carries no decryption), a page number beyond the count, a broken cross reference, a content filter it cannot decode, a stream whose `/Length` does not end at `endstream`, and a `/Rotate` that is not a multiple of 90. **The import does not judge what it takes over**: `pdfa` and `ua` vouch for what *this* document draws, not for the foreign page - validate the result.

## Reading what a file says about itself

```tcl
# The reader [pdf import] uses, so nothing new is read and nothing outside has
# to be installed - no foreign program, no exit status to interpret. EVERY KEY
# IS ALWAYS PRESENT, empty where the file says nothing, so a field can be read
# without first asking whether it exists.
set facts [::tclpdf::pdf info [file join $out ref-12-import.pdf]]
puts "keys: [lsort [dict keys $facts]]"
puts "version [dict get $facts version], xref [dict get $facts xref],\
    [dict get $facts pages] page(s), [dict get $facts revisions] revision(s),\
    tagged [dict get $facts tagged], encrypted [dict get $facts encrypted]"
puts "info: [dict get $facts info]"

# The four answers that cost more than the summary, which is why they are
# separate calls - measured on a 62 MB catalogue: info 52 ms, fonts 1.6 s,
# because the latter walks every page and everything its resources reach.
puts "page 1: [lindex [::tclpdf::pdf pages [file join $out ref-12-import.pdf]] 0]"
foreach face [::tclpdf::pdf fonts [file join $out ref-12-import.pdf]] {
    puts "font: [dict get $face basefont], embedded [dict get $face embedded],\
        [dict get $face subtype] via [dict get $face encoding]"
}
# The XMP packet as it stands, raw - parsing XML properly means tdom, which
# this package asks for only where a document builds a packet of its own. A
# document that claims nothing has none.
puts "xmp: [string length [::tclpdf::pdf metadata [file join $out ref-12-import.pdf]]] bytes"
```

`revisions` is **not** `sections`: an incremental update appends its section, while a linearized file carries a second one at the *front* that chains forwards - so `revisions` is `sections` minus every forward step. `pdfa` and `pdfua` report what the packet **claims**, which is not a conformance: veraPDF decides that over hundreds of rules. An **encrypted** file is answered rather than refused - the one place in this package where that is so, because an inventory is the caller for which "encrypted, revision 6, AES-256" is the answer. Deliberately not answered: the text, words and colours of a page (that is rendering), whether a signature is *valid* (that is cryptography against a trust store), and outlines, page labels, the structure tree and every annotation other than the form widgets `pdf fields` reports.

## Continuing a file: the incremental update

```tcl
# An incremental update appends the changes to the end of the file and leaves
# every byte already in it exactly where it is. Why it exists is the SECOND
# SIGNATURE (see 11): a signature covers the bytes of the file it sits in, so
# signing an already signed document means appending. This is not a PDF
# editor and cannot become one - the object graph of a foreign file is not in
# memory, and what its objects mean is what a reader does not know.
file copy -force [file join $out ref-12-letterhead.pdf] [file join $out ref-12-updated.pdf]
set upd [::tclpdf::update open [file join $out ref-12-updated.pdf]]
puts "the file holds [$upd count] objects; the new ones number upwards from there"

# The handle speaks the vocabulary of the writer, deliberately: add, reserve,
# put, addStream, stream, ref, body and count mean here what they mean while a
# document is being written - so a builder written against the one works on
# the other unchanged.
regexp {^(\d+)} [$upd trailer Info] -> information
puts "as the file states it: [$upd body $information]"

# [replace] writes a SECOND copy of an object the file already carries; the
# old one stays where it is and the added cross-reference section decides
# which of the two a reader sees.
$upd replace $information [::tclpdf::pdfObj dictionary [list \
    Producer [::tclpdf::pdfObj str "tclpdf"] \
    Title [::tclpdf::pdfObj str "Letterhead, continued"]]]
$upd write                        ;# without a path: continue the file in place
$upd destroy

set facts [::tclpdf::pdf info [file join $out ref-12-updated.pdf]]
puts "now: [dict get $facts info] - [dict get $facts revisions] revisions,\
    [dict get $facts sections] cross-reference sections"
```

The update is always written as a **classic cross-reference table**, also onto a file whose own is a stream - measured: qpdf, pdfinfo, pdftotext and pyHanko all read such a file, a replaced object overrides even a compressed one inside an object stream, and a PDF/A document stays conformant. `/Info` and the metadata stream are never rewritten by an update this package makes on its own, so a PDF/A or ZUGFeRD claim survives untouched - an update that writes fresh metadata without the `pdfaid` properties turns an archivable invoice into an ordinary PDF file. Of `/ID` the permanent first string is kept and the second recomputed, which makes the same update repeatable byte for byte.

Refused by name rather than written wrong: an **encrypted** file, an object at a generation other than 0, an object stream or a cross-reference stream as the target of `replace`, and **deleting** an object - nothing in an update says what still points at the object being dropped, and a dangling reference produces a file that opens with pieces missing.

## When the file is not what it claims: the `TCLPDF IMPORT` class

The four commands above share one reader, so they share one error class. Every refusal it produces carries an `-errorcode` beginning `TCLPDF IMPORT`, and `trap {TCLPDF IMPORT}` catches all sixteen of them: `FILE`, `SYNTAX`, `DEPTH`, `XREF`, `OBJECT`, `OBJSTM`, `RECURSION`, `STREAM`, `FILTER`, `PREDICTOR`, `ROOT`, `PAGES`, `BOX`, `ROTATE`, `ENCRYPTED` and `SERIALIZE`. A damaged or hostile file is what they exist for - a cross-reference chain that runs in a circle, an object stream that contains itself, a `/Length` that points at its own object, a page tree that names itself among its children - and each of those would otherwise end in a loop that does not return, or in a raw Tcl error naming an operand instead of the file.

```tcl
# Two files to be refused. The damaged one is deliberately NOT named ref-*.pdf,
# because that is the pattern check.tcl hands to qpdf.
set channel [open [file join $out ref-12-letterhead.pdf] rb]
set bytes [read $channel]
close $channel
set channel [open [file join $out broken-12.pdf] wb]
puts -nonewline $channel $bytes
puts -nonewline $channel "startxref\n999999\n%%EOF\n"    ;# the LAST one is read
close $channel

set locked [tclpdf new -unit mm -version 2.0]
$locked encrypt -user {} -owner secret
$locked page add
$locked font -family helvetica -size 10
$locked text "not to be imported" -at {20 20}
$locked write [file join $out ref-12-locked.pdf]
$locked destroy

set doc [tclpdf new -unit mm]
$doc page add
foreach {label script} [list \
        "no such file"     [list $doc pdf import a [file join $out nothing.pdf]] \
        "a bent offset"    [list $doc pdf import b [file join $out broken-12.pdf]] \
        "an encrypted one" [list $doc pdf import c [file join $out ref-12-locked.pdf]] \
        "page 9 of 2"      [list $doc pdf import d \
                                [file join $out ref-12-letterhead.pdf] -page 9] \
        "reading it"       [list ::tclpdf::pdf fonts [file join $out ref-12-locked.pdf]] \
        "continuing it"    [list ::tclpdf::update open [file join $out ref-12-locked.pdf]]] {
    try {
        {*}$script
        puts "$label: went through, which it should not have"
    } trap {TCLPDF IMPORT} {message options} {
        puts "$label -> [dict get $options -errorcode]"
    }
}

# The one exception, and it is deliberate: [pdf info] ANSWERS an encrypted file
# instead of refusing it, because an inventory is the caller for which
# "encrypted, revision 6, AES-256" is the answer.
set facts [::tclpdf::pdf info [file join $out ref-12-locked.pdf]]
puts "locked: encrypted [dict get $facts encrypted],\
    version [dict get $facts version], [dict get $facts encryption]"
# pages, size, info and the rest stay EMPTY - they are behind the encryption.
$doc destroy
```

The message is not a contract and may be sharpened in any release; the `-errorcode` is one. Handle a class, not a wording: `trap {TCLPDF IMPORT ENCRYPTED}` is the case a batch skips with a note, `trap {TCLPDF IMPORT PAGES}` the one where the caller asked for a page the file does not have, and `trap {TCLPDF IMPORT}` the catch-all that keeps a run over a directory of foreign files going. Note that `pdf import` refuses **before** anything is registered, so a caught refusal leaves no half-built form behind and the document can carry on.
