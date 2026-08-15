#
# tclpdf - PDF generation for Tcl
#
# pdfa - what makes a document archivable: output intent and XMP (ISO 19005)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# PDF/A is not a different file format. It is a set of promises about an
# ordinary PDF: every font embedded, every colour anchored to a profile, the
# metadata machine-readable, nothing encrypted. This module makes the two
# promises that are structural - the output intent and the XMP packet - and
# hooks itself onto the write run so nothing in the core knows about it.
#
#   $doc pdfa -part 3 -conformance B -profile icc/sRGB.icc
#
# ZUGFeRD builds on this rather than repeating it: an invoice is a PDF/A-3
# document with an attachment and an extension schema, and zugferd.tcl adds
# exactly those two things.
#
# One promise IS checked here, and only because it is cheap and certain: that
# every font used is embedded. The 14 standard fonts are not, so a document
# that quietly falls back to Helvetica - a table style, a forgotten -family -
# is not archivable, and nothing on the way to the recipient says so. This is
# the same reasoning as refusing a character the font has no glyph for: the
# writer is the only place in the chain that still knows what was meant.
#
# Everything else is left to veraPDF. Declaring a document archivable does not
# make it so, and a checker built into the writer would only ever confirm its
# own assumptions.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::io 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::xmp 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::pdfa {
  namespace export {[a-z]*}
  namespace ensemble create
}

