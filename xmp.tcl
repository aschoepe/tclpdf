#
# tclpdf - PDF generation for Tcl
#
# xmp - the metadata packet, and who is allowed to write into it (XMP part 1)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A PDF says who made it twice: in the Info dictionary, which is deprecated in
# 2.0, and in an XMP packet, which is XML and is what every standard from
# PDF/A on reads. The packet has one slot per document, so the moment two
# topics want to write into it - PDF/A its part and conformance, PDF/UA its
# part and revision - neither can own it any more.
#
# Hence this module. It owns the packet and nothing else; the topics register
# what they want to say:
#
#   my xmpSchema pdfaid http://www.aiim.org/pdfa/ns/id/ \
#       {part conformance} PdfaXmpBody
#
# The last argument is a METHOD, called when the packet is built, and that is
# the whole trick: a topic's part number may still change after it registered
# - [pdfa -part 3] can be called twice - and a callback reads the state as it
# is at write time rather than as it was at registration. Registration order
# is packet order, so a document that declares PDF/A and then PDF/UA gets
# pdfaid before pdfuaid, every time.
#
# The method answers with a list of entries, each one {kind tag value}:
#
#   {text part 2}
#   {bag declarations {{conformsTo http://pdfa.org/declarations/wtpdf/#reuse1.0}}}
#
# The kind is stated rather than derived from the shape of the value, and
# that is deliberate. A value's shape is not a reliable signal in Tcl - every
# string is also a list, and a two word title would parse as a structure. The
# same mistake once cost this package a table cell that quietly dropped all
# but its last word.
#
# Three descriptions are written by this module itself and belong to no topic:
# dc, xmp and pdf carry title, author, subject, dates and producer, all read
# from the Info dictionary. They are not PDF/A's property - an ordinary
# document has them too - and putting them here is what lets [ua] produce a
# valid packet with no PDF/A anywhere in the document.
#
# The XML is built with tdom rather than by appending strings, following the
# construction in the author's ooxml package. Three things come out of that
# and each one had been a hand written detail before: escaping is the
# parser's business, a raw contribution from outside is PARSED on the way in
# and a malformed one fails at the call instead of in a validator, and the
# packet is well formed by construction rather than by review.
#
# Two mechanics of tdom that are not obvious and both were measured here:
# an element command has to be declared with [dom createNodeCmd] before
# [appendFromScript] can use it, and it needs -namespace, or a prefixed
# ATTRIBUTE inside the script - rdf:about is one - is refused with "attribute
# prefix does not resolve".
#

package require Tcl 8.6.11-
package require TclOO
package require tdom 0.9.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::xmp {
  namespace export {[a-z]*}
  namespace ensemble create

  variable namespaces {
    x       "adobe:ns:meta/"
    rdf     "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    dc      "http://purl.org/dc/elements/1.1/"
    xmp     "http://ns.adobe.com/xap/1.0/"
    pdf     "http://ns.adobe.com/pdf/1.3/"
  }

  # Which element commands have been declared, keyed by the PAIR of tag name
  # and namespace URI: {name uri} -> command. [dom createNodeCmd] overwrites
  # silently when called twice, and the dict keeps that work out of the
  # second document in a process that writes many - but the key is the pair
  # and not the name alone, and that is the whole point: see [declare].
  variable commands {}

  # Counts the second and every further URI one tag name is used with, so
  # each pair gets an element command of its own.
  variable serial 0

  # The text node command is created with tdom's text check OFF, and on
  # purpose: under Tcl 8.6 a character outside the BMP arrives as a surrogate
  # pair (TCL_UTF_MAX 3), which the check refuses as "Invalid text value" -
  # a legal title would make the document unwritable. The pair is not broken
  # text: [encoding convertto utf-8] of 8.6.11+ folds it back into the real
  # character when the packet is encoded for the stream. Tcl 9 stores the
  # character whole and tdom serialises it as a character reference; there
  # the check never fired. [dom createNodeCmd] captures the setting at
  # CREATION time - measured; toggling it around the build does nothing - so
  # it is toggled around this one line and restored for everyone else.
  #
  # What the switch costs is that tdom no longer refuses a C0 control
  # character either, and XML 1.0, 2.2 allows none of them but tab, newline
  # and carriage return - a "\x07" out of an Info entry went into the packet
  # as the byte 07, where veraPDF said isCompliant="true" and xmllint said
  # "PCDATA invalid Char value 7" (measured 2026-08-25). U+0000 cannot even
  # be written as a character reference. [CheckText] below takes that half
  # of the check back, keeping the surrogate pair this switch is here for.
  set textCheck [dom setTextCheck]
  dom setTextCheck 0
  dom createNodeCmd textNode Text
  dom setTextCheck $textCheck
  unset textCheck
}

