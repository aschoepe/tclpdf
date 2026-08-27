#
# tclpdf - PDF generation for Tcl
#
# zugferd - an electronic invoice or order inside a PDF/A-3 document
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# ZUGFeRD, Factur-X, XRechnung-in-PDF and Order-X are the same construction:
# a PDF/A-3 document carrying the invoice - or the order - a second time as
# machine-readable XML. What this module adds to pdfa.tcl and attach.tcl is
# small and entirely specific: the extension schema, the four fx: properties,
# and reading the profile out of the XML instead of asking for it.
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
# Order-X (Order-X 1.0, 4.1.2) uses the same schema - same name, same four
# properties - under a namespace URI of its own, WITHOUT the ":invoice"
# segment: urn:factur-x:pdfa:CrossIndustryDocument:1p0#. Measured on the 24
# sample PDFs and the XMP sample of the Order-X 1.0 distribution: all of
# them spell it that way, all of them keep the schema name "Factur-X PDFA
# Extension Schema" that table 4-1 of the specification renames to
# "Order-X PDFA extension Schema" - the samples are followed, as for
# Factur-X.
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

  # BT-24, the "specification identifier": the document family it belongs
  # to and the conformance level it maps to. The level goes into
  # fx:ConformanceLevel verbatim, spaces included. BASIC and EXTENDED exist
  # in both families, which is why the family is recorded next to the level
  # rather than derived from it: an invoice at BASIC is not an order at
  # BASIC, and the URN is the only thing that tells them apart.
  variable profiles {
    urn:factur-x.eu:1p0:minimum {invoice MINIMUM}
    urn:zugferd.de:2p0:minimum {invoice MINIMUM}
    urn:factur-x.eu:1p0:basicwl {invoice {BASIC WL}}
    urn:zugferd.de:2p0:basicwl {invoice {BASIC WL}}
    urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic {invoice BASIC}
    urn:cen.eu:en16931:2017#compliant#urn:zugferd.de:2p0:basic {invoice BASIC}
    urn:cen.eu:en16931:2017 {invoice {EN 16931}}
    urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended {invoice EXTENDED}
    urn:cen.eu:en16931:2017#conformant#urn:zugferd.de:2p0:extended {invoice EXTENDED}
    urn:order-x.eu:1p0:basic {order BASIC}
    urn:order-x.eu:1p0:comfort {order COMFORT}
    urn:order-x.eu:1p0:extended {order EXTENDED}
  }

  # The two document families and what belongs to each: the fx:DocumentType
  # values, the conformance levels a -profile override may name, and the
  # file names the standards allow. The name is not decoration - a reader
  # looks the attachment up by it - and it is bound to the family: Order-X
  # 1.0, 4.1.1 embeds the order as order-x.xml and nothing else, and none
  # of the three invoice names is an order. The first name of a family is
  # its default.
  #
  # The invoice levels are the five of the table above and XRECHNUNG, which
  # [profile] answers for an XRechnung identifier; the order levels are the
  # three of Order-X 1.0, 3.1 (its "COMFORT" is what EN 16931 is to an
  # invoice). Both used to go into the XMP verbatim, whatever they said -
  # measured 2026-08-17, a typo became a conformance level nobody validates
  # against.
  variable families {
    invoice {
      types {INVOICE}
      levels {MINIMUM {BASIC WL} BASIC {EN 16931} EXTENDED XRECHNUNG}
      names {factur-x.xml zugferd-invoice.xml xrechnung.xml}
      description invoice
    }
    order {
      types {ORDER ORDER_RESPONSE ORDER_CHANGE}
      levels {BASIC COMFORT EXTENDED}
      names {order-x.xml}
      description order
    }
  }
  variable types {INVOICE ORDER ORDER_RESPONSE ORDER_CHANGE}

  # A REFERENCE profile and the name its XML is embedded under. Factur-X
  # 1.09.2, 6.2: "Die XML-Datei wird immer unter dem Namen factur-x.xml
  # eingebettet. Die einzige Ausnahme bilden Referenzprofile wie das Profil
  # XRECHNUNG; hier muss der Name xrechnung.xml lauten", and 7.7: "Der Name
  # der xml-Komponente ... muss immer xrechnung.xml lauten, sie darf nicht
  # factur-x.xml sein. Konsequenterweise darf es in einem XRECHNUNG-Profil
  # ... auch keine Einbettung einer factur-x.xml-Datei geben".
  #
  # So the name is bound to the PROFILE and not only to the family, which
  # is how it was read until 2026-08-27: [zugferd -profile XRECHNUNG] took
  # the family's first name, factur-x.xml, and an EN 16931 invoice was
  # allowed to call itself xrechnung.xml. Both files pass Mustangproject
  # and veraPDF - neither tests the binding - and both name themselves
  # something they are not.
  #
  # A dict rather than one "if", because that is what the standard's
  # sentence says: a reference profile is a KIND, XRECHNUNG is today's
  # only member, and the names of every reference profile are what a
  # non-reference profile may not use.
  variable reference {XRECHNUNG xrechnung.xml}

  # The relationships that may stand on the XML this module embeds, for
  # BOTH families. Order-X 1.0, 4.1.1 lists these three for order-x.xml and
  # names no default; Factur-X 1.09.2 binds the invoice's to the profile -
  # Data for MINIMUM and BASIC WL, Alternative for the fuller ones, see the
  # method - and -relationship overrides that, which is what the manual
  # promises and what a caller mirroring another generator needs.
  #
  # What the override may NOT say is Supplement or Unspecified, and that is
  # the one thing the invoice side never checked: "zugferd invoice.xml
  # -relationship Supplement" went through, although the manual names the
  # three this list holds. The two words describe an attachment that stands
  # BESIDE the document - a note, a drawing, something the standards do put
  # in a hybrid file - and this XML is the document a second time. Neither
  # veraPDF nor Mustangproject objects (measured 2026-08-25, both call the
  # file valid), so nothing but the writer is going to say it.
  #
  # AND THE PROFILE BINDS THE DEFAULT, NOT THE OPTION. The question was put
  # the other way round on 2026-08-25 - should "-relationship Data" on an
  # EN 16931 invoice be refused, since Factur-X names Alternative for that
  # profile? Measured first: it goes through, the file carries
  # /AFRelationship /Data, veraPDF calls it PASS 3b and Mustangproject calls
  # it valid. No tool decides this, so it is a decision and not a rule to
  # look up, and it is decided the open way, for three reasons.
  #
  # These three words are the ones the standards allow FOR THIS FILE:
  # Order-X 4.1.1 lists all three and prescribes none, and Factur-X picks
  # two of them by profile - so none of the three is ever a value the format
  # forbids here, which is exactly what separates them from the two above.
  # Second, the option exists for the case a profile cannot foresee: a
  # caller reproducing another generator's file, where the relationship is
  # whatever that generator wrote, and a package that refuses it sends them
  # back to [attach] to build the whole hybrid by hand. Third, a gate would
  # answer a profile it has never heard of - a later revision, a family this
  # module does not yet know - by refusing, which is the wrong way round for
  # a writer whose files other people have to accept. So the default carries
  # the standard, which is what a caller who says nothing gets; the option
  # carries the exception, and a caller who names one has said so on
  # purpose. What was written is reported by [zugferd state], which is where
  # a caller checks what their file actually says.
  variable relationships {Data Source Alternative}
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
      name {} profile {} type {} version 1.0 icc {} compress 0
      relationship {} description {}
    } $args "zugferd"]
    if {[my state zugferd] ne {}} {
      return -code error -errorcode [list TCLPDF ZUGFERD STATE invoice] \
          "tclpdf: this document already carries an invoice or\
          order - a ZUGFeRD or Order-X document has exactly one"
    }

    # A hybrid invoice is a PDF/A-3 document, and PDF/A forbids encryption -
    # the same wall pdfa.tcl names, said here so the caller learns it at the
    # call that meant the invoice rather than one level down.
    if {[my state encrypt] ne {}} {
      return -code error -errorcode [list TCLPDF ZUGFERD STATE encrypted] \
          "tclpdf: a ZUGFeRD or Order-X document is a PDF/A-3\
          document and PDF/A forbids encryption - this document is encrypted"
    }

    # Every option is checked HERE, before the first call that changes the
    # document. This method makes three calls that each leave state behind
    # - pdfa, pdfa extension, attach - and a refusal from the last of them
    # used to leave the first two standing: a bad -relationship, caught
    # inside [attach], left a PDF/A-3B claim with the Factur-X schema and
    # fx:DocumentFileName in the packet and NO invoice in the file - a
    # document that validates and lies - and a corrected retry declared the
    # schema a second time.

    # Read as bytes and keep them that way. Everything downstream - the
    # attachment, the checksum a recipient may compute - depends on it.
    set bytes [::tclpdf::io read $path]

    # The document type decides the family - invoice or order - and the
    # family decides which levels, which names and which relationships are
    # allowed. Without -type the family comes from BT-24: an Order-X
    # identifier makes the document an ORDER (the plain order, not a
    # response or change - those the caller has to name), anything else an
    # INVOICE. Without -profile BT-24 gives the level as well, and then
    # the identifier's family and -type have to agree: a Factur-X BASIC
    # invoice under -type ORDER would come out with a level that Order-X
    # also knows, labelled as something it is not.
    variable ::tclpdf::zugferd::families
    variable ::tclpdf::zugferd::types
    set type [dict get $options type]
    if {$type ne {} && $type ni $types} {
      return -code error -errorcode [list TCLPDF ZUGFERD TYPE $type] \
          "tclpdf: \"$type\" is not a document type - use one\
          of: [join $types {, }]"
    }
    set profile [dict get $options profile]
    set read {}
    if {$profile eq {}} {
      lassign [::tclpdf::zugferd identify $bytes] read profile
    } elseif {$type eq {}} {
      # -profile overrides the level, so BT-24 may say anything - even
      # nothing. Where it names a family all the same, that family is the
      # default type; where it does not, INVOICE is.
      catch {set read [lindex [::tclpdf::zugferd identify $bytes] 0]}
    }
    if {$type eq {}} {
      set type [expr {$read eq "order" ? "ORDER" : "INVOICE"}]
    }
    set family [expr {$type in [dict get $families order types] ? "order" : "invoice"}]
    set kind [dict get $families $family description]
    if {$read ne {} && $read ne $family} {
      return -code error -errorcode [list TCLPDF ZUGFERD PROFILE $profile] \
          "tclpdf: BT-24 of this XML is an $read identifier\
          ($profile) and -type $type makes it an $kind - the two have to\
          agree; pass -profile to override the identifier, or the -type of\
          the $read family: [join [dict get $families $read types] {, }]"
    }
    set levels [dict get $families $family levels]
    if {[dict get $options profile] ne {} && $profile ni $levels} {
      set other [expr {$family eq "order" ? "invoice" : "order"}]
      if {$profile in [dict get $families $other levels]} {
        return -code error -errorcode [list TCLPDF ZUGFERD PROFILE $profile] \
            "tclpdf: \"$profile\" is a conformance level of\
            an [dict get $families $other description], and this document is\
            an $kind (-type $type) - its levels are: [join $levels {, }]; for\
            an [dict get $families $other description] pass -type\
            [join [dict get $families $other types] {, }]"
      }
      return -code error -errorcode [list TCLPDF ZUGFERD PROFILE $profile] \
          "tclpdf: \"$profile\" is not a conformance level -\
          use one of: [join $levels {, }]"
    }

    # The name is bound to the family AND to the profile: a reference
    # profile has one name of its own and no other profile may use it (see
    # [reference] at the top). Everything a non-reference profile may be
    # called is what the family allows minus the reference names, and the
    # first of what is left is its default.
    #
    # Without -name the file's own name is kept where it is one the profile
    # allows, and the default is taken otherwise - so an XRECHNUNG invoice
    # in a file called rechnung.xml becomes xrechnung.xml, and one in a
    # file called factur-x.xml becomes xrechnung.xml as well rather than
    # keeping a name 7.7 forbids it.
    variable ::tclpdf::zugferd::reference
    set names [dict get $families $family names]
    if {[dict exists $reference $profile]} {
      set names [list [dict get $reference $profile]]
    } else {
      foreach {referenceProfile referenceName} $reference {
        set names [lsearch -all -inline -not -exact $names $referenceName]
      }
    }
    set name [dict get $options name]
    if {$name eq {}} {
      set name [file tail $path]
      if {$name ni $names} {
        set name [lindex $names 0]
      }
    }
    if {$name ni $names} {
      set other [expr {$family eq "order" ? "invoice" : "order"}]
      if {$name in [dict get $families $other names]} {
        return -code error -errorcode [list TCLPDF ZUGFERD NAME $name] \
            "tclpdf: \"$name\" is the file name of an\
            [dict get $families $other description], and this document is an\
            $kind (-type $type) - which is embedded as [join $names {, }]\
            (Order-X 1.0, 4.1.1 binds the name to the document); for an\
            [dict get $families $other description] pass -type\
            [join [dict get $families $other types] {, }]"
      }
      # A name that belongs to a reference profile, or the name of a
      # reference profile used by one that is not it: the two halves of
      # 7.7, said with the profile in hand rather than as "not a name the
      # standards allow". After the family question, which is the coarser
      # one - an order named xrechnung.xml is first of all not an invoice.
      dict for {referenceProfile referenceName} $reference {
        if {$name ne $referenceName} {
          continue
        }
        return -code error -errorcode [list TCLPDF ZUGFERD NAME $name] \
            "tclpdf: \"$name\" is the file name of the\
            $referenceProfile profile and this $kind is $profile - a\
            reference profile's name is its own (Factur-X 1.09.2, 7.7);\
            this one is embedded as [join $names {, }], or pass -profile\
            $referenceProfile if that is what the XML is"
      }
      if {[dict exists $reference $profile]} {
        return -code error -errorcode [list TCLPDF ZUGFERD NAME $name] \
            "tclpdf: a $profile $kind is embedded as\
            \"[lindex $names 0]\" and under no other name - Factur-X\
            1.09.2, 7.7 forbids it the names of the ordinary profiles,\
            \"$name\" among them"
      }
      return -code error -errorcode [list TCLPDF ZUGFERD NAME $name] \
          "tclpdf: \"$name\" is not a file name the standards\
          allow - use one of: [join $names {, }]"
    }
    if {$name in [my attachments]} {
      return -code error -errorcode [list TCLPDF ZUGFERD NAME $name] \
          "tclpdf: an attachment named \"$name\" already\
          exists - names in the embedded file name tree have to be unique"
    }
    # The mirror of the guard in attach.tcl, so the two orders answer the
    # same: there a reserved name is refused because the invoice is already
    # in the tree, here the invoice is refused because a reserved name is.
    # Case-insensitively for the same reason - "factur-x.XML" is a key of
    # its own and the same name to a reader (Factur-X 1.09.2, 6.2 and 7.7;
    # Order-X 1.0, 4.1.1).
    foreach existing [my attachments] {
      if {[::tclpdf::attach::isReserved $existing]} {
        return -code error -errorcode [list TCLPDF ZUGFERD NAME $existing] \
            "tclpdf: this document already carries an\
            attachment named \"$existing\", which is a name the hybrid\
            standards reserve for the XML that IS the document a second\
            time - a reader looking the $kind up by name would find two.\
            Give that attachment a name of its own, or drop it"
      }
    }
    # fx:Version is the version of the standard the XML follows - "1.0" for
    # every Factur-X and ZUGFeRD 2.x invoice and for Order-X 1.0 - and it
    # goes into the packet as XML text. Digits and dots only: an empty
    # value used to come out as "<fx:Version/>", and a "<" in it went into
    # the packet unescaped, where the parser refused the whole document at
    # write time.
    set version [dict get $options version]
    if {![regexp {^[0-9]+(\.[0-9]+)*$} $version]} {
      return -code error -errorcode [list TCLPDF ZUGFERD ARGUMENT version] \
          "tclpdf: -version takes a version number such as\
          1.0 - digits and dots - not \"$version\""
    }
    if {![string is boolean -strict [dict get $options compress]]} {
      return -code error -errorcode [list TCLPDF ZUGFERD ARGUMENT compress] \
          "tclpdf: -compress takes a boolean, not\
          \"[dict get $options compress]\""
    }

    # The default /AFRelationship follows the profile, because Factur-X binds
    # the two together: MINIMUM and BASIC WL record too little to stand in
    # for the invoice, so their XML is Data - for every fuller profile the
    # XML IS the invoice a second time, which is what Alternative means.
    # A single value for all profiles gets one of the two families rejected.
    # An order is Data: Order-X 1.0, 4.1.1 allows Data, Source or
    # Alternative for order-x.xml and prescribes none of them, and an
    # order's XML is data for processing - the sample PDFs of the
    # distribution split 12 Data, 6 Source, 6 Alternative. An explicit
    # -relationship still WINS over this default - the profile binds the
    # default and not the option, decided on 2026-08-25 and reasoned out at
    # [relationships] above - and is checked here against the list attach.tcl
    # owns, not left to [attach] at the end; for order-x.xml against the
    # three of 4.1.1 besides.
    set relationship [dict get $options relationship]
    if {$relationship eq {}} {
      if {$family eq "order" || $profile in {MINIMUM {BASIC WL}}} {
        set relationship Data
      } else {
        set relationship Alternative
      }
    } elseif {$relationship ni $::tclpdf::attach::relationships} {
      return -code error -errorcode [list TCLPDF ZUGFERD RELATIONSHIP $relationship] \
          "tclpdf: -relationship must be one of\
          [join $::tclpdf::attach::relationships {, }] - not \"$relationship\""
    } elseif {$relationship ni $::tclpdf::zugferd::relationships} {
      set clause [expr {$family eq "order" ? {Order-X 1.0, 4.1.1}
          : {Factur-X 1.09.2, embedding rules}}]
      return -code error -errorcode [list TCLPDF ZUGFERD RELATIONSHIP $relationship] \
          "tclpdf: -relationship for $name is one of\
          [join $::tclpdf::zugferd::relationships {, }] ($clause) - not\
          \"$relationship\", which is for the other attachments"
    }

    # PDF/A-3 first: the invoice rides on it, and the output intent has to be
    # in place before anything else is written. ONE call, so that a profile
    # pdfa refuses - a missing -icc - refuses before the claim exists rather
    # than after it. Without -icc the profile is the one [pdfa] uses by
    # default - the sRGB profile shipped with the package - and pdfa.tcl is
    # where a missing one is refused, so nothing is decided about it here.
    #
    # -conformance ONLY where nothing has been declared yet. B is the level
    # every invoice reaches without a structure tree and the least the
    # standards ask for, so it is the right default - but it was passed
    # unconditionally, and a caller who had said [pdfa -conformance A]
    # before the invoice got B back without a word: measured 2026-08-25,
    # the structure tree was still written and the packet said
    # pdfaid:conformance B - paid for, not claimed. Factur-X 1.09.2 and
    # Order-X 1.0, 4.1 ask for PDF/A-3 and leave the level open, so there
    # is nothing here to overrule the caller with. The PART is not left
    # open: both standards name PDF/A-3, and [pdfa] refuses a part that
    # cannot carry an attachment anyway.
    set declaration [list -part 3]
    if {[my state pdfa] eq {}} {
      lappend declaration -conformance B
    }
    if {[dict get $options icc] ne {}} {
      lappend declaration -profile [dict get $options icc]
    }
    my pdfa {*}$declaration
    my pdfa extension [::tclpdf::zugferd extensionSchema $family]
    my pdfa extension [::tclpdf::zugferd properties $name $type $version \
        $profile $family]

    set description [dict get $options description]
    if {$description eq {}} {
      set description "$profile $kind data"
    }
    # ModDate in the /Params dictionary is required for the attachment (Factur-X
    # 1.09.2, embedding rules; Order-X 1.0, 4.1.1). The MODIFICATION TIME OF
    # THE XML FILE is used rather than the current time: it is what the field
    # means, and it keeps the output reproducible - the same invoice written
    # twice has to give the same bytes.
    my attach $path -name $name -relationship $relationship \
        -mime text/xml -compress [dict get $options compress] \
        -description $description \
        -date [::tclpdf::pdfObj date [file mtime $path]]

    my state zugferd [dict create name $name profile $profile \
        type $type version $version \
        relationship $relationship bytes [string length $bytes]]
    return $profile
  }
}

