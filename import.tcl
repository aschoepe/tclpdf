#
# tclpdf - PDF generation for Tcl
#
# import - a page of an existing PDF, taken over as a form XObject (Etappe 7)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Usage:
#
#   $doc pdf import letterhead briefbogen.pdf
#   $doc pdf import annex report.pdf -page 3
#   $doc form place letterhead -at {0 0}
#   $doc form place annex -at {20 40} -scale 0.4
#
# The named page becomes a form under the same contract as [form create]:
# placed with [form place], as often as wanted, scaled and rotated, stored
# once in the file. Taking over a letterhead is [pdf import] once and
# [form place] on every page.
#
# WHAT IS READ. Both cross-reference flavours of ISO 32000: the classic
# table (7.5.4) and, since PDF 1.5, cross-reference streams (7.5.8) with
# object streams (7.5.7) - measured on a stock of real invoices, 29 of 32
# use the stream flavour, so a reader without it would refuse most files
# that arrive in practice. Hybrid files (7.5.8.4) are read through their
# XRefStm entry. Incremental updates are followed over /Prev, newest
# section first, as the standard prescribes.
#
# WHAT IS REFUSED, by name: encrypted files (no decryption in this
# package - see the encryption stage of the roadmap), content streams in a
# filter this package cannot decode (the resources are exempt, see below),
# and files whose cross-reference is broken. Refusing beats guessing: an
# imported letterhead that is silently wrong reaches the recipient.
#
# HOW THE TAKEOVER WORKS. Everything reachable from the page's /Resources
# is copied object by object, renumbered through this document's writer.
# The copy is done on PARSED objects - a real tokenizer, not a text
# substitution - so a literal string that happens to contain "5 0 R" stays
# untouched. Streams among the copied objects (fonts, images, ICC
# profiles) keep their bytes and their /Filter exactly as they were: the
# import never decodes what it does not have to, which is also why exotic
# image filters are no obstacle. Only the CONTENT streams are decoded -
# they have to become one stream to live in a form XObject, and their
# operators end up behind this document's own compression.
#
# The page's boxes travel along: the form's BBox is the CropBox where one
# exists - intersected with the MediaBox, which bounds it (14.11.2.2) -
# the MediaBox otherwise, and a /Rotate of 90, 180 or 270 becomes
# the form's /Matrix, so the placed page looks the way a viewer shows it.
# A /Properties resource (optional content, "layers") gets its catalog
# counterpart via /OCProperties, or a validator reports an OCG without a
# configuration.
#
# The parser below is deliberately independent of the document object -
# plain procs over a byte string - so the tests can feed it handcrafted
# files without a document around it.

package require Tcl 8.6.11-
package require tclpdf::importRead 1.0-
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