# Declare the element commands for one schema. Called by [declare] below and
# by every topic that contributes, through [xmpSchema].
proc ::tclpdf::xmp::declare {prefix uri tags} {
  variable commands
  variable serial
  foreach tag $tags {
    set name [expr {$prefix eq {} ? $tag : "$prefix:$tag"}]
    if {[dict exists $commands [list $name $uri]]} {
      continue
    }
    # A prefix is not a name. It is a label a DOCUMENT puts on a URI, and two
    # documents in one process may label two different URIs with it - which
    # is legal XML and was silently wrong here: keyed by the name alone, the
    # second document skipped the declaration and kept the FIRST document's
    # element command, whose -namespace is captured at creation. Measured
    # 2026-08-25: the second document wrote
    # <my:foo xmlns:my="http://example.com/one/"> under an rdf:Description
    # declaring xmlns:my="http://example.com/TWO/" - the property stood in
    # the namespace of a document that had already been written and closed.
    # A single document is always right, which is why neither the suite nor
    # a validator ever saw it; a server or a batch run is not.
    #
    # So the pair is the key, and each pair gets an element command of its
    # own. The FIRST URI seen for a name keeps the plain command name, so a
    # process that uses one URI per prefix - every normal one - builds
    # exactly the commands it always did.
    set command Tag_$name
    foreach key [dict keys $commands] {
      if {[lindex $key 0] eq $name} {
        set command Tag_[incr serial]_$name
        break
      }
    }
    # Refused with the caller's words, by tdom's own validator: the raw
    # "Invalid tag name 'Tag_...'" out of [dom createNodeCmd] names an
    # internal command, not the schema the caller wrote. The catch stays as
    # the net under it - a bad PREFIX passes the tag check and still fails
    # in the same call.
    if {![dom isNCName $tag] || [catch {namespace eval ::tclpdf::xmp \
        [list dom createNodeCmd -tagName $name -namespace $uri \
        elementNode $command]}]} {
      return -code error -errorcode [list TCLPDF XMP TAG $tag] \
          "tclpdf: xmpSchema tag \"$tag\" is not a valid XML\
          name (schema $prefix)"
    }
    dict set commands [list $name $uri] $command
  }
  return
}

namespace eval ::tclpdf::xmp {
  variable namespaces
  declare rdf [dict get $namespaces rdf] {RDF Description Alt Bag Seq li}
  declare dc [dict get $namespaces dc] {title creator description language}
  declare xmp [dict get $namespaces xmp] {CreateDate ModifyDate CreatorTool}
  declare pdf [dict get $namespaces pdf] {Producer Keywords}
}

