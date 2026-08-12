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
    # Level A is refused for the same reason part 1 is: it asks for a tagged
    # document, and this writer has no structure tree. Accepting it produced a
    # file that says PDF/A-3a and fails validation on two counts - measured
    # with veraPDF, clauses 6.7.2.2 (MarkInfo/Marked) and 6.7.3.3
    # (StructTreeRoot). A refusal here is worth more than a rejection at the
    # recipient.
    set level [string toupper [dict get $current conformance]]
    switch -- $level {
      B - U {}
      A {
        return -code error "tclpdf: PDF/A level A needs a tagged document -\
            a structure tree and MarkInfo, neither of which tclpdf writes yet.\
            Use level U, which guarantees extractable text, or level B"
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
      dict set current registered 1
    }
    my state pdfa $current
    return $current
  }

  # Add an extension schema description to the XMP packet. ZUGFeRD needs one;
  # so would any other standard riding on PDF/A-3.
  method PdfaExtension {xml} {
    set current [my pdfa]
    dict lappend current extensions $xml
    my state pdfa $current
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
    my PdfaCheckFonts
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
  #
  # Checked against the OBJECTS rather than against a list of intentions: a
  # font resource exists only once something was set in it, and its dictionary
  # either names a font file or it does not. That catches the case nobody
  # notices - a table theme defaulting to Helvetica in a document whose text
  # is all in an embedded face.
  method PdfaCheckFonts {} {
    set missing {}
    dict for {name reference} [my resource Font] {
      if {![regexp {(\d+) 0 R} $reference -> number]} {
        continue
      }
      if {[my PdfaHasFontFile $number 3]} {
        continue
      }
      # Name the FAMILY, not the resource - "F1 is not embedded" tells a
      # caller nothing about which call to fix.
      unset -nocomplain family
      regexp {/BaseFont /(\S+?)[ />]} [[my writer] body $number] -> family
      lappend missing [expr {[info exists family] ? $family : $name}]
    }
    if {[llength $missing]} {
      return -code error "tclpdf: PDF/A requires every font to be embedded,\
          but [join [lsort -unique $missing] {, }] [expr {[llength $missing] > 1 ?
          {are standard fonts} : {is a standard font}}] - embed a face with\
          \"font embed\" and use it, or drop the pdfa declaration"
    }
    return
  }

  # Does this font object, or anything it points at, carry a font program?
  #
  # Following the references rather than looking in one place, because how
  # deep the file sits depends on the kind of font: a simple TrueType font
  # names its descriptor directly, while a Type0 goes Type0 -> CIDFont ->
  # FontDescriptor -> FontFile2. Checking only one level reports every
  # embedded Type0 face as missing, which is what a first attempt here did.
  method PdfaHasFontFile {number depth} {
    if {$depth <= 0} {
      return 0
    }
    set body [[my writer] body $number]
    if {[regexp {/FontFile[23]?\s} $body]} {
      return 1
    }
    foreach reference [regexp -all -inline {(\d+) 0 R} $body] {
      if {![string is integer -strict $reference]} {
        continue
      }
      if {[my PdfaHasFontFile $reference [expr {$depth - 1}]]} {
        return 1
      }
    }
    return 0
  }

  # The XMP packet. Written at catalog time so that everything that wanted to
  # add an extension schema has had its chance.
  method PdfaCatalog {} {
    if {[my metadata] eq {}} {
      my metadata [my PdfaXmp]
    }
    return
  }

  # Build the packet. Assembled here rather than taken from a template file
  # because three values have to be substituted and a half-templated XMP is
  # the worst of both.
  method PdfaXmp {} {
    set current [my state pdfa]
    set title [my info Title]
    set author [my info Author]
    set subject [my info Subject]
    set producer [my info Producer]
    set extensions [join [dict get $current extensions] "\n"]
    set stamp [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S%z"]
    # xmp:CreateDate wants the offset as +HH:MM, %z gives +HHMM.
    set stamp [string replace $stamp end-1 end-2 ":[string range $stamp end-1 end]"]

    append xmp "<?xpacket begin=\"\xef\xbb\xbf\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
    append xmp "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n"
    append xmp "  <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
    append xmp "    <rdf:Description rdf:about=\"\"\
        xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\">\n"
    append xmp "      <pdfaid:part>[dict get $current part]</pdfaid:part>\n"
    append xmp "      <pdfaid:conformance>[dict get $current conformance]</pdfaid:conformance>\n"
    append xmp "    </rdf:Description>\n"
    append xmp "    <rdf:Description rdf:about=\"\"\
        xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n"
    if {$title ne {}} {
      append xmp "      <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\"\
          >[my PdfaEscape $title]</rdf:li></rdf:Alt></dc:title>\n"
    }
    if {$author ne {}} {
      append xmp "      <dc:creator><rdf:Seq><rdf:li\
          >[my PdfaEscape $author]</rdf:li></rdf:Seq></dc:creator>\n"
    }
    if {$subject ne {}} {
      append xmp "      <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\"\
          >[my PdfaEscape $subject]</rdf:li></rdf:Alt></dc:description>\n"
    }
    append xmp "    </rdf:Description>\n"
    append xmp "    <rdf:Description rdf:about=\"\"\
        xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\">\n"
    append xmp "      <xmp:CreateDate>$stamp</xmp:CreateDate>\n"
    append xmp "      <xmp:ModifyDate>$stamp</xmp:ModifyDate>\n"
    append xmp "      <xmp:CreatorTool>[my PdfaEscape $producer]</xmp:CreatorTool>\n"
    append xmp "    </rdf:Description>\n"
    append xmp "    <rdf:Description rdf:about=\"\"\
        xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\">\n"
    append xmp "      <pdf:Producer>[my PdfaEscape $producer]</pdf:Producer>\n"
    append xmp "    </rdf:Description>\n"
    if {$extensions ne {}} {
      append xmp $extensions "\n"
    }
    append xmp "  </rdf:RDF>\n"
    append xmp "</x:xmpmeta>\n"
    # The trailing padding is prescribed: it lets a tool rewrite the packet in
    # place without moving every byte after it (XMP part 1, 7.3.2).
    append xmp [string repeat " " 100] "\n"
    append xmp "<?xpacket end=\"w\"?>\n"
    return $xmp
  }

  method PdfaEscape {text} {
    return [string map {& &amp; < &lt; > &gt;} $text]
  }
}

package provide tclpdf::pdfa 1.2