oo::define ::tclpdf::document::document {

  # $doc pdf import <alias> <path> ?-page n?
  method pdf {subcommand args} {
    switch -- $subcommand {
      import {return [my PdfImport {*}$args]}
      default {
        return -code error "tclpdf: unknown pdf subcommand \"$subcommand\" -\
            known is: import"
      }
    }
  }

  method PdfImport {alias path args} {
    set options [::tclpdf::option parse {page 1} $args "pdf import"]
    set page [dict get $options page]
    if {![string is entier -strict $page] || $page < 1} {
      return -code error "tclpdf: -page of pdf import is a page number\
          counted from 1, not \"$page\""
    }
    set forms [my state forms]
    if {[dict exists $forms $alias]} {
      return -code error "tclpdf: a form named \"$alias\" already exists"
    }
    if {![file exists $path]} {
      return -code error "tclpdf: pdf import: no file \"$path\""
    }

    set reader [::tclpdf::importRead::Open $path]
    set pageDict [::tclpdf::importRead::Page reader $page]

    # The box that becomes the form, the rotation and the extent both
    # produce: [Geometry] answers all three, and it is the same answer
    # [::tclpdf::pdf pages] reports about every page of a file - see there
    # for why the reasoning lives in one place.
    set geometry [::tclpdf::importRead::Geometry reader $pageDict $page]
    lassign [dict get $geometry box] x0 y0 x1 y1
    set rotate [dict get $geometry rotate]
    set width [dict get $geometry width]
    set height [dict get $geometry height]

    # Everything the page's resources reach is copied and renumbered; the
    # content streams are NOT part of that closure - they are decoded and
    # merged into the form below rather than copied.
    set resources [::tclpdf::importRead::Get $pageDict Resources]
    set writer [my writer]
    set queue [::tclpdf::importRead::Refs $resources]
    set map {}
    set order {}
    while {[llength $queue]} {
      set queue [lassign $queue number]
      if {[dict exists $map $number]} continue
      dict set map $number [$writer reserve]
      lappend order $number
      lassign [::tclpdf::importRead::Object reader $number] value - -
      lappend queue {*}[::tclpdf::importRead::Refs $value]
    }
    foreach number $order {
      lassign [::tclpdf::importRead::Object reader $number] value hasStream data
      if {$hasStream} {
        # The raw bytes and their /Filter travel unchanged, and the object
        # goes out through [stream] rather than being assembled here: that
        # is the one place /Length is computed (writer.tcl) and the one
        # place a stream's filters are checked against the document's PDF
        # version. Building the body here meant a copied stream was the
        # single stream in the document that passed neither - a second
        # producer of /Length beside the writer's, and a FlateDecode
        # resource that could land in a file whose header disowns the
        # filter.
        #
        # /Length is dropped rather than restated: the writer sets it, and
        # an indirect length object therefore need not come along.
        # The parsed value is a dictionary whenever hasStream is true: a
        # stream is only recognised as one when its /Length could be read
        # out of a dictionary, so there is nothing else it could be here.
        set pairs {}
        foreach {key item} [lindex $value 1] {
          if {$key eq "Length"} continue
          lappend pairs $key [::tclpdf::importRead::Serialize $item $map]
        }
        $writer stream [dict get $map $number] $pairs $data
      } else {
        $writer put [dict get $map $number] \
            [::tclpdf::importRead::Serialize $value $map]
      }
    }

    # The resources dictionary itself: referenced and already part of the
    # closure, or direct on the page and written as an object of its own.
    if {[lindex $resources 0] eq "r"} {
      set resourcesRef [$writer ref \
          [dict get $map [lindex [lindex $resources 1] 0]]]
    } elseif {[lindex $resources 0] eq "d"} {
      set resourcesRef [$writer ref [$writer add \
          [::tclpdf::importRead::Serialize $resources $map]]]
    } else {
      # A page without resources is legal; the form then carries an empty
      # dictionary, which PDF/A asks for anyway (6.2.2).
      set resourcesRef [$writer ref [$writer add "<< >>"]]
    }

    # An optional-content resource needs its catalog counterpart, or the
    # file carries layers no viewer can configure. Table 98 allows an OCMD
    # as a /Properties value; the catalog's /OCGs array takes the GROUPS
    # behind it - its /OCGs, a reference or an array of them - never the
    # OCMD itself (8.11.4.2 asks for every group in the document there).
    set resolved [::tclpdf::importRead::Resolve reader $resources]
    set properties [::tclpdf::importRead::Resolve reader \
        [::tclpdf::importRead::Get $resolved Properties]]
    set numbers {}
    # A second import MERGES with what an earlier one put into the catalog
    # rather than overwriting it; the entry is this module's own
    # serialization, read back with its own parser. First come the groups
    # already there, then the new ones, duplicates dropped by number.
    set existing [my catalogEntry OCProperties]
    if {$existing ne {}} {
      set pos 0
      set have [::tclpdf::importRead::Parse $existing pos]
      foreach item [lindex [::tclpdf::importRead::Get $have OCGs] 1] {
        if {[lindex $item 0] eq "r"} {
          lappend numbers [lindex [lindex $item 1] 0]
        }
      }
    }
    if {[lindex $properties 0] eq "d"} {
      foreach {- item} [lindex $properties 1] {
        if {[lindex $item 0] ne "r"} continue
        set entry [::tclpdf::importRead::Resolve reader $item]
        if {[lindex [::tclpdf::importRead::Get $entry Type] 1] eq "OCMD"} {
          set members [::tclpdf::importRead::Get $entry OCGs]
          if {[lindex $members 0] eq "r"} {
            set members [list $members]
          } elseif {[lindex $members 0] eq "a"} {
            set members [lindex $members 1]
          } else {
            set members {}
          }
          foreach member $members {
            if {[lindex $member 0] eq "r"} {
              lappend numbers \
                  [dict get $map [lindex [lindex $member 1] 0]]
            }
          }
        } else {
          lappend numbers [dict get $map [lindex [lindex $item 1] 0]]
        }
      }
    }
    if {[llength $numbers]} {
      set groups {}
      set seen {}
      foreach number $numbers {
        if {[dict exists $seen $number]} continue
        dict set seen $number 1
        lappend groups "$number 0 R"
      }
      my catalogEntry OCProperties "<< /OCGs \[[join $groups { }]\]\
          /D << /ON \[[join $groups { }]\] >> >>"
    }

    # The content: one stream or an array of streams whose CONCATENATION
    # is the page description (7.8.2) - decoded, joined, and stored behind
    # this document's own compression.
    set contents [::tclpdf::importRead::Resolve reader \
        [::tclpdf::importRead::Get $pageDict Contents]]
    set pieces {}
    if {[lindex $contents 0] eq "a"} {
      set list [lindex $contents 1]
    } elseif {$contents eq {}} {
      set list {}
    } else {
      set list [list [::tclpdf::importRead::Get $pageDict Contents]]
    }
    foreach item $list {
      set number [lindex [lindex $item 1] 0]
      lassign [::tclpdf::importRead::Object reader $number] value hasStream data
      if {!$hasStream} {
        return -code error "tclpdf: $path: content object $number is not a\
            stream"
      }
      lappend pieces [::tclpdf::importRead::DecodeStream reader $value $data \
          "the content stream"]
    }
    set content [join $pieces \n]

    # The form: BBox in its own normalized space, the page's corner and a
    # /Rotate folded into /Matrix, so [form place] puts down what a viewer
    # shows - upright, at the placement point.
    switch -- $rotate {
      90 {
        set matrix [list 0 -1 1 0 [expr {-$y0}] $x1]
      }
      180 {
        set matrix [list -1 0 0 -1 $x1 $y1]
      }
      270 {
        set matrix [list 0 1 -1 0 $y1 [expr {-$x0}]]
      }
      default {
        set matrix [list 1 0 0 1 [expr {-$x0}] [expr {-$y0}]]
      }
    }
    # The BBox clips in FORM space, before the matrix is applied (ISO
    # 32000-2, 8.10.2) - so it is the page's own box, unrotated; only the
    # width and height handed to [form place] are the post-matrix extents.
    set pairs [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [list \
            [::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] \
            [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1]]] \
        Matrix [::tclpdf::pdfObj arr \
            [lmap number $matrix {::tclpdf::pdfObj num $number}]] \
        Resources $resourcesRef]
    # The same transparency group [form create] writes - isolated, and
    # deliberately without /CS; xObject.tcl carries the full reasoning (a
    # named colour space is a PDF/A claim, ISO 19005-2, 6.2.4.3-2).
    # Without the group, [form place -opacity] composites each imported
    # object separately instead of fading the page as a whole. Groups
    # exist since PDF 1.4 - an older document gets none.
    if {[package vcompare [$writer version] 1.4] >= 0} {
      lappend pairs Group [::tclpdf::pdfObj dictionary {S /Transparency I true}]
    }
    set number [my streamObject $pairs $content]

    set resourceName PI[expr {[dict size $forms] + 1}]
    my resource XObject $resourceName [$writer ref $number]
    dict set forms $alias [dict create resource $resourceName \
        width $width height $height]
    my state forms $forms
    return $alias
  }
}