# Hold one value against the characters XML allows (XML 1.0, 2.2:
# #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]).
# "where" names the place in the packet, so the caller learns which of their
# values carries it.
#
# REFUSED, not repaired, and that is a decision rather than the easy way out.
# A control character in a title is data the caller did not mean to send -
# out of a database column, a scanned field, a CSV - and the two ways to
# repair it both lie: dropping it hands out a title that is not the one that
# was set, and a replacement character claims a character was there. The
# packet exists to say what the document is. This is the same answer the
# package gives for a character the font has no glyph for: the writer is the
# last place in the chain that still knows what was meant, and it says so
# instead of quietly deciding.
#
# The check is deliberately NOT tdom's own (see the note where the text node
# command is created): that one refuses the surrogate PAIR Tcl 8.6 stores an
# astral character as, and refusing a legal emoji in a title would be a
# worse bug than the one being fixed. So the pair is walked here by hand -
# a high surrogate followed by a low one is one character and passes, a lone
# one does not. Under Tcl 8.6 a lone surrogate is encoded to the three bytes
# ED A0 BD, which is not UTF-8 at all; under Tcl 9 [encoding convertto
# utf-8] throws, and the caller would see a raw Tcl error out of the writer
# instead of a tclpdf one (both measured 2026-08-25).
#
# Character by character rather than by a regular expression, because the
# two interpreters do not agree on what a character is: Tcl 8.6 holds U+1F600
# as D83D DE00 and Tcl 9 as one code point, so no single character class
# reads both the same way. Metadata values are short - this is not a hot
# path.
proc ::tclpdf::xmp::CheckText {value where} {
  set length [string length $value]
  for {set index 0} {$index < $length} {incr index} {
    set code [scan [string index $value $index] %c]
    if {$code >= 0xD800 && $code <= 0xDBFF} {
      set next [expr {$index + 1 < $length
          ? [scan [string index $value [expr {$index + 1}]] %c] : -1}]
      if {$next >= 0xDC00 && $next <= 0xDFFF} {
        incr index
        continue
      }
    } elseif {$code == 0x9 || $code == 0xA || $code == 0xD
        || ($code >= 0x20 && $code < 0xD800)
        || ($code >= 0xE000 && $code <= 0xFFFD)
        || ($code >= 0x10000 && $code <= 0x10FFFF)} {
      continue
    }
    if {$code >= 0xD800 && $code <= 0xDFFF} {
      return -code error -errorcode [list TCLPDF XMP SURROGATE $where $code] \
          "tclpdf: $where carries the unpaired surrogate\
          U+[format %04X $code] - a character outside the BMP has to be a\
          high surrogate followed by a low one, or it is not a character"
    }
    return -code error -errorcode [list TCLPDF XMP CHAR $where $code] \
        "tclpdf: $where carries U+[format %04X $code], which XML does not\
        allow in a document (XML 1.0, 2.2) - the XMP packet has to be well\
        formed XML, and no escape can carry this character into it"
  }
  return
}

# A raw contribution, parsed - the caller owns the document that comes back
# and has to delete it.
#
# It is parsed inside an rdf:RDF of its own rather than straight into the
# tree, and that is not decoration. A contribution written for the packet may
# use the prefixes that are in scope THERE - the Factur-X extension schema
# says rdf:Bag and rdf:li without declaring rdf, because the rdf:RDF around
# it always has. Parsed on its own it is not well formed; parsed in a wrapper
# carrying the same declaration it is.
# The element command for one tag of one schema - the pair of tag name and
# namespace URI, never the name alone, see [declare]. A tag the schema never
# declared used to surface as tdom's raw "invalid command name Tag_..." with
# no word about which schema went wrong, so it is named here together with
# what the schema did declare.
proc ::tclpdf::xmp::Command {prefix tag uri} {
  variable commands
  set key [list "$prefix:$tag" $uri]
  if {[dict exists $commands $key]} {
    return [dict get $commands $key]
  }
  set known {}
  foreach declared [dict keys $commands] {
    lassign $declared name declaredUri
    if {$declaredUri eq $uri && [string equal -length \
        [string length "$prefix:"] "$prefix:" $name]} {
      lappend known [string range $name [string length "$prefix:"] end]
    }
  }
  return -code error -errorcode [list TCLPDF XMP TAG $prefix $tag] \
      "tclpdf: unknown tag \"$tag\" for XMP schema \"$prefix\" - declared\
      are: [join $known {, }]"
}

