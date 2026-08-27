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

  # The names the hybrid standards RESERVE for the one XML that is the
  # document a second time: Factur-X 1.09.2, 6.2 and 7.7 for the three
  # invoice spellings, Order-X 1.0, 4.1.1 for the order. Owned here beside
  # the relationships and read by zugferd.tcl, for the same reason - the
  # name tree is this module's, and one list keeps the two from drifting.
  #
  # What they are reserved FOR is decided in zugferd.tcl, which binds each
  # one to a family and a profile. What is decided here is narrower and is
  # about the tree: once a document carries the invoice or the order, no
  # second attachment may take one of these names, however it is spelled.
  # A reader looks the XML up BY NAME, and two candidates under one name
  # is a document that answers two ways - Factur-X 7.7 says as much for
  # the XRECHNUNG case ("es darf ... auch keine Einbettung einer
  # factur-x.xml-Datei geben"). Measured 2026-08-27, before this list
  # existed: after [zugferd] a plain [attach -name order-x.xml] and a
  # [attach -name factur-x.XML] both went in, and Mustangproject and
  # veraPDF called the result valid.
  variable reserved {factur-x.xml zugferd-invoice.xml xrechnung.xml order-x.xml}
}

# Whether a name is one the hybrid standards reserve, compared the way a
# READER compares it: case is not part of the answer. The name tree keys on
# bytes, so "factur-x.XML" is a key of its own and sits beside
# "factur-x.xml" without the uniqueness check noticing - and a reader
# looking for the invoice finds two files whose names differ in nothing
# that means anything.
proc ::tclpdf::attach::isReserved {name} {
  variable reserved
  return [expr {[string tolower $name] in $reserved}]
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
proc ::tclpdf::attach::keyBytes {name {encoding auto}} {
  # pdfObj DIRECTLY, and deliberately: this asks the string constructor a
  # question - what bytes would this key be written as - and the answer never
  # reaches the file. It is the sort order of the name tree (7.9.6), which is
  # over the PLAIN key bytes; going through the document's constructor would
  # sort an encrypted document by ciphertext and put the tree out of order
  # for every reader. The key itself is written at [AttachCatalog], and that
  # one does go through the document.
  if {$encoding eq "utf16"} {
    return [::tclpdf::pdfObj::Utf16Be $name]
  }
  set written [::tclpdf::pdfObj str $name]
  if {[string index $written 0] eq "<"} {
    return [binary decode hex [string range $written 1 end-1]]
  }
  return $name
}

# Which of the two spellings the WHOLE tree is written in.
#
# 7.9.6 leaves the encoding of the keys open and then binds it: "Any encoding
# of the keys may be used as long as it is self-consistent; keys shall be
# compared for equality on a simple byte-by-byte basis". Per key, [pdfObj
# str] picks the shorter readable form - a literal for printable ASCII, a
# UTF-16BE hexadecimal string for anything else - and a tree holding
# "b.txt" next to "aä.txt" then carries BOTH, which is what
# self-consistent rules out.
#
# What it costs in practice was measured on 2026-08-26: byte order and text
# order part company the moment the two spellings meet, because every
# UTF-16BE key begins with FE and sorts after every ASCII one. The file was
# in byte order - the order the clause prescribes - and qpdf 12.4.0, which
# compares the DECODED texts, repaired it: "keys are not sorted in validate".
# tools/check.sh tolerates exactly one qpdf warning, so an invoice with
# "Rechnung.xml" next to "Anlage ä.pdf" would have turned make check red.
#
# So the tree decides once: as soon as one key needs UTF-16BE, every key of
# that tree is written that way. Byte order over UTF-16BE is code point
# order except across the surrogate window, so the file is then in an order
# both kinds of reader agree on.
proc ::tclpdf::attach::treeEncoding {names} {
  foreach name $names {
    # Through [keyBytes], which is the one place that asks [pdfObj str] what
    # a key would be written as: a name that comes back as itself is the
    # literal spelling, anything else is the hexadecimal one.
    if {[keyBytes $name] ne $name} {
      return utf16
    }
  }
  return auto
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
  #                    ?-date D:20260818120000+02'00'?
  # $doc attach -data $bytes -name x.xml -date D:...  (no file on disk)
  #
  # -date is REQUIRED with -data and defaults to the file's modification time
  # for the path form: every attachment is an associated file and /Params
  # /ModDate is required of one (ISO 32000-2, 14.13.2) - see the check below.
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
        return -code error -errorcode [list TCLPDF ATTACH ARGUMENT data] \
            "tclpdf: -data takes bytes, not text - encode it\
            first (encoding convertto utf-8 \$text)"
      }
    } else {
      return -code error -errorcode [list TCLPDF ATTACH ARGUMENT source] \
          "tclpdf: attach needs a file name or -data"
    }
    set name [dict get $options name]
    if {$name eq {}} {
      return -code error -errorcode [list TCLPDF ATTACH ARGUMENT name] \
          "tclpdf: attach needs -name when given -data"
    }
    # 7.11.2.1: in a file specification string "/" separates path
    # components and "\\" escapes, so neither can be part of a NAME - a
    # "dir/sub.txt" would be read as a path, and the name tree wants a name.
    if {[string first / $name] >= 0 || [string first \\ $name] >= 0} {
      return -code error -errorcode [list TCLPDF ATTACH NAME $name] \
          "tclpdf: -name must not contain \"/\" or \"\\\" -\
          they are path separators in a file specification (ISO 32000-1,\
          7.11.2.1) - not \"$name\""
    }
    # And no control character. 7.11.2.1 does not spell it out - a PDF string
    # holds any byte - but the name is a FILE NAME: it goes into /F and /UF,
    # a reader offers it as what to save the attachment as, and no file
    # system on which a PDF is ever opened takes a NUL or a line break in
    # one. Measured 2026-08-26: "-name a\x00b" wrote /F (a_b) with /UF
    # <feff006100000062> and "qpdf --list-attachments" showed "a^@b", while
    # veraPDF 3b called the file conformant. Refused rather than repaired,
    # for the reason the XMP module gives for the same class of value: the
    # writer is the last place that still knows what was meant.
    if {[regexp {[\x00-\x1f\x7f]} $name]} {
      regexp -indices {[\x00-\x1f\x7f]} $name where
      set code [scan [string index $name [lindex $where 0]] %c]
      return -code error -errorcode [list TCLPDF ATTACH NAME $name] \
          "tclpdf: -name carries U+[format %04X $code] at position\
          [lindex $where 0] - an attachment's name is a file name (ISO\
          32000-2, 7.11.2.1, /F and /UF), and a control character is not\
          part of one on any system that would save it"
    }

    variable ::tclpdf::attach::relationships
    if {[dict get $options relationship] ni $relationships} {
      return -code error -errorcode [list TCLPDF ATTACH ARGUMENT relationship] \
          "tclpdf: -relationship must be one of\
          [join $relationships {, }] - not \"[dict get $options relationship]\""
    }
    # /Subtype of the embedded file stream is the MIME type as a name
    # (Table 45), so it needs the shape "type/subtype" of RFC 2045 tokens -
    # an empty or a spaced value wrote a name a reader cannot use.
    if {![regexp {^[!#$%&'*+.^_`|~0-9A-Za-z-]+/[!#$%&'*+.^_`|~0-9A-Za-z-]+$} \
        [dict get $options mime]]} {
      return -code error -errorcode [list TCLPDF ATTACH ARGUMENT mime] \
          "tclpdf: -mime takes a media type such as text/xml\
          or application/pdf, not \"[dict get $options mime]\""
    }
    if {![string is boolean -strict [dict get $options compress]]} {
      return -code error -errorcode [list TCLPDF ATTACH ARGUMENT compress] \
          "tclpdf: -compress takes a boolean, not\
          \"[dict get $options compress]\""
    }
    # /ModDate in the Params dictionary is a PDF date (Table 46) - the same
    # shape [info CreationDate] takes, checked by the same reader.
    #
    # AND IT IS REQUIRED, not optional. Every attachment this package writes
    # is an ASSOCIATED FILE: the file specification carries /AFRelationship
    # and the catalog lists it under /AF ([AttachCatalog]), for any
    # -relationship including the default Unspecified. ISO 32000-2, 14.13.2
    # says of such a stream that its dictionary contains "a Params key whose
    # value shall be a dictionary containing at least a ModDate key whose
    # value shall be the latest modification date of the source file", and
    # Tables 44 and 45 spell the same thing as "required in the case of an
    # embedded file stream used as an associated file". No validator here
    # reports its absence - veraPDF 3b called a file without it conformant
    # (measured 2026-08-26) - which is why it went unnoticed until the date
    # was read out of the norm rather than out of a report.
    #
    # There are two ways to a date and deliberately no third:
    #
    #   - the PATH form has the file itself, so its modification time is the
    #     default. That is what the field means, and it is what zugferd.tcl
    #     has passed for the invoice XML since it was written.
    #   - -data has no file behind it. Stamping [clock seconds] in would
    #     break the rule the whole package writes by - the same document
    #     written twice gives the same bytes - so the caller has to say, and
    #     is refused rather than guessed for.
    #
    # An explicit -date always wins, in both forms.
    if {[dict get $options date] ne {}} {
      my CheckDate [dict get $options date] "attach -date"
    } elseif {$path ne {}} {
      # In this file's spelling; [respellDate] in AttachWrite moves it again
      # if the version moves between here and the write.
      dict set options date [::tclpdf::pdfObj date [file mtime $path] \
          [[my writer] version]]
    } else {
      return -code error -errorcode [list TCLPDF ATTACH ARGUMENT date] \
          "tclpdf: attach -data needs -date, the modification time of the\
          data it carries - /Params /ModDate is required of an embedded file\
          stream used as an associated file (ISO 32000-2, 14.13.2 and Tables\
          44 and 45), every attachment of this document is one, and -data\
          has no file whose time could stand in for it - pdfObj date writes\
          one from a clock value (D:20260818120000+02'00')"
    }
    # The mirror of the check in pdfa.tcl: PDF/A-2 admits no embedded file
    # that is not itself PDF/A (ISO 19005-2, 6.8), and a claim already made
    # is not quietly broken by an attachment that follows it.
    if {[my state pdfa] ne {} && [dict get [my state pdfa] part] == 2} {
      return -code error -errorcode [list TCLPDF ATTACH STATE pdfa2] \
          "tclpdf: this document claims PDF/A-2, which admits\
          no embedded file that is not itself PDF/A (ISO 19005-2, 6.8) -\
          declare pdfa -part 3, which admits any file"
    }

    # A document that already carries the invoice or the order keeps the
    # reserved names for it. [zugferd] runs through this method too and is
    # not caught by it: its own state is recorded AFTER the attachment, so
    # the invoice itself always goes in and only what follows it is held.
    #
    # Case-insensitively, which the uniqueness check below is not and
    # cannot be: the name tree keys on bytes (7.9.6), "factur-x.XML" is a
    # key of its own, and for the reader looking the invoice up it is the
    # same name. See [isReserved].
    if {[my state zugferd] ne {} && [::tclpdf::attach::isReserved $name]} {
      return -code error -errorcode [list TCLPDF ATTACH NAME $name] \
          "tclpdf: \"$name\" is a name the hybrid standards\
          reserve for the one XML that IS the document a second time, and\
          this document already carries it as\
          \"[dict get [my state zugferd] name]\" - a reader looks that file\
          up by name and would find two (Factur-X 1.09.2, 6.2 and 7.7;\
          Order-X 1.0, 4.1.1). Give the supporting document a name of its\
          own"
    }

    # Embedded file streams and the EmbeddedFiles name tree are PDF 1.3
    # (Reference 1.7, 3.10.3). /AF and /AFRelationship are PDF 2.0 entries
    # that ISO 19005-3 (Annex E) admits into a 1.7 file as an extension -
    # which is what every ZUGFeRD invoice is - and are therefore NOT gated.
    my RequireVersion 1.3 "attach"
    set attachments [my state attachments]
    foreach entry $attachments {
      if {[dict get $entry name] eq $name} {
        return -code error -errorcode [list TCLPDF ATTACH NAME $name] \
            "tclpdf: an attachment named\
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
      # /ModDate beside /Size, and unconditionally: EVERY entry carries a
      # date, because [attach] takes the file's modification time for the
      # path form and refuses -data without -date - see there for 14.13.2,
      # which requires the entry of an associated file.
      #
      # In the spelling this file uses - the version can move between the
      # [attach] call and the write (see [respellDate] in document.tcl).
      set params [list Size [string length $bytes] \
          ModDate [my Str [::tclpdf::document::respellDate \
              [dict get $entry date] [$writer version]]]]
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
    #
    # One encoding for the whole tree, decided before the sort and used by
    # both it and the writing below - see [treeEncoding] for the clause and
    # for what a mixed tree did to qpdf.
    set encoding [::tclpdf::attach::treeEncoding [lmap entry $specs {
      dict get $entry name
    }]]
    set sorted [lsort -command [list apply {{encoding a b} {
      string compare [::tclpdf::attach::keyBytes [dict get $a name] $encoding] \
          [::tclpdf::attach::keyBytes [dict get $b name] $encoding]
    }} $encoding] $specs]
    set pairs {}
    foreach entry $sorted {
      # [my Str] for the ASCII tree, [my HexStr] of the same bytes for the
      # UTF-16BE one - both go through the document's string seam, so an
      # encrypted document encrypts the key exactly as it always did (the
      # cipher takes the bytes either way, see EncryptString in encrypt.tcl).
      if {$encoding eq "utf16"} {
        lappend pairs [my HexStr \
            [::tclpdf::attach::keyBytes [dict get $entry name] utf16]]
      } else {
        lappend pairs [my Str [dict get $entry name]]
      }
      lappend pairs [$writer ref [dict get $entry spec]]
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

package provide tclpdf::attach 1.9