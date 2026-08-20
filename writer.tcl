#
# tclpdf - PDF generation for Tcl
#
# writer - object numbering, cross-reference table and file layout (7.5)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Holds no PDF semantics - it knows nothing about pages, fonts or colours. It
# knows how to hand out object numbers, how to place bytes in a file and how to
# record where each object ended up. Everything topical builds on top.
#
# Two things are deliberately not done here:
#
#   * Cross-reference STREAMS and object streams are not written. Measured over
#     the document corpus, they save 1.5 % on an 18-object invoice and 3.1 % in
#     the median - and they cost every reader that only speaks PDF 1.4. Reading
#     them is a different matter and belongs to stage 7 (see docs/FEATURES.md).
#   * Offsets are counted from the bytes handed to the channel, not asked of
#     the channel with [tell]. That used to be the other way round, for the
#     safety of never miscounting - and [tell] answers -1 on a pipe or a
#     socket, and on a channel that already carries a CGI header it counts
#     the header in: the xref then said "-000000001" for every object, and
#     "startxref -1". An xref offset is relative to the %PDF- header (7.5.4),
#     so counting what is written after that point is right on every kind
#     of channel. An xref table that is off by one byte produces a file that
#     some readers still open, which is the worst kind of defect to chase -
#     hence one counter, fed by the one method that writes.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-

namespace eval ::tclpdf::writer {}