# Read BT-24 out of the XML and translate it into the document family and
# the conformance level: {invoice {EN 16931}}, {order COMFORT}.
#
# One regexp, no XML parser: the element occurs once, its content is a URN,
# and pulling in a DOM to read a single string would make tdom a runtime
# dependency of every invoice.
proc ::tclpdf::zugferd::identify {bytes} {
  variable profiles

  # A UTF-16 file can never match the pattern below - every ASCII letter
  # carries a NUL neighbour - and the BT-24 refusal it got instead blamed
  # the content for the encoding. The byte order mark is the giveaway.
  set bom [string range $bytes 0 1]
  if {$bom eq "\xFF\xFE" || $bom eq "\xFE\xFF"} {
    return -code error -errorcode [list TCLPDF ZUGFERD XML encoding] \
        "tclpdf: this XML is UTF-16 encoded - re-encode the\
        XML as UTF-8"
  }
  # The same refusal one encoding further out. UTF-16 was caught because the
  # BT-24 pattern below cannot match it; an ISO-8859-1 file matches
  # perfectly and went in byte for byte, declaration and all - measured
  # 2026-08-26, "Lieferänt" as the single byte E4 under
  # encoding="ISO-8859-1", accepted, attached, Mustang "valid" and veraPDF
  # 3b conformant. The invoice is then a file whose bytes say one thing and
  # whose /Subtype text#2Fxml says another to every reader that does not
  # open it as XML.
  #
  # Two halves, because a file can get this wrong in two ways: the
  # DECLARATION may name an encoding that is not UTF-8, and the BYTES may
  # not be UTF-8 whatever the declaration says (an ISO-8859-1 file with no
  # declaration at all is the common one out of a spreadsheet export). A
  # byte order mark before the declaration is fine and is what XML 1.0, 4.3.3
  # provides for.
  set head [string range $bytes 0 255]
  if {[string range $head 0 2] eq "\xEF\xBB\xBF"} {
    set head [string range $head 3 end]
  }
  if {[regexp -nocase {^<\?xml[^>]*?encoding[[:space:]]*=[[:space:]]*["']([^"']+)["']} \
      $head -> declared] && ![string equal -nocase $declared utf-8]} {
    return -code error -errorcode [list TCLPDF ZUGFERD XML encoding] \
        "tclpdf: this XML declares encoding=\"$declared\" - the\
        invoice is embedded byte for byte and is read as UTF-8 by every\
        reader of the attachment, so re-encode the XML as UTF-8 and say so\
        in its declaration"
  }
  # [encoding convertfrom] answers rather than throwing under 8.6, so the
  # round trip is what says it: bytes that are not UTF-8 do not come back as
  # themselves.
  if {[catch {encoding convertfrom utf-8 $bytes} text]
      || [encoding convertto utf-8 $text] ne $bytes} {
    return -code error -errorcode [list TCLPDF ZUGFERD XML encoding] \
        "tclpdf: this XML is not UTF-8 - it carries bytes no\
        UTF-8 sequence can hold. Re-encode it as UTF-8 (encoding convertto\
        utf-8 \[encoding convertfrom iso8859-1 \$bytes\] for a Latin-1 file)"
  }
  if {![regexp {GuidelineSpecifiedDocumentContextParameter>.*?<ram:ID>([^<]+)<} \
      $bytes -> identifier]} {
    return -code error -errorcode [list TCLPDF ZUGFERD XML identifier] \
        "tclpdf: this XML carries no BT-24 specification\
        identifier (GuidelineSpecifiedDocumentContextParameter) - it is not a\
        ZUGFeRD or Factur-X invoice or an Order-X order"
  }
  set identifier [string trim $identifier]
  if {[dict exists $profiles $identifier]} {
    return [dict get $profiles $identifier]
  }
  # XRechnung rides on the same construction with its own identifier, and new
  # ones appear with every release - so the shape is recognised rather than
  # the exact string, and anything else is refused by name.
  if {[string match {*xrechnung*} [string tolower $identifier]]} {
    return {invoice XRECHNUNG}
  }
  return -code error -errorcode [list TCLPDF ZUGFERD XML $identifier] \
      "tclpdf: unknown BT-24 specification identifier\
      \"$identifier\" - pass -profile to override. Guessing here is how an\
      EXTENDED invoice goes out labelled BASIC"
}