oo::define ::tclpdf::document::document {

  # $doc pdfa ?-part 3? ?-conformance B? ?-profile <path>? ?-identifier ...?
  # $doc pdfa extension <xml>     add an extension schema to the XMP
  # $doc pdfa state               what has been set
  method pdfa {args} {
    if {[llength $args] && [string index [lindex $args 0] 0] ne "-"} {
      switch -- [lindex $args 0] {
        extension {return [my PdfaExtension {*}[lrange $args 1 end]]}
        state {return [my state pdfa]}
        default {
          return -code error "tclpdf: unknown pdfa subcommand\
              \"[lindex $args 0]\" - known are: extension, state"
        }
      }
    }
    set current [my state pdfa]
    if {$current eq {}} {
      set current [dict create part 3 conformance B profile {} \
          identifier {} extensions {} registered 0]
    }
    set current [::tclpdf::option parse $current $args "pdfa"]
    # Which parts this writer can actually deliver.
    #
    # Part 1 forbids transparency, and tclpdf writes it without ceremony
    # through [opacity]. Accepting the declaration would produce a document
    # that says PDF/A-1 and is not - so it is refused with the part that does
    # fit named in the message.
    #
    # Part 4 needs a PDF 2.0 file; this writer emits 1.7 and below.
    #
    # Refusing beats writing something a validator will reject at the
    # recipient, where nobody can tell any more which call caused it.
    switch -- [dict get $current part] {
      1 {
        return -code error "tclpdf: PDF/A-1 forbids transparency, which\
            tclpdf writes through \"opacity\" and through PNG soft masks -\
            use part 2, which is PDF/A-1 plus everything that was missing"
      }
      2 - 3 {}
      default {
        return -code error "tclpdf: PDF/A part must be 2 or 3 - part\
            [dict get $current part] needs PDF 2.0, which tclpdf does not write"
      }
    }
    # The declared part decides the minimum file version, rather than the two
    # being set independently and contradicting each other. Measured: a
    # document with "%PDF-1.4" in the header and pdfaid:part 3 in the XMP
    # passes veraPDF without a word - two claims, one file, nobody objects.
    if {[package vcompare [[my writer] version] 1.7] < 0} {
      [my writer] version 1.7
    }
    # Level B is "looks the same forever", level U is B plus text that can be
    # extracted reliably - the ToUnicode CMap this package writes for every
    # embedded face, so U costs nothing here and is the better default answer
    # when asked for.
    #
    # Level A is B and U plus a tagged document, so it needs the structure
    # tree switched on. It used to be refused outright, and before that it was
    # accepted without one - which produced a file saying PDF/A-3a that failed
    # validation on two counts, measured with veraPDF, clauses 6.7.2.2
    # (MarkInfo/Marked) and 6.7.3.3 (StructTreeRoot).
    #
    # Switching [tagged] on here rather than complaining would be the friendly
    # move and is wrong: the brackets change every content stream, so a
    # document would silently come out different from the one the caller
    # tested. Saying which single call is missing costs them one line.
    set level [string toupper [dict get $current conformance]]
    switch -- $level {
      B - U {}
      A {
        if {[my state tagged] ne "1"} {
          return -code error "tclpdf: PDF/A level A needs a tagged document -\
              a structure tree and MarkInfo. Call \[\$doc tagged 1\] before\
              drawing, or use level U, which guarantees extractable text"
        }
      }
      default {
        return -code error "tclpdf: PDF/A conformance must be B or U, not\
            \"[dict get $current conformance]\""
      }
    }
    dict set current conformance $level
    if {![dict get $current registered]} {
      my onSelf beforeWrite PdfaWrite
      my onSelf catalog PdfaCatalog
      # First in the packet, because it was first here before xmp.tcl existed
      # and a PDF/A document's metadata should keep its shape across a refactor.
      my xmpSchema pdfaid "http://www.aiim.org/pdfa/ns/id/" \
          {part conformance} PdfaXmpBody
      dict set current registered 1
    }
    my state pdfa $current
    return $current
  }

  # Add an extension schema description to the XMP packet. ZUGFeRD needs one;
  # so would any other standard riding on PDF/A-3.
  #
  # Kept in the pdfa state as well as handed to xmp.tcl, because [pdfa state]
  # is documented to answer with what has been declared and callers read it.
  method PdfaExtension {xml} {
    set current [my pdfa]
    dict lappend current extensions $xml
    my state pdfa $current
    my xmpRaw $xml
    return
  }

  # The output intent: which colour space the numbers in this file mean.
  #
  # Without it a "0.8 0.2 0.1 rg" is a promise about nothing - two readers may
  # render it differently and both be right. That is precisely what an archive
  # format cannot allow, and it is the one PDF/A rule that needs a file rather
  # than a flag.
  method PdfaWrite {} {
    set current [my state pdfa]
    if {[dict get $current profile] eq {}} {
      return
    }
    set bytes [::tclpdf::io read [dict get $current profile]]
    # N is the number of components the profile describes; it is at offset 16
    # of the ICC header as a four-character space signature.
    set space [string range $bytes 16 19]
    set components [dict get {GRAY 1 RGB  3 CMYK 4} [string trimright $space]]
    # Both numbers survive rebuilds - PdfaWrite runs on every write, and a
    # fresh pair per run would embed the ICC profile anew each time.
    set number [my streamObject [list N $components] $bytes \
        [my reservation pdfa.icc]]
    set intent [my reservation pdfa.intent]
    [my writer] put $intent [::tclpdf::pdfObj dictionary [list \
        Type /OutputIntent \
        S /GTS_PDFA1 \
        OutputConditionIdentifier [::tclpdf::pdfObj str \
            [expr {[dict get $current identifier] ne {} ?
                [dict get $current identifier] : "sRGB IEC61966-2.1"}]] \
        Info [::tclpdf::pdfObj str \
            [expr {[dict get $current identifier] ne {} ?
                [dict get $current identifier] : "sRGB IEC61966-2.1"}]] \
        DestOutputProfile [[my writer] ref $number]]]
    my catalogEntry OutputIntents [::tclpdf::pdfObj arr \
        [list [[my writer] ref $intent]]]
    return
  }

  # Every font actually used has to carry its program (ISO 19005-3, 6.2.11.4).
  # The fact is established by font.tcl, which owns the question; what belongs
  # here is only what PDF/A makes of it.
  method PdfaCheckFonts {} {
    set missing [my fontsWithoutProgram]
    if {[llength $missing]} {
      return -code error "tclpdf: PDF/A requires every font to be embedded,\
          but [join $missing {, }] [expr {[llength $missing] > 1 ?
          {are standard fonts} : {is a standard font}}] - embed a face with\
          \"font embed\" and use it, or drop the pdfa declaration"
    }
    return
  }

  # The XMP packet. Written at catalog time so that everything that wanted to
  # add an extension schema has had its chance.
  method PdfaCatalog {} {
    # The font check runs HERE and not in PdfaWrite, and the difference is not
    # cosmetic. Both subscribe to write time events, and subscribers run in
    # the order they registered - so a document that declared [pdfa] before
    # its first [font embed] ran this check before the font module had
    # written a single object. It then found no /FontFile, and refused a
    # document whose fonts were all embedded correctly, with the message
    # "FEbody is a standard font" - naming the resource because there was no
    # /BaseFont to read yet.
    #
    # The catalog event fires after every beforeWrite subscriber, so by now
    # the objects exist whatever order the caller used. Nothing is lost by
    # checking late: [write] assembles everything before it opens the file,
    # so a refusal here still leaves no file behind.
    my PdfaCheckFonts
    return
  }

  # What PDF/A contributes to the XMP packet: the two values that make the
  # claim. Called by xmp.tcl when the packet is built, which is why it reads
  # the state instead of taking arguments - [pdfa -part 2] after [pdfa -part
  # 3] has to win, and it does.
  method PdfaXmpBody {} {
    set current [my state pdfa]
    return [list [list text part [dict get $current part]] \
        [list text conformance [dict get $current conformance]]]
  }

}

package provide tclpdf::pdfa 1.3
