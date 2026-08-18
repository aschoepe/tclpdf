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
# Two promises ARE checked here, and only because they are cheap and certain.
# That every font used is embedded: the 14 standard fonts are not, so a
# document that quietly falls back to Helvetica - a table style, a forgotten
# -family - is not archivable, and nothing on the way to the recipient says
# so. And that every colour space used fits the output intent (6.2.4.3):
# DeviceRGB needs an RGB intent, DeviceCMYK a CMYK one, and a single {cmyk 0
# 1 1 0} under the shipped sRGB profile - or a steelblue under a CMYK press
# profile - fails validation at the recipient, where nobody can tell any more
# which call painted it. This is the same reasoning as refusing a character
# the font has no glyph for: the writer is the only place in the chain that
# still knows what was meant.
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

  # The sRGB profile that ships with the package, found relative to this file
  # so it is still found after "make install". It is the default for -profile:
  # this writer paints with DeviceRGB operators, and ISO 19005-2, 6.2.4.3
  # makes the output intent mandatory for those - so a document without a
  # profile is not archivable, and until 2026-08-15 [pdfa] wrote exactly that
  # and let the recipient's validator say so. zugferd.tcl uses the same path.
  variable icc [file join [file dirname [file normalize [info script]]] \
      icc sRGB.icc]
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
      set current [dict create part 3 conformance B \
          profile $::tclpdf::pdfa::icc identifier {} extensions {} registered 0]
    }
    # Parsed over the four PUBLIC keys only. The whole state dict used to be
    # the parse defaults, which made "-registered 1" and "-extensions" valid
    # options and named them in the message for a misspelled one - and
    # "-registered 1" on a fresh document then claimed conformance without
    # ever subscribing to the write, so no output intent and no packet.
    set current [dict merge $current [::tclpdf::option parse \
        [dict filter $current key part conformance profile identifier] \
        $args "pdfa"]]

    # Everything below up to the version calls is a CHECK and changes
    # nothing: a refused call has to leave the document as it was. It used
    # not to - "pdfa -conformance Z" had already raised the version to 1.7
    # and pinned the floor and the ceiling to PDF/A-3 before the conformance
    # was looked at, and the next "configure -version 2.0" was refused for a
    # claim that no state held.
    #
    # Said here, at the call, rather than at write time from inside a failed
    # [read]. The shipped profile is part of the installation, so its absence
    # is a broken installation and is named as one - it used to be degraded
    # to "no output intent" without a word.
    set profile [dict get $current profile]
    if {![file exists $profile]} {
      if {$profile eq $::tclpdf::pdfa::icc} {
        return -code error "tclpdf: the sRGB profile shipped with the package\
            is missing at $profile - the installation is incomplete"
      }
      return -code error "tclpdf: the ICC profile \"$profile\" does not exist"
    }
    # Stored NORMALIZED, so that the shipped profile is recognised however
    # its path was spelled: "-profile icc/sRGB.icc" from the package
    # directory used to be compared as a string against the absolute path,
    # miss, and go out under the desc tag's bare "sRGB" instead of the
    # "sRGB IEC61966-2.1" every other document carries.
    dict set current profile [file normalize $profile]
    # And read once here, for what the output intent needs of it: a real
    # ICC profile ("acsp" at offset 36) describing a device space. The
    # manual says a Lab or XYZ profile is refused at the call; it used to be
    # refused at the write, out of PdfaProfile.
    ::tclpdf::pdfa space [::tclpdf::io read $profile] $profile
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
    # Part 2 admits an embedded file only when that file is itself PDF/A
    # (ISO 19005-2, 6.8) - which no attachment this package writes is
    # checked to be, and veraPDF's 2b profile fails a file with any other.
    # Part 3 was made for exactly that case. The mirror check sits in
    # attach.tcl for an attachment that arrives after the claim.
    if {[dict get $current part] == 2 && [llength [my state attachments]]} {
      return -code error "tclpdf: PDF/A-2 admits no embedded file that is\
          not itself PDF/A (ISO 19005-2, 6.8), and this document carries\
          [llength [my state attachments]] attachment(s) - use part 3, which\
          admits any file"
    }
    # The mirror image of the check in ua.tcl: parts 2 and 3 are PDF 1.7
    # formats (ISO 19005-2/-3 build on ISO 32000-1), and PDF/UA-2 - or a
    # caller's [configure -version 2.0] - commits the file to 2.0. Said at
    # the call that creates the contradiction, whichever way round the two
    # were declared. Checked BEFORE the raise below, which only ever lifts to
    # 1.7 - so a 2.0 seen here always came from the caller, never from pdfa
    # itself.
    if {[my state ua] ne {} && [dict get [my state ua] part] == 2} {
      return -code error "tclpdf: PDF/A-[dict get $current part] is a PDF 1.7\
          format and PDF/UA-2 needs PDF 2.0 - the two cannot be claimed by\
          one file. Use ua 1 with pdfa -part 3, which is the combination\
          ZUGFeRD needs"
    }
    if {[package vcompare [[my writer] version] 2.0] >= 0} {
      return -code error "tclpdf: PDF/A-[dict get $current part] is a PDF 1.7\
          format and this document is set to PDF [[my writer] version] -\
          leave the version alone, pdfa raises it to 1.7 by itself"
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
        return -code error "tclpdf: PDF/A conformance must be B, U or A, not\
            \"[dict get $current conformance]\""
      }
    }
    dict set current conformance $level

    # From here on the document changes. The declared part decides the
    # minimum file version, rather than the two being set independently and
    # contradicting each other. Measured: a document with "%PDF-1.4" in the
    # header and pdfaid:part 3 in the XMP passes veraPDF without a word - two
    # claims, one file, nobody objects. Through [configure], so that [cget
    # -version] answers what the header says; and recorded with the writer
    # both ways, so that a later [configure -version 1.4] OR [configure
    # -version 2.0] is refused naming PDF/A rather than writing that very
    # file. The ceiling is not decoration: measured, "pdfa -part 3" then
    # "configure -version 2.0" produced %PDF-2.0 with pdfaid:part 3, and
    # veraPDF -f 3b failed it on ISO 19005-3 6.1.2-1 alone (the header shall
    # be %PDF-1.n, n 0 to 7) - the same for part 2 under 19005-2.
    if {[package vcompare [[my writer] version] 1.7] < 0} {
      my configure -version 1.7
    }
    my RequireVersion 1.7 "PDF/A-[dict get $current part]"
    my LimitVersion 1.7 "PDF/A-[dict get $current part]"
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
    # After a [pdfa] call, never instead of one: this used to call [pdfa]
    # itself when nothing had been declared, and a document that only meant
    # to add a schema came out claiming PDF/A-3B - a claim its fonts and
    # colours had never been held to.
    if {[my state pdfa] eq {}} {
      return -code error "tclpdf: pdfa extension needs a PDF/A declaration to\
          add to - call pdfa first"
    }
    set current [my state pdfa]
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
    lassign [my PdfaProfile] bytes space components
    # Both numbers survive rebuilds - PdfaWrite runs on every write, and a
    # fresh pair per run would embed the ICC profile anew each time.
    set number [my streamObject [list N $components] $bytes \
        [my reservation pdfa.icc]]
    # The condition identifier names the profile, and the profile knows its
    # own name: the desc tag. It used to be a fixed "sRGB IEC61966-2.1"
    # whatever file was passed, so a GRAY or CMYK intent went out labelled as
    # sRGB. An explicit -identifier still wins; a profile without a readable
    # description is named after its file.
    #
    # The shipped profile is the one exception: its desc tag says only "sRGB",
    # while the colour space it implements is IEC 61966-2-1, and that is the
    # name every document written before the desc tag was read carried. Kept
    # so that the same script keeps producing the same bytes across releases.
    set identifier [dict get $current identifier]
    if {$identifier eq {} && [dict get $current profile] eq $::tclpdf::pdfa::icc} {
      set identifier "sRGB IEC61966-2.1"
    }
    if {$identifier eq {}} {
      set identifier [::tclpdf::pdfa description $bytes]
    }
    if {$identifier eq {}} {
      set identifier [file rootname [file tail [dict get $current profile]]]
    }
    set intent [my reservation pdfa.intent]
    [my writer] put $intent [::tclpdf::pdfObj dictionary [list \
        Type /OutputIntent \
        S /GTS_PDFA1 \
        OutputConditionIdentifier [::tclpdf::pdfObj str $identifier] \
        Info [::tclpdf::pdfObj str $identifier] \
        DestOutputProfile [[my writer] ref $number]]]
    my catalogEntry OutputIntents [::tclpdf::pdfObj arr \
        [list [[my writer] ref $intent]]]
    return
  }

  # The declared profile, read: its bytes, the device space it describes -
  # GRAY, RGB or CMYK - and the component count that space has. The space is
  # at offset 16 of the ICC header as a four-character signature. Lab and XYZ
  # profiles exist and are valid ICC, but an output intent wants a device
  # space - an unknown signature is reported with its name rather than
  # falling over inside a dict lookup.
  #
  # Two readers: PdfaWrite embeds the bytes and needs N; PdfaCheckColour
  # holds the space against the colours used. One reading, so the two cannot
  # disagree about what the intent is.
  method PdfaProfile {} {
    set profile [dict get [my state pdfa] profile]
    set bytes [::tclpdf::io read $profile]
    return [list $bytes {*}[::tclpdf::pdfa space $bytes $profile]]
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

  # Every device colour space used has to fit the output intent (ISO 19005-2,
  # 6.2.4.3, the same words in 19005-3): DeviceGray under any intent,
  # DeviceRGB only under an RGB one, DeviceCMYK only under a CMYK one - and
  # veraPDF applies that to a picture's colour space, an Indexed base, a
  # shading and a separation's alternate (6.2.4.4) exactly as to a fill.
  # Measured 2026-08-17 with veraPDF 1.30.2 over every one of those roads
  # under both the shipped sRGB profile and a CMYK press profile: each fails
  # 6.2.4.3-2 or -3 under the wrong intent, each passes under the right one.
  #
  # The facts come from [colourSpacesUsed] in color.tcl, fed by every module
  # that paints; judged here. All offending spaces in one message, like the
  # fonts, and each with the calls that used it - a refusal that says "a
  # colour somewhere" sends the caller reading every line of the script.
  #
  # The alternative would be to write /DefaultRGB and /DefaultCMYK colour
  # space resources, which the clause also admits. That would let a caller
  # mix spaces under one intent, at the price of an ICC-based space per page
  # resource dictionary that the caller never asked for and this writer does
  # not otherwise produce - so it is a refusal with the fix named, not a
  # silent conversion.
  method PdfaCheckColour {} {
    set used [my colourSpacesUsed]
    if {$used eq {}} {
      return
    }
    lassign [my PdfaProfile] - intent
    set offending {}
    foreach {space needs} {DeviceRGB RGB DeviceCMYK CMYK} {
      if {$intent ne $needs && [dict exists $used $space]} {
        lappend offending $space
      }
    }
    if {![llength $offending]} {
      return
    }
    set users [lmap space $offending {
      set by [join [dict get $used $space users] {, }]
      if {[dict get $used $space more]} {
        append by " and elsewhere"
      }
      # The space is named again only when two are listed - "used by rect
      # on page 1" reads better than "used DeviceCMYK by rect on page 1".
      expr {[llength $offending] > 1 ? "$space by $by" : "by $by"}
    }]
    # Under a GRAY intent both spaces can offend at once; the hint names the
    # profile that would admit what was painted, and the space the intent
    # does admit.
    set paint [dict get {GRAY grey RGB {RGB or grey} CMYK {CMYK or grey}} $intent]
    set profile [dict get {DeviceRGB {an RGB profile} DeviceCMYK {a CMYK profile}
        {DeviceRGB DeviceCMYK} {an RGB or CMYK profile}} $offending]
    return -code error "tclpdf: PDF/A with the $intent output intent\
        \"[file tail [dict get [my state pdfa] profile]]\" cannot carry\
        [join $offending { or }] (ISO 19005-2, 6.2.4.3) - used\
        [join $users {; }]; paint in $paint, or give $profile with pdfa\
        -profile"
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
    #
    # The colour check sits here for the same reason with one more: the
    # record it reads is filled while drawing, and [pdfa] may be declared
    # before or after the drawing - at catalog time both orders look alike.
    my PdfaCheckFonts
    my PdfaCheckColour
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

# The device space an ICC profile describes and the component count that
# space has - {RGB 3}, {GRAY 1}, {CMYK 4} - read from the header: the
# profile file signature "acsp" at offset 36 (ICC.1, 7.2.9) says it is a
# profile at all, and the four-character data colour space at offset 16
# (7.2.6) says which. Lab and XYZ profiles exist and are valid ICC, but an
# output intent wants a device space; either is reported by name rather
# than falling over inside a dict lookup. Called at the [pdfa] call, so a
# wrong profile is refused where it was named, and again from PdfaProfile
# at write time - one reading, so the two cannot disagree about the intent.
proc ::tclpdf::pdfa::space {bytes profile} {
  if {[string range $bytes 36 39] ne "acsp"} {
    return -code error "tclpdf: \"$profile\" is not an ICC profile - the\
        signature \"acsp\" is missing from its header"
  }
  set space [string trimright [string range $bytes 16 19]]
  set spaces {GRAY 1 RGB 3 CMYK 4}
  if {![dict exists $spaces $space]} {
    return -code error "tclpdf: the ICC profile \"$profile\" describes\
        colour space \"$space\" - the output intent supports GRAY, RGB and\
        CMYK"
  }
  return [list $space [dict get $spaces $space]]
}

# The description an ICC profile carries about itself - the desc tag - or an
# empty string when there is none that can be read.
#
# Only as much of ICC.1 as this needs: the tag table starts at byte 128 with
# a count, then twelve bytes per entry - signature, offset, size, all
# big-endian. A version 2 desc tag is of type 'desc' and carries a length and
# an ASCII string (ICC.1:2001-04, 6.5.17); a version 4 one is of type 'mluc',
# a table of language records with UTF-16BE text (ICC.1:2010, 10.13). Of the
# records the en-US one is taken where present, the first otherwise. Every
# offset is checked against the bytes at hand rather than trusted: a
# truncated or lying profile gives an empty answer, not a scan error.
proc ::tclpdf::pdfa::description {bytes} {
  if {[binary scan $bytes @128Iu count] != 1} {
    return {}
  }
  for {set i 0} {$i < $count} {incr i} {
    if {[binary scan $bytes @[expr {132 + 12 * $i}]a4IuIu sig offset size] != 3} {
      return {}
    }
    if {$sig ne "desc"} {
      continue
    }
    if {$size < 12 || $offset + $size > [string length $bytes]} {
      return {}
    }
    set tag [string range $bytes $offset [expr {$offset + $size - 1}]]
    switch -- [string range $tag 0 3] {
      desc {
        binary scan $tag @8Iu length
        # The length counts the terminating NUL; a profile that miscounts
        # is trimmed rather than believed.
        return [string trimright \
            [string range $tag 12 [expr {12 + $length - 1}]] "\0"]
      }
      mluc {
        binary scan $tag @8IuIu records recordSize
        set chosen {}
        for {set r 0} {$r < $records} {incr r} {
          if {[binary scan $tag @[expr {16 + $recordSize * $r}]a2a2IuIu \
              language country length start] != 4} {
            break
          }
          if {$chosen eq {} || ($language eq "en" && $country eq "US")} {
            set chosen [list $start $length]
          }
        }
        if {$chosen eq {}} {
          return {}
        }
        lassign $chosen start length
        if {$start + $length > $size} {
          return {}
        }
        binary scan $tag @${start}Su[expr {$length / 2}] units
        return [string trimright [join [lmap unit $units {format %c $unit}] {}] "\0"]
      }
    }
    return {}
  }
  return {}
}

package provide tclpdf::pdfa 1.6
