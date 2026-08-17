#
# tclpdf - PDF generation for Tcl
#
# zugferd - an electronic invoice inside a PDF/A-3 document
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# ZUGFeRD, Factur-X and XRechnung-in-PDF are the same construction: a PDF/A-3
# document carrying the invoice a second time as machine-readable XML. What
# this module adds to pdfa.tcl and attach.tcl is small and entirely specific:
# the extension schema, the four fx: properties, and reading the profile out
# of the XML instead of asking for it.
#
#   $doc zugferd invoice.xml
#   $doc write rechnung.pdf
#
# Three things are done deliberately and each one for a measured reason:
#
#   The profile comes from BT-24 of the XML. A single regexp over
#   GuidelineSpecifiedDocumentContextParameter is enough - no XML parser is
#   needed for one element, and asking the caller invites the two from
#   drifting apart. The alternative was measured on the reference toolchain:
#   an unknown value is silently replaced by BASIC there, so an EXTENDED
#   invoice can go out labelled wrongly. Here an unknown value is an error.
#
#   /AF points DIRECTLY at the file specification. One well-known generator
#   puts a second level of indirection in between; the file passes PDF/A-3
#   validation and qpdf and poppler still cannot find the invoice.
#
#   The XML is read and embedded as BYTES. A silent line-ending conversion
#   would be invisible to every validator - as invisible as a font missing
#   its euro sign.
#
# The extension schema wording follows the normative sample shipped with the
# ZUGFeRD 2.5.2 distribution (Dokumentation, FACTUR-X_extension_schema_
# example.xmp.txt), checked against it rather than written from memory. Two
# details that a reasonable guess gets wrong: the schema is named "Factur-X
# PDFA Extension Schema" (not what the file's own comment header calls it),
# and the namespace URI carries mixed case plus a trailing "#" - the sample
# PDFs of the Factur-X info package spell it all-lowercase, which the
# specification does not allow.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::option 1.0-
package require tclpdf::io 1.0-
package require tclpdf::attach 1.0-
package require tclpdf::pdfa 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::zugferd {
  namespace export {[a-z]*}
  namespace ensemble create

  # BT-24, the "specification identifier", and the conformance level it maps
  # to. The value goes into fx:ConformanceLevel verbatim, spaces included.
  variable profiles {
    urn:factur-x.eu:1p0:minimum MINIMUM
    urn:zugferd.de:2p0:minimum MINIMUM
    urn:factur-x.eu:1p0:basicwl {BASIC WL}
    urn:zugferd.de:2p0:basicwl {BASIC WL}
    urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic BASIC
    urn:cen.eu:en16931:2017#compliant#urn:zugferd.de:2p0:basic BASIC
    urn:cen.eu:en16931:2017 {EN 16931}
    urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended EXTENDED
    urn:cen.eu:en16931:2017#conformant#urn:zugferd.de:2p0:extended EXTENDED
  }

  # The file names the standards allow. The name is not decoration - a reader
  # looks the attachment up by it.
  variable names {factur-x.xml zugferd-invoice.xml xrechnung.xml order-x.xml}
}

oo::define ::tclpdf::document::document {

  # $doc zugferd <path> ?-name factur-x.xml? ?-profile ...? ?-type INVOICE?
  #              ?-version 1.0? ?-icc icc/sRGB.icc? ?-relationship r? ?-description d? ?-compress 0?
  # $doc zugferd profile <xmlBytes>    -> the conformance level, without writing
  # $doc zugferd state
  method zugferd {args} {
    if {[llength $args] && [lindex $args 0] in {profile state}} {
      switch -- [lindex $args 0] {
        profile {return [::tclpdf::zugferd profile [lindex $args 1]]}
        state {return [my state zugferd]}
      }
    }
    return [my ZugferdInvoice {*}$args]
  }

  method ZugferdInvoice {path args} {
    set options [::tclpdf::option parse {
      name {} profile {} type INVOICE version 1.0 icc {} compress 0
      relationship {} description {}
    } $args "zugferd"]
    if {[my state zugferd] ne {}} {
      return -code error "tclpdf: this document already carries an invoice -\
          a ZUGFeRD document has exactly one"
    }

    # Read as bytes and keep them that way. Everything downstream - the
    # attachment, the checksum a recipient may compute - depends on it.
    set bytes [::tclpdf::io read $path]
    set name [dict get $options name]
    if {$name eq {}} {
      set name [file tail $path]
      if {$name ni $::tclpdf::zugferd::names} {
        set name factur-x.xml
      }
    }
    if {$name ni $::tclpdf::zugferd::names} {
      return -code error "tclpdf: \"$name\" is not a file name the standards\
          allow - use one of: [join $::tclpdf::zugferd::names {, }]"
    }
    set profile [dict get $options profile]
    if {$profile eq {}} {
      set profile [::tclpdf::zugferd profile $bytes]
    }

    # The default /AFRelationship follows the profile, because Factur-X binds
    # the two together: MINIMUM and BASIC WL record too little to stand in
    # for the invoice, so their XML is Data - for every fuller profile the
    # XML IS the invoice a second time, which is what Alternative means.
    # A single value for all profiles gets one of the two families rejected.
    # An explicit -relationship still wins.
    set relationship [dict get $options relationship]
    if {$relationship eq {}} {
      if {$profile in {MINIMUM {BASIC WL}}} {
        set relationship Data
      } else {
        set relationship Alternative
      }
    }

    # PDF/A-3 first: the invoice rides on it, and the output intent has to be
    # in place before anything else is written. Without -icc the profile is
    # the one [pdfa] uses by default - the sRGB profile shipped with the
    # package - and pdfa.tcl is where a missing one is refused, so nothing is
    # decided about it here.
    my pdfa -part 3 -conformance B
    if {[dict get $options icc] ne {}} {
      my pdfa -profile [dict get $options icc]
    }
    my pdfa extension [::tclpdf::zugferd extensionSchema]
    my pdfa extension [::tclpdf::zugferd properties $name \
        [dict get $options type] [dict get $options version] $profile]

    set description [dict get $options description]
    if {$description eq {}} {
      set description "$profile invoice data"
    }
    # ModDate in the /Params dictionary is required for the attachment (Factur-X
    # 1.09.2, embedding rules). The MODIFICATION TIME OF THE XML FILE is used
    # rather than the current time: it is what the field means, and it keeps
    # the output reproducible - the same invoice written twice has to give the
    # same bytes.
    my attach $path -name $name -relationship $relationship \
        -mime text/xml -compress [dict get $options compress] \
        -description $description \
        -date [::tclpdf::pdfObj date [file mtime $path]]

    my state zugferd [dict create name $name profile $profile \
        type [dict get $options type] version [dict get $options version] \
        bytes [string length $bytes]]
    return $profile
  }
}