oo::class create ::tclpdf::writer::pdf {
  variable tclpdfObjects tclpdfNext tclpdfVersion tclpdfId tclpdfRequired \
      tclpdfCeiling tclpdfEncryptor

  # The PDF version is a parameter, not a constant: PDF/A-3 and therefore
  # ZUGFeRD require 1.7, while PDF/A-4f would want 2.0. Keeping it here makes
  # that a setting rather than a rebuild.
  constructor {{version 1.7}} {
    set tclpdfObjects {}
    set tclpdfNext 0
    set tclpdfId {}
    set tclpdfRequired {}
    set tclpdfCeiling {}
    set tclpdfEncryptor {}
    my version $version
  }

  method version {{value {}}} {
    if {$value ne {}} {
      # A list, not a pattern. The pattern let "1.9" through, and there is
      # no PDF 1.8 or 1.9 - the file would claim a version that does not
      # exist, which no reader complains about and no validator checks.
      if {$value ni {1.0 1.1 1.2 1.3 1.4 1.5 1.6 1.7 2.0}} {
        return -code error "tclpdf: there is no PDF version \"$value\" -\
            known are 1.0 to 1.7 (ISO 32000-1) and 2.0 (ISO 32000-2)"
      }
      # Not below what the document already uses: [require] checked against
      # the version of ITS moment, and lowering it afterwards would put the
      # feature into a file whose header disowns it - the hole a check at
      # call time leaves open, closed here rather than by checking again
      # at write time.
      if {$tclpdfRequired ne {}
          && [package vcompare $value [lindex $tclpdfRequired 0]] < 0} {
        return -code error "tclpdf: this document already uses\
            [lindex $tclpdfRequired 1], which needs PDF\
            [lindex $tclpdfRequired 0] - it cannot be lowered to PDF $value"
      }
      # And not above what a claim in the document allows: [limit] recorded
      # the ceiling at ITS moment, and raising past it afterwards would put
      # a PDF/A-3 claim into a file whose header disowns it.
      # Measured: "pdfa -part 3" then "configure -version 2.0" wrote
      # %PDF-2.0 with pdfaid:part 3, and veraPDF failed it on one rule
      # only, ISO 19005-3 6.1.2-1 - the header has to be %PDF-1.n, n from 0
      # to 7 - the file itself being fine. The one place that can catch it
      # is here, before the header exists.
      if {$tclpdfCeiling ne {}
          && [package vcompare $value [lindex $tclpdfCeiling 0]] > 0} {
        return -code error "tclpdf: this document claims\
            [lindex $tclpdfCeiling 1], which is written as PDF\
            [lindex $tclpdfCeiling 0] at most - it cannot be raised to PDF\
            $value"
      }
      set tclpdfVersion $value
    }
    return $tclpdfVersion
  }

  # A feature that exists only from a certain PDF version on, about to be
  # written. Refused - not raised past the caller, who set the version on
  # purpose - when the file is older than that; remembered otherwise, so
  # that [version] can refuse a later lowering. The header is what a reader
  # believes: a 1.3 file carrying an ExtGState /ca is one that some readers
  # render opaque and no validator objects to.
  #
  # The version is what the writer holds NOW: pdfa raises it, so a feature
  # asked for after that call passes where it failed before, which is right.
  method require {version feature} {
    if {[package vcompare $tclpdfVersion $version] < 0} {
      return -code error "tclpdf: $feature needs PDF $version - this document\
          is written as PDF $tclpdfVersion; create it with -version $version\
          or higher, or raise it with configure -version"
    }
    if {$tclpdfRequired eq {}
        || [package vcompare $version [lindex $tclpdfRequired 0]] > 0} {
      set tclpdfRequired [list $version $feature]
    }
    return
  }

  # The mirror image of [require]: a claim that binds the file to a version
  # AT MOST, about to be made. PDF/A-2 and -3 (ISO 19005-2/-3, 6.1.2) are
  # profiles of ISO 32000-1, and each spells out that the header is
  # "%PDF-1.n" with n from 0 to 7 - so a 2.0 file cannot carry the claim,
  # whatever else is in it (measured with veraPDF, see pdfa.tcl). Refused
  # when the file is already past the ceiling; remembered otherwise, so that
  # [version] can refuse a later raising. The lowest ceiling is the one that
  # counts, as the highest requirement is in [require].
  method limit {version feature} {
    if {[package vcompare $tclpdfVersion $version] > 0} {
      return -code error "tclpdf: $feature is written as PDF $version at\
          most - this document is written as PDF $tclpdfVersion"
    }
    if {$tclpdfCeiling eq {}
        || [package vcompare $version [lindex $tclpdfCeiling 0]] < 0} {
      set tclpdfCeiling [list $version $feature]
    }
    return
  }

  # Reserve a number without having the content yet. This is what makes
  # forward references possible - a page needs the number of its content
  # stream before the stream is finished.
  method reserve {} {
    incr tclpdfNext
    dict set tclpdfObjects $tclpdfNext {}
    return $tclpdfNext
  }

  # Fill a reserved number.
  method put {number body} {
    if {![dict exists $tclpdfObjects $number]} {
      return -code error "tclpdf: object $number was never reserved"
    }
    dict set tclpdfObjects $number $body
    return $number
  }

  # Reserve and fill in one step - the common case.
  method add {body} {
    return [my put [my reserve] $body]
  }

  # A stream object. /Length is computed here and nowhere else: it is the byte
  # count of the data exactly as written, and getting it wrong produces a file
  # that opens in some readers and not in others.
  method addStream {pairs data} {
    return [my add [my StreamBody $pairs $data]]
  }

  method stream {number pairs data} {
    return [my put $number [my StreamBody $pairs $data]]
  }

  # The one place every stream passes through - which makes it the place for
  # the one filter check. FlateDecode exists since PDF 1.2 (PDF Reference
  # 1.7, Table 3.5); the document's -compress, an embedded font program, a
  # PNG picture and an attachment all deflate, and gating them each at their
  # own site is how one of them would one day be forgotten.
  method StreamBody {pairs data} {
    my CheckBytes $data
    if {[dict exists $pairs Filter]
        && [string match *FlateDecode* [dict get $pairs Filter]]} {
      my require 1.2 "a FlateDecode stream (-compress 1, an embedded font, a\
          PNG picture, a compressed attachment)"
    }
    # Encryption sits here and only here, between the filter check and the
    # length: ISO 32000-2, 7.6.3.3 - "Stream data shall be encrypted after
    # applying all stream encoding filters" - and /Length is then the length
    # of the ENCRYPTED bytes. The other order writes a file whose /Length
    # describes data no reader ever gets to see, which readers answer with
    # anything from a blank page to a refusal.
    #
    # A metadata stream is MARKED rather than skipped. /EncryptMetadata
    # false (7.6.2) leaves exactly this one stream in the clear, and whether
    # a document does that is the encryptor's business - it knows what it
    # put into /Encrypt. The writer only says which stream it is holding.
    #
    # Without an encryptor nothing happens here at all.
    if {$tclpdfEncryptor ne {}} {
      if {[dict exists $pairs Type] && [dict get $pairs Type] eq "/Metadata"} {
        set data [{*}$tclpdfEncryptor $data metadata]
      } else {
        set data [{*}$tclpdfEncryptor $data]
      }
      # Asked again, because it is the encryptor's answer that reaches the
      # channel now: a cipher handing back text rather than bytes would
      # give a /Length in characters and a truncated file.
      my CheckBytes $data
    }
    lappend pairs Length [string length $data]
    return "[::tclpdf::pdfObj dictionary $pairs]\nstream\n$data\nendstream"
  }

  method count {} {
    return $tclpdfNext
  }

  # An indirect reference to one of OUR objects. Delegates the syntax to
  # pdfObj and adds the one thing only the writer can know: whether that
  # number was ever handed out. A reference to a number that does not exist
  # produces a file readers open and render with pieces missing.
  method ref {number} {
    if {![dict exists $tclpdfObjects $number]} {
      return -code error "tclpdf: no such object: $number"
    }
    return [::tclpdf::pdfObj ref $number]
  }

  # The stored body of an object - for tests and for diagnostics.
  method body {number} {
    if {![dict exists $tclpdfObjects $number]} {
      return -code error "tclpdf: no such object: $number"
    }
    return [dict get $tclpdfObjects $number]
  }

  # The file identifier (14.4). Required by PDF/A, and readers use it to tell
  # revisions of the same document apart. Settable so a caller who needs a
  # byte-identical result can pin it.
  method id {{value {}}} {
    if {$value ne {}} {
      set tclpdfId $value
    } elseif {$tclpdfId eq {}} {
      # Uniqueness is all that is asked for - this is not a digest and does not
      # have to be one, which saves a dependency on a hash package. Eight bytes
      # of clock plus eight of rand() cannot collide within a process and are
      # separated across processes by the microsecond part.
      set now [clock microseconds]
      set bytes {}
      for {set n 0} {$n < 8} {incr n} {
        lappend bytes [expr {($now >> ($n * 8)) & 0xff}]
      }
      for {set n 0} {$n < 8} {incr n} {
        lappend bytes [expr {int(rand() * 256)}]
      }
      set tclpdfId [binary format c* $bytes]
    }
    return $tclpdfId
  }

  # The command prefix every stream's data is handed to before it is measured
  # and written - the seam encryption hangs in. Set with a prefix, read with
  # no argument; the empty prefix, which is the default, means the writer
  # writes what it was given.
  #
  # The contract, so that the two sides can be built apart:
  #
  #   {*}$prefix $data             -> the bytes to write for a normal stream
  #   {*}$prefix $data metadata    -> the same for the /Metadata stream
  #
  # The answer must be bytes and may be of any length - /Length is taken
  # from it, not from what went in. The prefix is called once per stream, in
  # the order the objects are filled, and it is called for EVERY stream, the
  # content streams and the embedded files included: a document is encrypted
  # whole or not at all (7.6.2).
  method encryptor {{cmdPrefix {}}} {
    if {$cmdPrefix ne {}} {
      set tclpdfEncryptor $cmdPrefix
    }
    return $tclpdfEncryptor
  }

  # Write the whole file. The trailer pairs come from the document (/Root and
  # /Info); /Size and /ID are added here because only the writer knows them.
  method writeChannel {channel trailerPairs} {
    my CheckComplete
    # "-translation binary" ALONE - measured, adding "-encoding binary" throws
    # under Tcl 9.0.4 ("unknown encoding \"binary\": No longer supported") and
    # would break the package there while working fine under 8.6. The
    # translation setting already selects the byte-transparent encoding in both.
    fconfigure $channel -translation binary

    # Every byte goes through [Emit], which counts it: the xref offsets are
    # taken from that count, never from [tell] - see the head of this file.
    # The count starts at the header, because that is where a reader starts
    # counting too (7.5.4): a channel that already carries a CGI header gets
    # a file whose offsets are right all the same.
    set written 0

    # Line two carries four bytes above 127 so that anything looking at the
    # file - a mail gateway, a version control system - classifies it as
    # binary and stops translating line endings (7.5.2).
    incr written [my Emit $channel "%PDF-[my version]\n"]
    incr written [my Emit $channel "%\xe2\xe3\xcf\xd3\n"]

    set offsets {}
    for {set number 1} {$number <= $tclpdfNext} {incr number} {
      dict set offsets $number $written
      incr written [my Emit $channel \
          "$number 0 obj\n[dict get $tclpdfObjects $number]\nendobj\n"]
    }

    set startxref $written
    incr written [my Emit $channel "xref\n0 [expr {$tclpdfNext + 1}]\n"]
    # Entry zero heads the chain of free objects and is always this literal.
    # Every entry is exactly 20 bytes including the two-byte line ending -
    # readers do seek into this table by index.
    incr written [my Emit $channel "0000000000 65535 f \n"]
    for {set number 1} {$number <= $tclpdfNext} {incr number} {
      incr written [my Emit $channel \
          [format "%010d 00000 n \n" [dict get $offsets $number]]]
    }

    # /ID is written in the clear and stays that way even in an encrypted
    # file (ISO 32000-2, 7.6.2): it is one of the inputs the encryption key
    # is derived from, so a reader has to be able to read it BEFORE it can
    # decrypt anything. Encrypting it would lock the file against its own
    # password. This is why the string goes to pdfObj directly and not
    # through a document-side redirection.
    set identifier [::tclpdf::pdfObj hexStr [my id]]
    lappend trailerPairs Size [expr {$tclpdfNext + 1}] \
        ID [::tclpdf::pdfObj arr [list $identifier $identifier]]
    incr written [my Emit $channel \
        "trailer\n[::tclpdf::pdfObj dictionary $trailerPairs]\n"]
    incr written [my Emit $channel "startxref\n$startxref\n%%EOF\n"]
    return $startxref
  }

  # Write one piece and answer its length, which the caller adds to its
  # count. The count is what the xref is built from, so this is the ONE way
  # bytes leave [writeChannel]: a second [puts] beside it would be a byte
  # the table does not know about. The length is the string length, which
  # is the byte count because everything that reaches here is bytes - stream
  # data by [CheckBytes], and every other object body by construction in
  # pdfObj.
  method Emit {channel text} {
    puts -nonewline $channel $text
    return [string length $text]
  }

  # Write to a file. The channel is configured here rather than at the call
  # site: measured, a channel left on the default translation turns 17 written
  # bytes into 21 in the file, and no validator reports it.
  method writeFile {path trailerPairs} {
    set channel [open $path w]
    try {
      my writeChannel $channel $trailerPairs
    } finally {
      close $channel
    }
    return $path
  }

  # A number reserved and never filled would be written as an empty object and
  # silently break every reference pointing at it.
  method CheckComplete {} {
    set missing {}
    dict for {number body} $tclpdfObjects {
      if {$body eq {}} {
        lappend missing $number
      }
    }
    if {[llength $missing]} {
      return -code error "tclpdf: object(s) reserved but never written: [join $missing {, }]"
    }
    return
  }

  # Stream data must be bytes. A string holding characters above U+00FF would
  # give a /Length in characters while the channel writes something else - the
  # file then looks right and is truncated.
  method CheckBytes {data} {
    # The range is written as escapes rather than as literal characters:
    # Tcl 8.6 reads this file through the system encoding and Tcl 9 as
    # UTF-8, so a literal would not mean the same thing in both.
    if {[regexp {[^\u0000-\u00ff]} $data]} {
      return -code error "tclpdf: stream data must be bytes, not text - encode it first"
    }
    return
  }
}

package provide tclpdf::writer 1.3