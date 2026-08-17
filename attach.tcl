#
# tclpdf - PDF generation for Tcl
#
# attach - embedded files (7.11.4), file specifications and the name tree
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Attachments are a CORE feature here and ZUGFeRD is the special case built on
# top of them, not the other way round. That order is what makes several
# attachments per document possible at all. Measured: 4 of the 61 official reference PDFs carry
# more than one (Aufmass.png, ElektronRapport.pdf, xrechnung.xml).
#
# Three places have to agree, and a reader needs all three:
#
#   1. the EmbeddedFile stream        the bytes
#   2. the Filespec dictionary        name, description, relationship
#   3. /Names /EmbeddedFiles          the name tree, how a reader finds it
#      and /AF on the catalog         the associated-files array PDF/A-3 wants
#
# The /AF entry points DIRECTLY at the Filespec. Measured on the corpus:
# Ghostscript inserts a second level of indirection there, and qpdf and
# poppler then cannot reach the invoice data even though the file passes
# PDF/A-3B validation.
#
# Files are read and embedded BYTE FOR BYTE. A silent line-ending conversion
# in an attachment is something no validator reports - measured, 8 of 61
# reference files differ from their published counterparts in nothing but CRLF
# against LF.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::io 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::attach {}

oo::define ::tclpdf::document::document {

  # $doc attach <path> ?-name factur-x.xml? ?-description "..."?
  #                    ?-relationship Data? ?-mime text/xml? ?-compress 0?
  # $doc attach -data $bytes -name x.xml ...        (no file on disk)
  #
  # -relationship is the /AFRelationship of PDF/A-3: Source, Data, Alternative,
  # Supplement or Unspecified. ZUGFeRD requires Data (or Alternative); getting
  # it wrong is one of the three classic reasons an otherwise valid invoice is
  # rejected.
  method attach {args} {
    # A leading path argument is optional so that both spellings work.
    set path {}
    if {[llength $args] % 2} {
      set path [lindex $args 0]
      set args [lrange $args 1 end]
    }
    set options [::tclpdf::option parse {
      data {} name {} description {} relationship Unspecified
      mime application/octet-stream compress 1 date {}
    } $args "attach"]

    if {$path ne {}} {
      # Binary, always - see io.tcl for what that prevents.
      set bytes [::tclpdf::io read $path]
      if {[dict get $options name] eq {}} {
        dict set options name [file tail $path]
      }
    } elseif {[dict get $options data] ne {}} {
      set bytes [dict get $options data]
    } else {
      return -code error "tclpdf: attach needs a file name or -data"
    }
    if {[dict get $options name] eq {}} {
      return -code error "tclpdf: attach needs -name when given -data"
    }

    set known {Source Data Alternative Supplement Unspecified}
    if {[dict get $options relationship] ni $known} {
      return -code error "tclpdf: -relationship must be one of\
          [join $known {, }] - not \"[dict get $options relationship]\""
    }

    # Embedded file streams and the EmbeddedFiles name tree are PDF 1.3
    # (Reference 1.7, 3.10.3). /AF and /AFRelationship are PDF 2.0 entries
    # that ISO 19005-3 (Annex E) admits into a 1.7 file as an extension -
    # which is what every ZUGFeRD invoice is - and are therefore NOT gated.
    my RequireVersion 1.3 "attach"
    set attachments [my state attachments]
    foreach entry $attachments {
      if {[dict get $entry name] eq [dict get $options name]} {
        return -code error "tclpdf: an attachment named\
            \"[dict get $options name]\" already exists - names in the embedded\
            file name tree have to be unique"
      }
    }
    dict set options bytes $bytes
    lappend attachments $options
    my state attachments $attachments

    # Registered once: the objects are created at write time, because only
    # then is it certain that nothing else will be added.
    if {[my state attachHooked] eq {}} {
      my state attachHooked 1
      my onSelf beforeWrite AttachWrite
      my onSelf catalog AttachCatalog
    }
    return [dict get $options name]
  }

  method attachments {} {
    return [lmap entry [my state attachments] {dict get $entry name}]
  }

  # Which attachments carry no description. Empty when every one has been
  # given a -description.
  #
  # PDF/UA-2 makes Desc mandatory on every file specification (8.2.5.11), and
  # the reason is the same as for a link: the name of a file is not a
  # description of it, and "factur-x.xml" announced on its own tells a
  # listener nothing. The fact is established here and judged by ua.tcl, the
  # same division as fonts and links.
  method attachmentsWithoutDescription {} {
    set missing {}
    foreach entry [my state attachments] {
      if {[dict get $entry description] eq {}} {
        lappend missing [dict get $entry name]
      }
    }
    return $missing
  }

  # -- internals ----------------------------------------------------------

  # Create the objects. Runs on beforeWrite, so a caller can attach right up
  # to the last moment.
  # Idempotent, because it runs on EVERY write: each attachment holds on to
  # its two object numbers and writes over them on a rebuild. Without that a
  # second write embedded every attachment a second time - the file grew by
  # the full attachment size per run and only the last copy stayed reachable.
  method AttachWrite {} {
    set writer [my writer]
    set created {}
    set index -1
    foreach entry [my state attachments] {
      incr index
      set bytes [dict get $entry bytes]
      set pairs [list Type /EmbeddedFile \
          Subtype [::tclpdf::pdfObj name [dict get $entry mime]]]
      set params [list Size [string length $bytes]]
      if {[dict get $entry date] ne {}} {
        lappend params ModDate [::tclpdf::pdfObj str [dict get $entry date]]
      }
      # /Params /Size is the UNCOMPRESSED length and has to be taken before
      # the filter runs.
      lappend pairs Params [::tclpdf::pdfObj dictionary $params]
      if {[dict get $entry compress]} {
        set bytes [::tclpdf::filter encodeFlate $bytes]
        lappend pairs Filter /FlateDecode
      }
      set streamNumber [my reservation attach.file.$index]
      $writer stream $streamNumber $pairs $bytes

      set specPairs [list Type /Filespec \
          F [::tclpdf::pdfObj str [dict get $entry name]] \
          UF [::tclpdf::pdfObj str [dict get $entry name]] \
          AFRelationship [::tclpdf::pdfObj name [dict get $entry relationship]] \
          EF [::tclpdf::pdfObj dictionary \
              [list F [$writer ref $streamNumber] \
                    UF [$writer ref $streamNumber]]]]
      if {[dict get $entry description] ne {}} {
        lappend specPairs Desc [::tclpdf::pdfObj str [dict get $entry description]]
      }
      set specNumber [my reservation attach.spec.$index]
      $writer put $specNumber [::tclpdf::pdfObj dictionary $specPairs]
      lappend created [dict create name [dict get $entry name] spec $specNumber]
    }
    my state attachSpecs $created
    return
  }

  # Hang them into the catalog: the name tree so a reader lists them, and /AF
  # so PDF/A-3 associates them with the document.
  method AttachCatalog {} {
    set specs [my state attachSpecs]
    if {![llength $specs]} {
      return
    }
    set writer [my writer]

    # The name tree has to be sorted by name (7.9.6) - a reader is allowed to
    # binary-search it, and an unsorted tree then finds nothing.
    set sorted [lsort -command {apply {{a b} {
      string compare [dict get $a name] [dict get $b name]
    }}} $specs]
    set pairs {}
    foreach entry $sorted {
      lappend pairs [::tclpdf::pdfObj str [dict get $entry name]] \
          [$writer ref [dict get $entry spec]]
    }
    my catalogEntry Names [::tclpdf::pdfObj dictionary \
        [list EmbeddedFiles [::tclpdf::pdfObj dictionary \
            [list Names [::tclpdf::pdfObj arr $pairs]]]]]

    # Straight at the Filespec, no second level in between.
    my catalogEntry AF [::tclpdf::pdfObj arr [lmap entry $sorted {
      $writer ref [dict get $entry spec]
    }]]
    return
  }
}

package provide tclpdf::attach 1.2