# Read BT-24 out of the invoice and translate it into a conformance level.
#
# One regexp, no XML parser: the element occurs once, its content is a URN,
# and pulling in a DOM to read a single string would make tdom a runtime
# dependency of every invoice.
proc ::tclpdf::zugferd::profile {bytes} {
  variable profiles

  if {![regexp {GuidelineSpecifiedDocumentContextParameter>.*?<ram:ID>([^<]+)<} \
      $bytes -> identifier]} {
    return -code error "tclpdf: this XML carries no BT-24 specification\
        identifier (GuidelineSpecifiedDocumentContextParameter) - it is not a\
        ZUGFeRD or Factur-X invoice"
  }
  set identifier [string trim $identifier]
  if {[dict exists $profiles $identifier]} {
    return [dict get $profiles $identifier]
  }
  # XRechnung rides on the same construction with its own identifier, and new
  # ones appear with every release - so the shape is recognised rather than
  # the exact string, and anything else is refused by name.
  if {[string match {*xrechnung*} [string tolower $identifier]]} {
    return XRECHNUNG
  }
  return -code error "tclpdf: unknown BT-24 specification identifier\
      \"$identifier\" - pass -profile to override. Guessing here is how an\
      EXTENDED invoice goes out labelled BASIC"
}

# The PDF/A extension schema description, word for word from the normative
# sample. Required because PDF/A only permits metadata whose schema is
# described in the packet itself - without this the file fails validation
# even though the fx: properties are correct.
proc ::tclpdf::zugferd::extensionSchema {} {
    return {    <rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
      <pdfaExtension:schemas>
        <rdf:Bag>
          <rdf:li rdf:parseType="Resource">
            <pdfaSchema:schema>Factur-X PDFA Extension Schema</pdfaSchema:schema>
            <pdfaSchema:namespaceURI>urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#</pdfaSchema:namespaceURI>
            <pdfaSchema:prefix>fx</pdfaSchema:prefix>
            <pdfaSchema:property>
              <rdf:Seq>
                <rdf:li rdf:parseType="Resource">
                  <pdfaProperty:name>DocumentFileName</pdfaProperty:name>
                  <pdfaProperty:valueType>Text</pdfaProperty:valueType>
                  <pdfaProperty:category>external</pdfaProperty:category>
                  <pdfaProperty:description>The name of the embedded XML document</pdfaProperty:description>
                </rdf:li>
                <rdf:li rdf:parseType="Resource">
                  <pdfaProperty:name>DocumentType</pdfaProperty:name>
                  <pdfaProperty:valueType>Text</pdfaProperty:valueType>
                  <pdfaProperty:category>external</pdfaProperty:category>
                  <pdfaProperty:description>The type of the hybrid document in capital letters, e.g. INVOICE or ORDER</pdfaProperty:description>
                </rdf:li>
                <rdf:li rdf:parseType="Resource">
                  <pdfaProperty:name>Version</pdfaProperty:name>
                  <pdfaProperty:valueType>Text</pdfaProperty:valueType>
                  <pdfaProperty:category>external</pdfaProperty:category>
                  <pdfaProperty:description>The actual version of the standard applying to the embedded XML document</pdfaProperty:description>
                </rdf:li>
                <rdf:li rdf:parseType="Resource">
                  <pdfaProperty:name>ConformanceLevel</pdfaProperty:name>
                  <pdfaProperty:valueType>Text</pdfaProperty:valueType>
                  <pdfaProperty:category>external</pdfaProperty:category>
                  <pdfaProperty:description>The conformance level of the embedded XML document</pdfaProperty:description>
                </rdf:li>
              </rdf:Seq>
            </pdfaSchema:property>
          </rdf:li>
        </rdf:Bag>
      </pdfaExtension:schemas>
    </rdf:Description>}
}

# The four properties themselves. This is what a recipient's software reads to
# find out that there is an invoice, what it is called and which profile it
# follows - before opening the attachment.
proc ::tclpdf::zugferd::properties {name type version conformance} {
  set namespace "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
  append xml "    <rdf:Description rdf:about=\"\" xmlns:fx=\"$namespace\">\n"
  append xml "      <fx:DocumentType>$type</fx:DocumentType>\n"
  append xml "      <fx:DocumentFileName>$name</fx:DocumentFileName>\n"
  append xml "      <fx:Version>$version</fx:Version>\n"
  append xml "      <fx:ConformanceLevel>$conformance</fx:ConformanceLevel>\n"
  append xml "    </rdf:Description>"
  return $xml
}

package provide tclpdf::zugferd 1.1