# The conformance level alone - what [zugferd profile] answers.
proc ::tclpdf::zugferd::profile {bytes} {
  return [lindex [identify $bytes] 1]
}

# The namespace URI of the fx: schema for a document family - see the
# header: Factur-X carries ":invoice", Order-X does not.
proc ::tclpdf::zugferd::namespaceURI {family} {
  if {$family eq "order"} {
    return "urn:factur-x:pdfa:CrossIndustryDocument:1p0#"
  }
  return "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
}
# The PDF/A extension schema description, word for word from the normative
# sample. Required because PDF/A only permits metadata whose schema is
# described in the packet itself - without this the file fails validation
# even though the fx: properties are correct. The family - invoice by
# default, order for Order-X - picks the namespace URI, nothing else.
proc ::tclpdf::zugferd::extensionSchema {{family invoice}} {
    return [string map [list @namespaceURI@ [namespaceURI $family]] {    <rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
      <pdfaExtension:schemas>
        <rdf:Bag>
          <rdf:li rdf:parseType="Resource">
            <pdfaSchema:schema>Factur-X PDFA Extension Schema</pdfaSchema:schema>
            <pdfaSchema:namespaceURI>@namespaceURI@</pdfaSchema:namespaceURI>
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
    </rdf:Description>}]
}

# The four properties themselves. This is what a recipient's software reads to
# find out that there is an invoice or an order, what it is called and which
# profile it follows - before opening the attachment.
proc ::tclpdf::zugferd::properties {name type version conformance {family invoice}} {
  append xml "    <rdf:Description rdf:about=\"\" xmlns:fx=\"[namespaceURI $family]\">\n"
  append xml "      <fx:DocumentType>$type</fx:DocumentType>\n"
  append xml "      <fx:DocumentFileName>$name</fx:DocumentFileName>\n"
  append xml "      <fx:Version>$version</fx:Version>\n"
  append xml "      <fx:ConformanceLevel>$conformance</fx:ConformanceLevel>\n"
  append xml "    </rdf:Description>"
  return $xml
}

package provide tclpdf::zugferd 1.6