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

namespace eval ::tclpdf::attach {
  # The /AFRelationship names admitted here are the five of ISO 19005-3,
  # Annex E - Table 43 of ISO 32000-2 knows more (EncryptedPayload, FormData,
  # Schema), which PDF/A-3 does not, and this package writes attachments for
  # PDF/A-3. Owned here and read by zugferd.tcl, which checks its
  # -relationship before it starts declaring things - one list, so the two
  # cannot drift.
  variable relationships {Source Data Alternative Supplement Unspecified}
}

# The bytes a reader compares when it looks a name up in the EmbeddedFiles
# name tree: 7.9.6 says the keys are sorted as byte strings, and the byte
# string of a key is what [pdfObj str] writes - the characters themselves
# for a printable ASCII name, UTF-16BE with a byte order mark for any other.
# Sorting the Tcl strings instead used to give a different order under the
# two interpreters for a name outside the BMP against one at U+FFC2: 8.6
# holds the first as a surrogate pair (D83D..., below FFC2) and 9.0 as the
# whole character (1F600, above it), and only one of those is the byte order
# of the file. Read back from the string object rather than encoded a second
# time here, so the sort and the file cannot disagree.
proc ::tclpdf::attach::keyBytes {name} {
  # pdfObj DIRECTLY, and deliberately: this asks the string constructor a
  # question - what bytes would this key be written as - and the answer never
  # reaches the file. It is the sort order of the name tree (7.9.6), which is
  # over the PLAIN key bytes; going through the document's constructor would
  # sort an encrypted document by ciphertext and put the tree out of order
  # for every reader. The key itself is written at [AttachCatalog], and that
  # one does go through the document.
  set written [::tclpdf::pdfObj str $name]
  if {[string index $written 0] eq "<"} {
    return [binary decode hex [string range $written 1 end-1]]
  }
  return $name
}