proc ::tclpdf::xmp::ParseRaw {xml} {
  variable namespaces
  if {[catch {dom parse "<rdf:RDF xmlns:rdf=\"[dict get $namespaces rdf]\"\
      >$xml</rdf:RDF>"} fragment message]} {
    return -code error -errorcode [list TCLPDF XMP RAW] \
        "tclpdf: XMP contribution is not well formed XML -\
        [dict get $message -errorinfo]"
  }
  return $fragment
}

# The same parse, thrown away again: the check that a contribution is well
# formed, made where the call that produced it is still on the stack. Which
# is what the head of this module has always promised and what [xmpRaw] did
# not do - the parse happened at WRITE time, so a broken contribution was
# taken silently and made the document unwritable from then on, with no way
# to take it back out (measured 2026-08-25: "pdfa extension {<rdf:Description>}"
# returned 0, and every [write] afterwards failed).
proc ::tclpdf::xmp::CheckRaw {xml} {
  [ParseRaw $xml] delete
  return
}

# The moment as XMP wants it: ISO 8601 with the zone offset as +HH:MM, where
# [clock format %z] gives +HHMM.
#
# The colon was missing from every document this package has written. The line
# that was supposed to insert it read
#
#   string replace $text end-1 end-2 ":[string range $text end-1 end]"
#
# and does nothing at all: with last before first, [string replace] returns
# the string unchanged rather than inserting at that point. No validator
# objected - veraPDF accepts both spellings - so it survived until the packet
# was rebuilt with a parser.
proc ::tclpdf::xmp::stamp {{seconds {}}} {
  if {$seconds eq {}} {
    set seconds [clock seconds]
  }
  set text [clock format $seconds -format "%Y-%m-%dT%H:%M:%S%z"]
  return "[string range $text 0 end-2]:[string range $text end-1 end]"
}

# The moment a PDF date string names (7.9.4, "D:YYYYMMDDHHmmSSOHH'mm'"), as
# XMP wants it - or an empty string when the text is not a PDF date. Table
# 317 pairs Info's CreationDate with xmp:CreateDate and ModDate with
# xmp:ModifyDate; a caller who set either through [info] gets it mirrored
# into the packet rather than the packet saying [Created] for both while
# the dictionary says something else. The fields are what [parseDate] in
# document.tcl reads out - one parser for the check at the call and for
# this conversion.
#
# XMP dates are as partial as PDF ones (XMP part 1, 8.2.1.4: YYYY, YYYY-MM,
# YYYY-MM-DD, then a time with at least hh:mm), so a date without a time
# stays a date. A time is written with seconds and with the zone where the
# PDF date has one - "Z" as Z, an offset as +HH:MM. A PDF date that gives
# an hour and no minutes gets ":00" for them, as XMP has no shorter form.
#
# Where the PDF date gives a time and NO zone - "D:20190301120000", the
# spelling half the generators in the wild use - the TIME IS DROPPED and the
# date stays. 8.2.1.4 has no form for a time without a zone: the zone
# designator is optional only while there is no time at all. And no zone can
# be invented for it, because ISO 32000-1, 7.9.4 says the relationship of
# such a time to UT is UNKNOWN - writing Z would claim UTC and writing the
# local offset would claim the machine that happened to run the job. So the
# packet says less rather than something that is not known: a date is a
# legal XMP value, "2019-03-01T12:00:00" is not one (measured 2026-08-25:
# veraPDF passes it all the same, which is why only a test holds this).
proc ::tclpdf::xmp::stampFromPdf {date} {
  set fields [::tclpdf::document::parseDate $date]
  if {$fields eq {}} {
    return {}
  }
  dict with fields {}
  # Absent minutes and seconds are spelled "00" - through [string], not
  # through [expr], which would hand back the number 0 for the string "00".
  foreach field {minute second zoneHour zoneMinute} {
    if {[set $field] eq {}} {
      set $field 00
    }
  }
  set text $year
  if {$month ne {}} {
    append text - $month
    if {$day ne {}} {
      append text - $day
      if {$hour ne {} && $sign ne {}} {
        append text T $hour : $minute : $second
        if {$sign eq "Z"} {
          append text Z
        } else {
          append text $sign $zoneHour : $zoneMinute
        }
      }
    }
  }
  return $text
}