# ---------------------------------------------------------------------------
# THE INVENTORY: what a finished file says about itself
# ---------------------------------------------------------------------------
#
#   set facts [::tclpdf::pdf info invoice.pdf]
#   dict get $facts pages                  -> 3
#   dict get $facts info Producer          -> "tclpdf 1.1.1"
#   dict get $facts pdfa                   -> "3B"
#   ::tclpdf::pdf pages invoice.pdf        -> one dictionary per page
#   ::tclpdf::pdf fonts invoice.pdf        -> one dictionary per face
#   ::tclpdf::pdf metadata invoice.pdf     -> the XMP packet, or {}
#
# WHY THIS COSTS ALMOST NOTHING. The reader above already reads a foreign
# file's trailer, its whole cross-reference chain, its page tree with the
# inherited attributes, and any object behind them - it has to, to take over a
# single page. Everything below only ASKS that reader what it has: not one
# byte is read that [pdf import] does not read anyway, and the one piece of
# arithmetic that is new - which box a viewer shows, turned which way - is the
# import's own, now shared with it ([Geometry] above). The alternative for a
# caller is shelling out to pdfinfo: a foreign program, its exit status, its
# output format, and a file that has to lie where that program may read it.
#
# A PACKAGE COMMAND, NOT A DOCUMENT METHOD - the decision update.tcl makes at
# length, for the same reason: the subject is a finished file made by anyone,
# addressed by its path. A document object is a file this package is about to
# WRITE, and asking one what some other file contains would put two unrelated
# things in one handle. So the entry sits beside [::tclpdf::update open] and
# [::tclpdf::sign digest]. The name mirrors the document method [$doc pdf
# import]: the "pdf" family is the one about foreign files - one takes a page
# out of one, the other asks one what it is.
#
# FOUR SUBCOMMANDS RATHER THAN ONE DICTIONARY, because they cost different
# things. [info] answers out of the trailer, the catalog and page one; [pages]
# walks every page of the tree; [fonts] walks every page AND the resources
# behind it. A 900-page catalogue can then answer "is this encrypted, how many
# pages, who made it" without its 900 pages being visited. Each call opens the
# file again - ask once and keep the answer.
#
# AN ENCRYPTED FILE IS ANSWERED, NOT REFUSED. [pdf import] and [update open]
# refuse one, and they must: they would produce a document made of cipher
# text. An inventory is the one caller for which "encrypted, standard handler,
# revision 6, AESV3" IS the answer - which is more than pdfinfo gives, since
# that stops at "Command Line Error: Incorrect password". What comes back is
# what the trailer and the cross-reference say: the size, the version, how
# often the file was written on, the identifier and the /Encrypt entries.
# Every content-derived field stays empty, because strings and streams are
# cipher text without the key (7.6.2) and a guess would be worse than an empty
# answer. [pages], [fonts] and [metadata] refuse an encrypted file by name -
# through [Open], which refuses it for all three.
#
# WHAT IS DELIBERATELY NOT ANSWERED, each because the honest answer would need
# more than reading:
#
#   TEXT, WORDS, IMAGES, COLOURS ON THE PAGE. That is rendering, not reading:
#   content streams would have to be interpreted, fonts decoded, CID codes
#   mapped back through ToUnicode. pdftotext does it, and does it well.
#
#   WHETHER A SIGNATURE IS VALID. What comes back is that a signature field
#   exists, what it claims, and whether its /ByteRange reaches the last byte
#   of the file. Whether the digest matches and whether the certificate is
#   trusted is cryptography against an outside trust store - pdfsig and
#   Mustangproject do that, and this package points at them rather than
#   half-doing it.
#
#   WHETHER THE FILE REALLY IS PDF/A. What is reported is the CLAIM in the XMP
#   packet - pdfaid:part and pdfaid:conformance - and a claim is not a
#   conformance; veraPDF decides that over hundreds of rules. The difference
#   is worth the key's name: "pdfa" is what the file says about itself.
#
#   THE PERMISSIONS OF AN ENCRYPTED FILE. /P is reported as the number it is
#   and not interpreted: from revision 6 on, the authoritative copy of the
#   permissions is the encrypted /Perms string (7.6.4.4), so decoded bits
#   would state as fact what only decryption can confirm.
#
#   JAVASCRIPT, "OPTIMIZED", USER PROPERTIES - fields pdfinfo prints that
#   cannot be had from one catalog key: scripts also hang off annotations and
#   page actions, and "optimized" is a claim about linearization. Half an
#   answer here would read like a whole one.
#
#   ANNOTATIONS, OUTLINES, PAGE LABELS, THE STRUCTURE TREE. Each is a tree of
#   its own and none of them is inventory in the sense asked for. They are
#   reachable through the same reader the day they are wanted.

package provide tclpdf::import 1.1