# The /F entry of a file specification is a byte string in the file system's
# own encoding, with "/" as the separator and "\\" as the escape (7.11.2.1),
# and every reader that has ever existed reads it; /UF is the text string
# with the real name (Table 44). For a name that is printable ASCII the two
# are the same. For any other, /F carries this fallback: every character
# outside printable ASCII replaced by "_", so that a reader too old for /UF
# still gets a name it can show, and one that knows /UF gets the real one.
# The name used to go into /F as UTF-16BE, which is not a form 7.11.2.1
# knows.
proc ::tclpdf::attach::fallbackName {name} {
  # One "_" per CODE POINT, not per string element: under Tcl 8.6 a character
  # beyond the BMP is stored as a surrogate pair - two elements - which the
  # class below alone turned into two underscores where Tcl 9, storing the
  # character whole, wrote one, and the /F bytes differed by interpreter.
  # The pair is folded first, as one; under Tcl 9 the range never matches.
  regsub -all {[\uD800-\uDBFF][\uDC00-\uDFFF]} $name _ name
  return [regsub -all {[^\x20-\x7e]} $name _]
}

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

    # Every check before the first change - a refused call leaves nothing
    # behind, and the checks that used to wait for the write ("expected
    # boolean value" out of the first [write] for -compress maybe, "stream
    # data must be bytes" for a -data with text in it) now name the option
    # at the call that gave it.
    #
    # -data is told from its absence by PRESENCE, not by content: an empty
    # attachment - a zero-byte marker file - is a legal thing to embed, and
    # "-data {}" used to be refused as "needs a file name or -data".
    set given 0
    foreach {option value} $args {
      if {[string trimleft $option -] eq "data"} {
        set given 1
      }
    }
    if {$path ne {}} {
      # Binary, always - see io.tcl for what that prevents.
      set bytes [::tclpdf::io read $path]
      if {[dict get $options name] eq {}} {
        dict set options name [file tail $path]
      }
    } elseif {$given} {
      set bytes [dict get $options data]
      # Bytes, as the option says. A character above U+00FF is text that was
      # never encoded, and the two roads out used to treat it differently:
      # uncompressed it was refused at the write by the writer's byte check,
      # compressed it went to [zlib compress], which keeps the low byte of
      # each character and says nothing - "中" became one byte 0x2D in the
      # file. Same rule as the writer's, said at the call.
      if {[regexp {[^\u0000-\u00ff]} $bytes]} {
        return -code error "tclpdf: -data takes bytes, not text - encode it\
            first (encoding convertto utf-8 \$text)"
      }
    } else {
      return -code error "tclpdf: attach needs a file name or -data"
    }
    set name [dict get $options name]
    if {$name eq {}} {
      return -code error "tclpdf: attach needs -name when given -data"
    }
    # 7.11.2.1: in a file specification string "/" separates path
    # components and "\\" escapes, so neither can be part of a NAME - a
    # "dir/sub.txt" would be read as a path, and the name tree wants a name.
    if {[string first / $name] >= 0 || [string first \\ $name] >= 0} {
      return -code error "tclpdf: -name must not contain \"/\" or \"\\\" -\
          they are path separators in a file specification (ISO 32000-1,\
          7.11.2.1) - not \"$name\""
    }

    variable ::tclpdf::attach::relationships
    if {[dict get $options relationship] ni $relationships} {
      return -code error "tclpdf: -relationship must be one of\
          [join $relationships {, }] - not \"[dict get $options relationship]\""
    }
    # /Subtype of the embedded file stream is the MIME type as a name
    # (Table 45), so it needs the shape "type/subtype" of RFC 2045 tokens -
    # an empty or a spaced value wrote a name a reader cannot use.
    if {![regexp {^[!#$%&'*+.^_`|~0-9A-Za-z-]+/[!#$%&'*+.^_`|~0-9A-Za-z-]+$} \
        [dict get $options mime]]} {
      return -code error "tclpdf: -mime takes a media type such as text/xml\
          or application/pdf, not \"[dict get $options mime]\""
    }
    if {![string is boolean -strict [dict get $options compress]]} {
      return -code error "tclpdf: -compress takes a boolean, not\
          \"[dict get $options compress]\""
    }
    # /ModDate in the Params dictionary is a PDF date (Table 46) - the same
    # shape [info CreationDate] takes, checked by the same reader.
    if {[dict get $options date] ne {}} {
      my CheckDate [dict get $options date] "attach -date"
    }
    # The mirror of the check in pdfa.tcl: PDF/A-2 admits no embedded file
    # that is not itself PDF/A (ISO 19005-2, 6.8), and a claim already made
    # is not quietly broken by an attachment that follows it.
    if {[my state pdfa] ne {} && [dict get [my state pdfa] part] == 2} {
      return -code error "tclpdf: this document claims PDF/A-2, which admits\
          no embedded file that is not itself PDF/A (ISO 19005-2, 6.8) -\
          declare pdfa -part 3, which admits any file"
    }

    # Embedded file streams and the EmbeddedFiles name tree are PDF 1.3
    # (Reference 1.7, 3.10.3). /AF and /AFRelationship are PDF 2.0 entries
    # that ISO 19005-3 (Annex E) admits into a 1.7 file as an extension -
    # which is what every ZUGFeRD invoice is - and are therefore NOT gated.
    my RequireVersion 1.3 "attach"
    set attachments [my state attachments]
    foreach entry $attachments {
      if {[dict get $entry name] eq $name} {
        return -code error "tclpdf: an attachment named\
            \"$name\" already exists - names in the embedded\
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
        lappend params ModDate [my Str [dict get $entry date]]
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

      # /F a byte string that every reader takes, /UF the text string with
      # the real name - see [fallbackName] for why the two can differ.
      set specPairs [list Type /Filespec \
          F [my Str [::tclpdf::attach::fallbackName [dict get $entry name]]] \
          UF [my Str [dict get $entry name]] \
          AFRelationship [::tclpdf::pdfObj name [dict get $entry relationship]] \
          EF [::tclpdf::pdfObj dictionary \
              [list F [$writer ref $streamNumber] \
                    UF [$writer ref $streamNumber]]]]
      if {[dict get $entry description] ne {}} {
        lappend specPairs Desc [my Str [dict get $entry description]]
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
    # binary-search it, and an unsorted tree then finds nothing. Sorted by
    # the BYTES of the key as written, which is what the reader compares -
    # see [keyBytes] for the case where the Tcl string order differs.
    set sorted [lsort -command {apply {{a b} {
      string compare [::tclpdf::attach::keyBytes [dict get $a name]] \
          [::tclpdf::attach::keyBytes [dict get $b name]]
    }}} $specs]
    set pairs {}
    foreach entry $sorted {
      lappend pairs [my Str [dict get $entry name]] \
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

package provide tclpdf::attach 1.4