# One rdf:Description under $rdf, declaring $prefix, filled by $script.
#
# The script runs in the CALLER's frame, so it sees the caller's variables -
# which is what lets [packet] write $title and $items straight into the tags
# without threading anything through.
#
# That convenience has a price, and it was paid once: the script's own loop
# variables are the caller's variables too. A [foreach {inner text}] in here
# overwrote a variable called text in [packet], and the packet went out with a
# URI in front of its opening processing instruction. See the naming note at
# the end of [packet].
proc ::tclpdf::xmp::Describe {rdf prefix uri script} {
  $rdf appendFromScript { Tag_rdf:Description rdf:about {} {} }
  set description [$rdf lastChild]
  $description setAttributeNS {} xmlns:$prefix $uri
  uplevel 1 [list $description appendFromScript $script]
  # A description with nothing in it says nothing and is left out - an empty
  # contribution should not become an empty element.
  if {![llength [$description childNodes]]} {
    $rdf removeChild $description
    $description delete
  }
  return
}

# Build the packet.
#
#   descriptions   list of {prefix uri {{kind tag value} ...}}
#   info           dict with title, author, subject, producer, and optionally
#                  creator, keywords, language - the document's RFC 3066
#                  tag, written as dc:language (a bag of locales in XMP
#                  part 1) - created and modified, the Info dictionary's
#                  CreationDate and ModDate as PDF date strings
#   raw            list of rdf:Description elements as XML text
#
# A procedure rather than a method, and not by preference: [appendFromScript]
# resolves the Tag_ commands in the namespace it runs in, and a TclOO method
# runs in the class namespace where they are not.
proc ::tclpdf::xmp::packet {descriptions info raw {seconds {}}} {
  variable namespaces
  set title [dict get $info title]
  set author [dict get $info author]
  set subject [dict get $info subject]
  set producer [dict get $info producer]
  # ISO 32000-1 Table 317 pairs the Info entries with the packet: Creator is
  # xmp:CreatorTool, Producer is pdf:Producer, Keywords is pdf:Keywords. The
  # tool that first created the document is the caller's application when it
  # names one, and this package when it does not - CreatorTool used to carry
  # the producer in both cases, so a document with "info Creator" set said
  # two different things about itself.
  set creator [expr {[dict exists $info creator] ? [dict get $info creator] : {}}]
  set keywords [expr {[dict exists $info keywords] ? [dict get $info keywords] : {}}]
  set language [expr {[dict exists $info language] ? [dict get $info language] : {}}]
  # The moment is HANDED IN by the caller, who shares it with the Info
  # dictionary's CreationDate - two clock reads here and there could straddle
  # a second and the two dates would disagree for the life of the file.
  # A CreationDate or ModDate the caller SET wins over it for the property
  # Table 317 pairs it with: the packet describes the dictionary, and a
  # dictionary saying 2019 under a packet saying today is what ISO 19005-1,
  # 6.7.3 forbids and what a reader comparing the two would report.
  set now [stamp $seconds]
  set created $now
  set modified $now
  foreach {key variable} {created created modified modified} {
    if {[dict exists $info $key] && [dict get $info $key] ne {}} {
      set converted [stampFromPdf [dict get $info $key]]
      if {$converted ne {}} {
        set $variable $converted
      }
    }
  }

  # Everything a caller supplies is held against XML's own character set
  # before a document exists, so a refusal leaves nothing to clean up and
  # names the property rather than a line number in a validator's report.
  # Values from the Info dictionary and from every schema method alike -
  # both reach the packet as text, and tdom's own check is off for them
  # (see the note at the text node command).
  foreach {value where} [list \
      $title "dc:title (the Info Title)" \
      $author "dc:creator (the Info Author)" \
      $subject "dc:description (the Info Subject)" \
      $language "dc:language (the document language)" \
      $creator "xmp:CreatorTool (the Info Creator)" \
      $keywords "pdf:Keywords (the Info Keywords)" \
      $producer "pdf:Producer (the Info Producer)"] {
    CheckText $value $where
  }

  # Every tag a schema method answers has to have been declared in the
  # [xmpSchema] call that registered the schema: the element commands exist
  # for declared tags only, and an undeclared one used to surface as tdom's
  # raw "invalid command name Tag_..." with no word about which schema went
  # wrong. Checked up front, where the schema and its declared tags can both
  # be named - and before the document is created, so there is nothing to
  # clean up.
  #
  # The lookup is by tag name AND the schema's URI, because that is what an
  # element command belongs to (see [declare]); the resolved command names
  # are carried into the build below, which must not go back to spelling
  # "Tag_$prefix:$tag" - that name belongs to whichever URI claimed it first
  # in this process.
  set built {}
  foreach entry $descriptions {
    lassign $entry prefix uri items
    CheckText $uri "the namespace URI of XMP schema \"$prefix\""
    set resolved {}
    foreach item $items {
      lassign $item kind tag value
      # A bag's resources carry tags of the same schema (see the build
      # below), and they are held to the same declaration and the same
      # characters as the tag around them.
      if {$kind eq "bag"} {
        set resources {}
        foreach resource $value {
          set pairs {}
          foreach {resourceTag resourceValue} $resource {
            CheckText $resourceValue "$prefix:$resourceTag"
            lappend pairs [Command $prefix $resourceTag $uri] $resourceValue
          }
          lappend resources $pairs
        }
        set value $resources
      } else {
        CheckText $value "$prefix:$tag"
      }
      lappend resolved [list $kind [Command $prefix $tag $uri] $value]
    }
    lappend built [list $prefix $uri $resolved]
  }

  # Only x and rdf are declared at the root; every other prefix is declared on
  # the rdf:Description that uses it, which is the shape Adobe's own writer
  # produces and the one every XMP in the wild has.
  #
  # The alternative - all of them at the root - is equally valid XML and was
  # measured to validate just as well. What it breaks is naive readers: tdom
  # then repeats the declaration on the first element using each prefix, and
  # "<pdfaid:conformance xmlns:pdfaid=...>U<" no longer matches a pattern
  # looking for "pdfaid:conformance>". A test here and an example both broke
  # on exactly that, which is warning enough about what it does to a caller's
  # tooling.
  #
  # It takes createDocumentNS plus -namespace on the element commands to get
  # here, and the declaration has to be set on the description BEFORE its
  # children are built - see [Describe].
  set document [dom createDocumentNS [dict get $namespaces x] x:xmpmeta]
  set root [$document documentElement]
  $root setAttributeNS {} xmlns:rdf [dict get $namespaces rdf]
  $root appendFromScript { Tag_rdf:RDF {} }
  set rdf [$root firstChild]

  # One description per schema, and each one built in three steps: create the
  # element, declare its prefix, THEN fill it. The order is the whole point.
  # Declared afterwards, tdom writes the xmlns twice - once where it was put
  # and once on the first child that uses the prefix - because by then the
  # children were serialised against a scope that did not have it. Declared
  # first, it appears exactly once, which is the shape every other XMP writer
  # produces and the one a reader looking for "pdfaid:part>" survives.
  foreach entry $built {
    lassign $entry prefix uri items
    Describe $rdf $prefix $uri {
      foreach item $items {
        lassign $item kind xmpTag value
        switch -- $kind {
          text {
            $xmpTag { Text $value }
          }
          bag {
            $xmpTag {
              Tag_rdf:Bag {
                foreach resource $value {
                  Tag_rdf:li rdf:parseType Resource {
                    foreach {xmpResourceTag resourceValue} $resource {
                      $xmpResourceTag { Text $resourceValue }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  Describe $rdf dc [dict get $namespaces dc] {
    if {$title ne {}} {
      Tag_dc:title { Tag_rdf:Alt { Tag_rdf:li xml:lang x-default { Text $title } } }
    }
    if {$author ne {}} {
      Tag_dc:creator { Tag_rdf:Seq { Tag_rdf:li { Text $author } } }
    }
    if {$subject ne {}} {
      Tag_dc:description { Tag_rdf:Alt { Tag_rdf:li xml:lang x-default { Text $subject } } }
    }
    # The same tag the catalog's /Lang carries, so the packet says what the
    # catalog says - a screen reader may take either.
    if {$language ne {}} {
      Tag_dc:language { Tag_rdf:Bag { Tag_rdf:li { Text $language } } }
    }
  }
  Describe $rdf xmp [dict get $namespaces xmp] {
    Tag_xmp:CreateDate { Text $created }
    Tag_xmp:ModifyDate { Text $modified }
    # Without a Producer - "info Producer {}" removes the key - there is no
    # tool to name, and an empty element would name one that is empty.
    if {$creator ne {} || $producer ne {}} {
      Tag_xmp:CreatorTool { Text [expr {$creator ne {} ? $creator : $producer}] }
    }
  }
  Describe $rdf pdf [dict get $namespaces pdf] {
    if {$producer ne {}} {
      Tag_pdf:Producer { Text $producer }
    }
    if {$keywords ne {}} {
      Tag_pdf:Keywords { Text $keywords }
    }
    # Info's Trapped is NOT mirrored, although ISO 32000-1 Table 317 pairs
    # it with pdf:Trapped: the predefined PDF schema of ISO 19005 - the
    # 2004/2005 XMP specification's - knows Keywords, PDFVersion and
    # Producer only, and veraPDF 1.30 fails a PDF/A file carrying
    # pdf:Trapped on 6.6.2.3.1 (measured 2026-08-18, two failed checks on
    # a 3u document that was clean without it). The dictionary keeps the
    # name; the packet stays inside the schema every validator knows.
  }

  # Parsed, not appended as text - see [ParseRaw]. A broken contribution has
  # already been refused by [xmpRaw] at the call that made it; this parse is
  # the one whose nodes are kept, and it still cleans up after itself for a
  # contribution that reached the state some other way.
  foreach xml $raw {
    if {[catch {ParseRaw $xml} fragment options]} {
      $document delete
      return -options $options $fragment
    }
    foreach child [[$fragment documentElement] childNodes] {
      $rdf appendChild [$child cloneNode -deep]
    }
    $fragment delete
  }
  set body [$root asXML -indent 2]
  $document delete

  # [set] rather than [append] on the first line, and a name no contributed
  # script would choose. A script passed to [Describe] runs in THIS frame, so
  # its loop variables are these variables - and one of them was called text,
  # which is what [append text] then continued. The packet came out with a
  # declaration URI in front of its opening processing instruction, which qpdf
  # accepted without a word and veraPDF reported as an XMP with nothing in it.
  #
  # The begin attribute is the byte order mark, ONE character U+FEFF, and
  # the packet is encoded to UTF-8 on its way into the stream (see
  # [metadata] and WriteMetadata) - which turns it into the three bytes EF
  # BB BF that XMP part 1, 7.3.2 asks for. It used to be written as the
  # three Latin-1 CHARACTERS \xef\xbb\xbf, and the encoding then made six
  # bytes of them, C3 AF C2 BB C2 BF: no validator objected, and every
  # packet this package wrote carried a begin attribute that was not a BOM.
  set packet "<?xpacket begin=\"\ufeff\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
  append packet $body "\n"
  # The trailing padding is prescribed: it lets a tool rewrite the packet in
  # place without moving every byte after it (XMP part 1, 7.3.2).
  append packet [string repeat " " 100] "\n"
  append packet "<?xpacket end=\"w\"?>\n"
  return $packet
}

oo::define ::tclpdf::document::document {

  # my xmpSchema <prefix> <uri> <tags> <method>
  #
  # Registering the same prefix twice replaces the entry rather than adding a
  # second one: a topic that is declared twice must not describe itself twice
  # in the packet.
  method xmpSchema {prefix uri tags method} {
    ::tclpdf::xmp::declare $prefix $uri $tags
    set schemas [my state xmpSchemas]
    set replaced 0
    set result {}
    foreach entry $schemas {
      if {[lindex $entry 0] eq $prefix} {
        lappend result [list $prefix $uri $method]
        set replaced 1
      } else {
        lappend result $entry
      }
    }
    if {!$replaced} {
      lappend result [list $prefix $uri $method]
    }
    my state xmpSchemas $result
    # The build hook is shared with [xmpRaw]: whichever of the two is called
    # first subscribes it, so the guard looks at both states - subscribed
    # twice, the packet would be rebuilt twice on every write.
    if {![llength $schemas] && ![llength [my state xmpRaw]]} {
      my onSelf catalog XmpCatalog
    }
    return
  }

  # my xmpRaw <xml>
  #
  # A whole rdf:Description written by the caller, for what does not fit the
  # tag and value form: a PDF/A extension schema description is one of these,
  # and it is a page of RDF that no accessor could usefully model.
  #
  # Subscribes the packet build exactly as [xmpSchema] does: a packet needs
  # no conformance claim, and a document whose only contribution is a raw
  # one gets its packet too. It did not, once - the hook belonged to
  # [xmpSchema] alone, and of two equal-ranking ways into the packet only
  # one triggered the build: the raw contribution was stored, the write
  # said nothing, and the file had no /Metadata at all.
  method xmpRaw {xml} {
    # Parsed HERE, not at write time. The head of this module has promised
    # since it was written that a raw contribution fails at the call, and it
    # did not: the parse happened while the packet was built, so a broken
    # contribution was accepted without a word, made every [write] fail from
    # then on, and could not be taken back out again - the state holds no
    # way to remove one. Measured 2026-08-25.
    ::tclpdf::xmp::CheckRaw $xml
    set raw [my state xmpRaw]
    if {![llength $raw] && ![llength [my state xmpSchemas]]} {
      my onSelf catalog XmpCatalog
    }
    lappend raw $xml
    my state xmpRaw $raw
    return
  }

  # Written at catalog time, so every topic has had its chance to register.
  # An explicit [metadata] wins: a caller who supplies their own packet has
  # said something more specific than any of this.
  #
  # Rebuilt on EVERY write, not only on the first. The packet used to be
  # built once and then left standing, because [metadata] answered non-empty
  # from the second write on - so a title or language changed between two
  # writes reached the Info dictionary, which is rebuilt per write, and never
  # the packet: the two halves of the file disagreed about the document.
  # Only PDF/A-1 validators say so (ISO 19005-1, 6.7.3 - measured with
  # veraPDF: the 1b profile flags a diverging dc:title, 2b and 3b do not);
  # the packet is wrong all the same, since it exists to describe the
  # document as it is.
  #
  # The caller's packet is told from this module's own by comparing with what
  # was last built here (xmpBuilt): what [metadata] holds is ours if it is
  # what we put there, and anything else was set from outside and stays. A
  # second write of an UNCHANGED document still comes out byte-identical -
  # the moment comes from [Created] and everything else from state that has
  # not moved.
  method XmpCatalog {} {
    set current [my metadata]
    if {$current ne {} && $current ne [my state xmpBuilt]} {
      return
    }
    set descriptions {}
    foreach entry [my state xmpSchemas] {
      lassign $entry prefix uri method
      set pairs [my $method]
      if {[llength $pairs]} {
        lappend descriptions [list $prefix $uri $pairs]
      }
    }
    my state xmpBuilt [my metadata [::tclpdf::xmp packet $descriptions \
        [dict create \
            title [my info Title] author [my info Author] \
            subject [my info Subject] producer [my info Producer] \
            creator [my info Creator] keywords [my info Keywords] \
            language [my language] \
            created [my info CreationDate] modified [my info ModDate]] \
        [my state xmpRaw] [my Created]]]
    return
  }
}

package provide tclpdf::xmp 1.5