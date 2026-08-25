#
# tclpdf - PDF generation for Tcl
#
# font - embedding TrueType faces (9.7)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The public face of the font topic. sfnt.tcl reads the file, subset.tcl
# reduces it, and this module turns the result into PDF objects. Nothing
# outside loads those two.
#
#   $doc font embed hausschrift examples/assets/fonts/DejaVuSans.ttf
#   $doc font -family hausschrift -size 11
#   $doc text "Rechnung 1.234,56 EUR" -at {20 30}
#
# Why Type0/Identity-H and not a simple TrueType font: a simple font addresses
# 256 codes through an encoding, and every document needing more than that -
# a Greek quotation, a Polish name, a currency symbol outside WinAnsi - has to
# juggle encodings. Identity-H addresses glyphs directly with two bytes, so
# the question never arises. Measured in the corpus: 51.9 % of the documents
# use it.
#
# The price is /ToUnicode. With Identity-H the text in the file consists of
# glyph numbers, which mean nothing outside this one font - without a ToUnicode
# CMap the text can be neither copied nor searched, and nothing reports that
# either. It is written unconditionally.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::sfnt 1.0-
package require tclpdf::subset 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::font {}

# The GSUB feature that gives a face its VERTICAL glyph forms.
#
# A bracket, a comma, a full stop and a long vowel mark are not the same
# shapes in a vertical line as in a horizontal one - the bracket turns on its
# side, the comma and the full stop move from the bottom left of their square
# to the top right. The face carries both sets and names the second one in a
# GSUB feature, so this is a lookup, not a rotation: drawing the horizontal
# glyph turned by ninety degrees gives a bracket that leans the wrong way and
# a comma in mid-air.
#
# WHICH FEATURE. Two tags exist for it, and the OpenType specification says
# vrt2 should be preferred where a face has both. MEASURED IN NOTO SANS JP,
# that is the poorer of the two: vert holds 383 substitution rules and vrt2
# holds 378, the 378 are the same rules with the same outputs, and the five
# only vert has include U+FF1A, the fullwidth colon. So vert is asked first
# here and vrt2 is the fallback for a face that has no vert - which inverts
# the specification's preference on the evidence of the one face this package
# can measure, and is written down here so that the next face measured can
# overturn it.
#
# It is a plain single substitution - lookup type 1, which gsubApply has done
# since the ligatures - so this proc holds no substitution machinery of its
# own: it selects the feature and hands the prepared lookups back.
#
# THE SCRIPTS ARE NAMED, and this is the one decision here that this tree
# cannot check. The default of [otLayout langSys] is {latn DFLT}, and a
# vertical line is set in kana or hani - but Noto Sans JP registers vert under
# all six of its scripts (measured: DFLT, cyrl, grek, hani, kana, latn), so
# asking under latn finds it too. A mutation that drops the script list
# therefore passes every test in this suite. It stays because a face that
# registers vert only under kana would be silently unshaped without it, and
# the note stays because the next reader is entitled to know the line is
# reasoned rather than measured.
proc ::tclpdf::font::vertForms {parsed} {
  set gsub [::tclpdf::sfnt table $parsed GSUB]
  if {$gsub eq {}} {
    return {}
  }
  package require tclpdf::gsubApply 1.0-
  package require tclpdf::gdef 1.0-
  set gdef [::tclpdf::gdef build $parsed]
  foreach tag {vert vrt2} {
    set prepared [::tclpdf::gsubApply feature $gsub $tag $gdef \
        {kana hani DFLT} single]
    if {[llength $prepared]} {
      return $prepared
    }
  }
  return {}
}

oo::define ::tclpdf::document::document {

  # $doc font embed <alias> ?<path>? ?-data bytes? ?-subset 0?
  # $doc font names                 -> the embedded aliases
  # $doc font info <alias>          -> what the file says about itself
  #
  # Everything else goes to the text module - "font" without a subcommand is
  # the font state (-family, -size, ...).
  #
  # THE PATH IS OPTIONAL, and -data replaces it: the face that never was a
  # file - one out of a database, one out of an archive, one fetched over the
  # network - had to be written to a temporary file first, and the caller then
  # had to remember to remove it. [image embed] and [colorFont] have taken
  # their input this way for a while; this is the same shape down to the
  # parity test, so that one habit serves all three.
  method FontEmbed {alias args} {
    # The name stays first and positional, as it was. What may follow it is a
    # path, and a path is what is left over when the options have been paired
    # off - an ODD number of remaining words. The same rule [image embed]
    # uses, and it is the only one that can tell "-data" the option from a
    # file that happens to be called that.
    set path {}
    if {[llength $args] % 2} {
      set path [lindex $args 0]
      set args [lrange $args 1 end]
    }
    set options [::tclpdf::option parse \
        {subset 1 metrics {} axes {} instance {} data {}} $args "font embed"]
    set fonts [my state fonts]
    if {[dict exists $fonts $alias]} {
      return -code error "tclpdf: a font named \"$alias\" is already embedded"
    }
    # Validated HERE, at the call. -subset used to be taken as given and to
    # fail at write time, in an "if" nowhere near the line that set it.
    if {![string is boolean -strict [dict get $options subset]]} {
      return -code error "tclpdf: -subset takes a boolean, not\
          \"[dict get $options subset]\""
    }
    # The file says what it is; the extension does not. Read once and let both
    # parsers work on the same bytes rather than opening it twice - and with
    # -data there is no file at all, only the bytes, which is exactly what
    # every test below already worked on.
    if {$path ne {} && [dict get $options data] ne {}} {
      # BOTH, which names two font programs for one alias. Whichever of them
      # were taken, the other would be read by nobody and no message would
      # say so - and the two are not interchangeable: one is on disk and can
      # be looked at, the other is in the caller's hands. Refused rather than
      # ranked, in the same spirit as -metrics on a TrueType face three
      # paragraphs below.
      return -code error -errorcode [list TCLPDF FONT SOURCE $alias] \
          "tclpdf: font embed takes a file name or -data, not both -\
          \"$alias\" was given \"$path\" and\
          [string length [dict get $options data]] bytes besides; drop\
          whichever of the two is not the font program you mean"
    }
    if {$path ne {}} {
      set bytes [::tclpdf::io read $path]
    } elseif {[dict get $options data] ne {}} {
      set bytes [dict get $options data]
    } else {
      return -code error -errorcode [list TCLPDF FONT SOURCE $alias] \
          "tclpdf: font embed needs a file name or -data - \"$alias\" names\
          the font in the document, not the font program"
    }
    # What the refusals below call the face. A path can be named; bytes cannot,
    # so they are described instead - and every message from here on says
    # $source rather than reaching for a file name that may not exist.
    set source [my FontSource $path $bytes]
    # An embedded face is PDF 1.2 whatever its kind: the program goes in as
    # a FlateDecode stream (Reference 1.7, Table 3.5), and a TrueType face is
    # written as a Type 0 font with Identity-H and a ToUnicode CMap (5.6 and
    # Table 5.18, both PDF 1.2). Checked here, at the call, rather than at
    # write time when the caller cannot tell any more which line asked.
    my RequireVersion 1.2 "font embed"
    # Two options belong to one road each, and an option that has nothing to
    # act on is refused rather than ignored - the manual says so of -axes on
    # a face without an fvar table, and the same reasoning holds for the
    # kind of file: -metrics names an AFM, which only a Type 1 program has a
    # use for, and -axes or -instance ask a variable font for a point on its
    # axes, which a Type 1 program does not have. Silently taking either
    # would embed something other than what the call describes.
    if {[string index $bytes 0] eq "\x80" || [string range $bytes 0 1] eq "%!"} {
      if {[dict get $options axes] ne {} || [dict get $options instance] ne {}} {
        return -code error "tclpdf: $source is a Type 1 font\
            program, which has no axes - -axes and -instance apply to a\
            variable TrueType face"
      }
      dict set fonts $alias [my FontEmbedType1 $alias $path $bytes \
          [dict get $options metrics]]
    } elseif {[::tclpdf::sfnt isBareCff $bytes]} {
      # A CFF with no sfnt around it - see [FontEmbedCff]. Asked here, after
      # Type 1 and before the sfnt reader, because its signature is the
      # thinnest of the three: four bytes of which three say anything. An sfnt
      # cannot be mistaken for one (0x00010000, "OTTO", "true" and "ttcf" all
      # start with a byte a CFF header cannot have), and a Type 1 program is
      # already accounted for above.
      if {[dict get $options axes] ne {} || [dict get $options instance] ne {}} {
        return -code error "tclpdf: $source is a CFF font program, which has\
            no axes - -axes and -instance apply to a variable TrueType face"
      }
      if {[dict get $options metrics] ne {}} {
        return -code error "tclpdf: -metrics names the AFM of a Type 1 font\
            program - $source is a CFF font program and carries its own\
            metrics, widths and glyph names"
      }
      dict set fonts $alias [my FontEmbedCff $alias $path $source $bytes]
    } else {
      if {[dict get $options metrics] ne {}} {
        return -code error "tclpdf: -metrics names the AFM of a Type 1 font\
            program - $source is a TrueType or OpenType face and\
            carries its own metrics"
      }
      set parsed [::tclpdf::sfnt parse $bytes]
      # A CFF face goes in as FontFile3 with /Subtype /OpenType, which is
      # PDF 1.6 (Reference 1.7, Table 5.23).
      if {[dict get $parsed outlines] eq "cff"} {
        my RequireVersion 1.6 "font embed of a CFF (OpenType) face"
      }
      # A CFF face goes in whole as CIDFontType0 and its glyphs are addressed
      # by index through Identity-H. ISO 32000-1 9.7.4.2 lets that stand only
      # for a name-keyed program; in a CID-keyed one the CID goes through the
      # program's charset, and wherever that is not the identity a reader that
      # follows the standard draws another glyph than the one measured here -
      # silently, past every validator. Refused at embed time rather than
      # built: the tree holds no such face, and mapping through charset would
      # be a piece of its own.
      if {[dict get $parsed cidKeyed]} {
        return -code error \
            -errorcode [list TCLPDF FONT CIDKEYED $alias $path] \
            "tclpdf: $source is a CID-keyed CFF\
            font, which tclpdf cannot embed - its glyphs would be addressed by\
            CID, not by glyph index; convert it to TrueType or to a name-keyed\
            CFF"
      }
      # A face that draws nothing, refused here rather than embedded: the
      # file that comes out of it is valid, extractable and blank, and the
      # reasoning is at [FontDrawsNothing].
      if {[my FontDrawsNothing $parsed]} {
        return -code error \
            -errorcode [list TCLPDF FONT OUTLINES $alias $path] \
            "tclpdf: $source draws nothing - every character it\
            covers has an EMPTY outline. That is what a colour font looks\
            like from the outside: its pictures sit in a table of its own\
            (COLR/CPAL, CBDT, sbix, SVG) which this package does not write,\
            and a document embedding it would come out blank with nothing\
            reporting it. Embed a monochrome face instead - Noto Emoji for\
            Noto Color Emoji - or draw the symbols with \[font define\] and\
            \[font glyph\] as a Type 3 font"
      }
      lassign [my FontAxes $parsed $options $source] coordinates axes
      dict set fonts $alias [dict create \
          kind truetype \
          path $path parsed $parsed subset [dict get $options subset] \
          coordinates $coordinates axes $axes \
          used {} number {}]
    }
    my state fonts $fonts

    if {[my state fontHooked] eq {}} {
      my state fontHooked 1
      # On resources, not beforeWrite: the subset and the ToUnicode map are
      # built from the glyphs USED, and beforeWrite is when the other
      # subscribers still draw - pageNumbers writes its labels there. Hooked
      # to beforeWrite, this ran first (it was registered first, at embed
      # time), wrote the face without the label's glyphs, and a face used
      # by nothing but the page numbers had reserved its object and written
      # none - "object(s) reserved but never written". Measured on the
      # checked-in state; resources fires after every beforeWrite subscriber
      # and before the catalog checks that inspect the fonts.
      my onSelf resources FontWrite
    }
    return $alias
  }

  # Has this face an outline for anything a caller could write?
  #
  # A COLOUR FONT keeps its pictures in a table of its own - COLR/CPAL,
  # CBDT/CBLC, sbix or SVG - and leaves the glyf entry of every character it
  # covers EMPTY. This package writes outlines and none of those tables, so
  # such a face passes every gate there is and produces a blank page. Measured
  # on 2026-08-21 with NotoColorEmoji-Regular: [font embed], [text] and
  # [write] all reported success, pdftotext gave the code point back and
  # pdffonts showed a clean subset, and no tool [make check] runs said a word.
  # That is why this is a refusal at the embed and not a warning - a warning
  # is only useful to someone who already knows what to look for.
  #
  # THE TEST IS THE EMPTY OUTLINE, NOT THE COLOUR TABLE. A colour font that
  # carries real monochrome fallback outlines draws them, and refusing it for
  # its COLR table would take a working face away. A face with no colour
  # table at all whose outlines are all empty is just as blank and is refused
  # for the same one reason.
  #
  # THE QUESTION IS ASKED OF THE CHARACTERS, not of every glyph in the file.
  # The layer glyphs of a COLRv1 face DO have outlines - measured, 37831 of
  # its 41863 glyphs - and nothing a caller writes reaches one: text goes
  # through the cmap to a base glyph, and every one of those is empty
  # (measured: 1499 of 1499 characters).
  #
  # ONE empty outline says nothing, and must not: U+0020 has none in any face
  # measured (DejaVu Sans 61 of 5918 characters, Noto Emoji 43 of 1503, the
  # space among them in both). It takes ALL of them - and the walk stops at
  # the first outline it finds, which for an ordinary face is one of the
  # first characters it looks at.
  #
  # A CFF face is not asked. Its outlines live in the CFF table, which this
  # package never walks - see sfnt.tcl - so there is nothing to measure here.
  method FontDrawsNothing {parsed} {
    if {[dict get $parsed outlines] ne "truetype"} {
      return 0
    }
    set loca [dict get $parsed loca]
    set cmap [dict get $parsed cmap]
    if {![llength $loca] || ![dict size $cmap]} {
      # Nothing to compare, or a face whose characters this package cannot
      # reach at all - neither of those is this question.
      return 0
    }
    # loca holds numGlyphs + 1 offsets, so glyph n is empty where the offset
    # behind it does not lie behind its own (ISO/IEC 14496-22, 5.3.3). A
    # glyph number the table does not cover has no outline either.
    set last [expr {[llength $loca] - 1}]
    dict for {code glyph} $cmap {
      if {$glyph < $last && [lindex $loca [expr {$glyph + 1}]]
          > [lindex $loca $glyph]} {
        return 0
      }
    }
    return 1
  }

  # Where on the axes a variable font is to be embedded: a list of two - the
  # normalised coordinates in fvar order, and the axis values as the caller
  # gave them, {tag value ...} - or two empty lists, which means "leave the
  # outlines alone". The second is kept because the PostScript name of the
  # instance is derived from it (TN 5902): a reader is told Roboto-Bold or
  # Roboto_620wght, not Roboto-Regular for every weight.
  #
  # BOTH SPELLINGS EXIST because they answer different questions. -instance
  # "Bold" asks for a point the designer named and stood behind; -axes
  # {wght 620} asks for one nobody has looked at, which is the whole reason a
  # variable font is variable. Named instances are resolved to axis values
  # first, so from there on there is one path.
  #
  # PDF HAS NOWHERE TO PUT AN AXIS VALUE - not in the font dictionary, not in
  # the descriptor. The outlines are therefore computed here and embedded as a
  # fixed instance; a reader never learns that the face could vary.
  method FontAxes {parsed options source} {
    set axes [dict get $options axes]
    set instance [dict get $options instance]
    if {$axes eq {} && $instance eq {}} {
      return {{} {}}
    }
    package require tclpdf::varFont 1.0-
    if {![::tclpdf::varFont isVariable $parsed]} {
      return -code error "tclpdf: $source is not a variable font\
          - it has no fvar table, so -axes and -instance have nothing to set"
    }
    if {$instance ne {}} {
      set found [my FontInstance $parsed $instance $source]
      # An explicit -axes wins over the named instance it starts from, so that
      # "Bold, but a little narrower" is one call rather than a lookup by hand.
      set axes [dict merge $found $axes]
    }
    set known {}
    set ranges {}
    foreach axis [::tclpdf::varFont axes $parsed] {
      lappend known [lindex $axis 0]
      dict set ranges [lindex $axis 0] [lrange $axis 1 3]
    }
    dict for {tag value} $axes {
      if {$tag ni $known} {
        return -code error "tclpdf: $source has no axis \"$tag\"\
            - it has: [join $known { }]"
      }
      if {![string is double -strict $value]} {
        return -code error "tclpdf: the value for axis \"$tag\" must be a\
            number, got \"$value\""
      }
      # Inside the axis, or refused. The normalisation clamps (varFont
      # normalise, as the format prescribes), so the OUTLINES of wght 5000
      # were those of 900 - but the value itself went on into the PostScript
      # name and the descriptor: measured, Roboto_5000wght with a StemV of
      # 5967, a font that does not exist named as if it did. Refused here,
      # before anything downstream sees the number, and with the range so
      # that the caller can pick a point that is on the axis.
      lassign [dict get $ranges $tag] minimum default maximum
      if {$value < $minimum || $value > $maximum} {
        return -code error "tclpdf: the value $value for axis \"$tag\" is\
            outside its range in $source - $tag runs from\
            [::tclpdf::pdfObj num $minimum] to [::tclpdf::pdfObj num $maximum]\
            (default [::tclpdf::pdfObj num $default])"
      }
    }
    return [list [::tclpdf::varFont coordinates $parsed $axes] $axes]
  }

  # The instanced glyphs of a variable font, computed once and kept.
  #
  # ONE SOURCE, because the alternative was measured and it is a defect: the
  # instancing used to happen in the subsetter, at write time, while textWidth
  # went on reading the advances of the file. So three weights out of one file
  # measured the same and drew differently - the line breaker, the table
  # columns and the /W array of the PDF all saw the default. That is the same
  # shape of error as measuring a -spacing that is never drawn.
  #
  # Whole face at once rather than per glyph: measured at 67 ms for Roboto's
  # 1326 glyphs, and a cache that fills as it goes would have to be written
  # back into the document state on every miss.
  method FontInstanced {alias} {
    set fonts [my state fonts]
    set entry [dict get $fonts $alias]
    if {[dict exists $entry instanced]} {
      return [dict get $entry instanced]
    }
    set coordinates [dict get $entry coordinates]
    if {![llength $coordinates]} {
      return {}
    }
    package require tclpdf::varFont 1.0-
    set instanced [::tclpdf::varFont all [dict get $entry parsed] $coordinates]
    dict set fonts $alias instanced $instanced
    my state fonts $fonts
    return $instanced
  }

  # The advance of one glyph, in font units - from the instance where there is
  # one. Everything that measures goes through here.
  method FontAdvance {alias parsed glyph} {
    set instanced [my FontInstanced $alias]
    if {[dict exists $instanced $glyph]} {
      return [dict get $instanced $glyph advance]
    }
    return [::tclpdf::sfnt advance $parsed $glyph]
  }

  # A named instance, by the name the font gives it. The lookup is over the
  # name table, so it is the name a font menu would show.
  method FontInstance {parsed wanted source} {
    set names {}
    foreach entry [::tclpdf::varFont instances $parsed] {
      lassign $entry nameId coordinates
      set name [::tclpdf::sfnt name $parsed $nameId]
      if {$name eq {}} {
        continue
      }
      lappend names $name
      if {[string equal -nocase $name $wanted]} {
        return $coordinates
      }
    }
    return -code error "tclpdf: $source has no instance named\
        \"$wanted\" - it has: [join $names {, }]"
  }

  # A Type 1 program plus the metrics beside it.
  #
  # The metrics are a SEPARATE FILE and there is no way around it: the widths
  # of a Type 1 face live in its charstrings, behind the eexec encryption, and
  # reading them would be the subsetting work this way exists to avoid. So the
  # AFM is looked for next to the program under the same base name, and
  # -metrics names it where it sits elsewhere.
  #
  # The AFM says which glyphs the face HAS, and it is not always right: Adobe's
  # Helvetica.afm lists Euro, Helvetica.pfb carries no such charstring. Read
  # by the AFM alone, the byte was set and the reader drew a blank - the one
  # thing the missing-glyph rule exists to prevent. So the program's own glyph
  # names are read (type1 glyphs) and a position is mapped only where both
  # agree; a character the program lacks is refused, as it is for TrueType.
  method FontEmbedType1 {alias path bytes metricsPath} {
    package require tclpdf::type1 1.0-
    set program [::tclpdf::type1 parse $bytes]
    if {$metricsPath eq {}} {
      if {$path eq {}} {
        # -data and no -metrics: there is no file to look beside. Said here
        # rather than letting the lookup below report that "".afm" is not
        # readable, which names a file nobody asked for.
        return -code error -errorcode [list TCLPDF FONT METRICS $alias] \
            "tclpdf: a Type 1 font needs its metrics, and a font passed with\
            -data has no file to look beside - name the AFM with -metrics"
      }
      set metricsPath [file rootname $path].afm
    }
    if {![file readable $metricsPath]} {
      return -code error "tclpdf: a Type 1 font needs its metrics -\
          \"$metricsPath\" is not readable. Put the AFM beside the font or\
          name it with -metrics"
    }
    set metrics [::tclpdf::type1 metrics $metricsPath]
    set glyphs [::tclpdf::type1 glyphs $program]
    return [dict create \
        kind type1 \
        path $path metricsPath $metricsPath \
        program $program metrics $metrics \
        widths [::tclpdf::type1 widths $metrics $glyphs] \
        names [::tclpdf::type1 names $metrics $glyphs] \
        subset 0 used {} number {}]
  }

  # What a refusal calls the face it is refusing.
  #
  # A file can be named and a caller can go and look at it. Bytes cannot: with
  # -data there IS no name, and "" is not readable" is a message about a file
  # nobody asked for. So the bytes describe themselves instead - by their
  # length, which is the one thing a caller can compare against what he passed
  # in. [image embed] answers the same question the same way.
  method FontSource {path bytes} {
    if {$path ne {}} {
      return "\"[file tail $path]\""
    }
    return "the font data passed with -data ([string length $bytes] bytes)"
  }

  # A BARE CFF - the same outlines a .otf carries, without the sfnt around
  # them.
  #
  # WHAT IS MISSING, and it is nearly everything a .otf answers with: no cmap,
  # so no character reaches a glyph; no hmtx, so no glyph has a width; no
  # name, so the face has no PostScript name; no head, so the em has no size;
  # no OS/2, so there is no embedding permission and no cap height. What is
  # left is the CFF, and every one of those answers is inside it - in the Name
  # INDEX, the Top DICT, the charset, the Encoding, the Private DICT and the
  # charstrings themselves. sfnt.tcl reads them; this method turns the result
  # into the entry the rest of the package works with.
  #
  # IT IS THE TYPE 1 ROAD, and that is a decision rather than a convenience.
  # A bare CFF goes into a PDF as /FontFile3 with /Subtype /Type1C - "Type
  # 1-equivalent font program" (ISO 32000-1, Table 126), which is an entry of
  # a SIMPLE font descriptor: one byte per character, addressed through an
  # encoding, exactly as the .pfb road works. So the entry it builds is a
  # type1 entry, down to the shape of its metrics dictionary, and everything
  # that asks what kind a face is - the text module, the annotation module,
  # [FontAscender] - is answered without knowing this format exists. The one
  # thing that differs is the bytes and the descriptor key, which is where the
  # two roads fork again, in [FontWriteType1].
  #
  # WHAT IT COSTS, said plainly because a caller has to know it before he
  # chooses this format: a bare CFF is addressed through WinAnsiEncoding and
  # reaches 224 byte positions, where the same outlines inside a .otf are
  # addressed by glyph number through Identity-H and reach every character the
  # face has a cmap entry for. The face has the glyphs either way; what the
  # bare file has lost is the table that says which character they belong to.
  # Where the .otf exists, embed the .otf.
  #
  # THE WIDTHS ARE SCALED HERE, once. A Type 1 font's widths are in
  # thousandths of an em by definition, and a CFF may be drawn on any grid its
  # FontMatrix declares - measured on this machine, 32 of 33 CFF faces are on
  # 1000 and FontAwesome is on 1792. Scaling at the point where the file is
  # read means nothing downstream has to know.
  method FontEmbedCff {alias path source bytes} {
    package require tclpdf::type1 1.0-
    set program [::tclpdf::sfnt cffFont $bytes]
    # The same refusal the .otf road makes, for the same reason: a CID-keyed
    # program addresses its glyphs by CID through its own charset, and this
    # package addresses them by name.
    if {[dict get $program cidKeyed]} {
      return -code error -errorcode [list TCLPDF FONT CIDKEYED $alias $path] \
          "tclpdf: $source is a CID-keyed CFF font program, which tclpdf\
          cannot embed - its glyphs carry CIDs rather than names, and a Type\
          1-equivalent font is addressed by name; convert it to a name-keyed\
          CFF or embed the TrueType cut of the face"
    }
    set units [dict get $program unitsPerEm]
    set scale [expr {1000.0 / $units}]
    set widths {}
    dict for {name width} [dict get $program widths] {
      dict set widths $name [expr {round($width * $scale)}]
    }
    # The metrics an AFM would have carried, filled from the font program
    # instead - same keys, same units, so that everything reading them stays
    # as it is. The four that are EMPTY are empty on purpose: a CFF states no
    # ascender, no descender, no cap height and no x height, and the readers
    # of this dictionary already fall back to the bounding box where a Type 1
    # face states none either. Writing a guess in here would put a number in
    # [font info] that the file never said.
    set metrics [dict create \
        name [dict get $program name] \
        family [dict get $program family] \
        bbox [lmap number [dict get $program bbox] {
          expr {round($number * $scale)}
        }] \
        italicAngle [dict get $program italicAngle] \
        ascender {} descender {} capHeight {} xHeight {} \
        stemV [dict get $program stemV] \
        widths $widths \
        codes [dict get $program encoding] \
        fixedPitch [dict get $program fixedPitch]]
    # WinAnsi position -> the name this face carries for it. The same call the
    # .pfb road makes, over the same kind of table: [type1 names] takes each
    # position's candidate names in order and keeps the first the face has.
    # The charset is what "has" means here, and the widths dictionary is keyed
    # by exactly the charset names, so no second list is needed.
    set names [::tclpdf::type1 names $metrics]
    if {![dict size $names]} {
      # A face NONE of whose glyphs is called by a WinAnsi name: every byte
      # position would be unwritable and the face could set no text at all.
      # Refused here rather than at the first [text], which would name a
      # character instead of the cause.
      #
      # A symbol face is not automatically this case, and the two URW symbol
      # faces are the measurement that says so: StandardSymbolsPS reaches 44
      # WinAnsi positions of its 191 glyphs and D050000L reaches 2 of its 203
      # - the digits, the ASCII punctuation and the space are called what
      # WinAnsi calls them whatever else the face holds. Two is next to
      # nothing and is still not none, so both are embedded rather than
      # refused. It takes a face whose every glyph carries a private name.
      return -code error -errorcode [list TCLPDF FONT ENCODING $alias $path] \
          "tclpdf: $source is a CFF font program whose\
          [dict size [dict get $program charset]] glyphs carry none of the\
          glyph names WinAnsiEncoding is built from, so not one byte position\
          could be written with it. A bare CFF is embedded as a Type\
          1-equivalent font and addressed through that encoding; a face whose\
          glyphs all carry private names has to come in as an OpenType (.otf)\
          face, which is addressed by glyph number instead"
    }
    return [dict create \
        kind type1 \
        path $path program {} cff $bytes \
        unitsPerEm $units \
        metrics $metrics \
        widths [::tclpdf::type1 widths $metrics] \
        names $names \
        subset 0 used {} number {}]
  }

  # Which of the two roads a face takes. Everything that has to tell them
  # apart asks here rather than testing for a key.
  method FontKind {alias} {
    return [dict get [my state fonts] $alias kind]
  }

  # The ascender of an embedded face at a given size, in points.
  #
  # Asked here rather than read out of the entry, because the two kinds keep
  # it in different places and different units: a TrueType face in hhea, in
  # its own units per em, a Type 1 face in the AFM beside it, already in
  # 1/1000 em. Whoever needs the number should not have to know which.
  method FontAscender {alias size} {
    set entry [dict get [my state fonts] $alias]
    if {[dict get $entry kind] eq "type1"} {
      # ZERO counts as absent, not as a measurement. The URW metrics in this
      # tree write "Ascender 0" and "Descender 0" - the fields are there and
      # say nothing. Read literally, every line anchored at its top sat one
      # full ascender too high, which in a table put the text on the rule
      # above it. A face has no zero ascender; the bounding box is measured
      # from the same outlines and is the honest substitute.
      set ascent [dict get $entry metrics ascender]
      if {$ascent eq {} || $ascent == 0} {
        set ascent [lindex [dict get $entry metrics bbox] 3]
      }
      return [expr {double($ascent) * $size / 1000.0}]
    }
    set parsed [dict get $entry parsed]
    return [expr {double([dict get $parsed ascender]) * $size
        / [dict get $parsed unitsPerEm]}]
  }

  # The descender of an embedded face, in points at the size asked for, as a
  # POSITIVE distance below the baseline.
  #
  # The twin of [FontAscender], and written on 2026-08-24 because it was
  # missing: annotMark.tcl carried the whole of it as a private method,
  # having said so in its own comment - "where a [FontDescender] is added
  # beside [FontAscender], this method becomes one line and should".
  #
  # Positive because that is the question callers ask - how far below the
  # baseline does the line reach - while the faces disagree on the sign: hhea
  # states it negative, an AFM may state either. Taking the absolute value
  # here is what keeps every caller from having to know that.
  #
  # ZERO counts as absent, not as a measurement, for the same reason it does
  # in [FontAscender]: the URW metrics in this tree write "Descender 0", the
  # field being there and saying nothing, and the bounding box is measured
  # from the same outlines and is the honest substitute.
  method FontDescender {alias size} {
    set entry [dict get [my state fonts] $alias]
    if {[dict get $entry kind] eq "type1"} {
      set descender [dict get $entry metrics descender]
      if {$descender eq {} || $descender == 0} {
        set descender [lindex [dict get $entry metrics bbox] 1]
      }
      return [expr {abs(double($descender)) * $size / 1000.0}]
    }
    set parsed [dict get $entry parsed]
    return [expr {abs(double([dict get $parsed descender])) * $size
        / [dict get $parsed unitsPerEm]}]
  }

  # A Type 1 face is addressed by single bytes through WinAnsiEncoding, so it
  # is encoded by the same code as the standard fourteen - only the widths
  # come from its own metrics. [afm encodeWidths] is that shared road; what
  # differs is which face the message names.
  method FontType1Encode {alias text} {
    return [::tclpdf::afm encodeWidths \
        [dict get [my state fonts] $alias widths] $text 0 \
        "the embedded Type 1 face \"$alias\"" \
        " - embed a TrueType face for this text" $alias]
  }

  method FontNames {} {
    return [dict keys [my state fonts]]
  }

  # What the file says about itself - including the embedding permission.
  #
  # EVERY KIND ANSWERS EVERY KEY, and that is the point of [FontInfoStated]
  # below: a caller who writes [dict get [$doc font info $a] capHeight] must
  # not have to find out first which format $a happens to be, and a key that
  # is present for a TrueType face and absent for a Type 1 one is a key that
  # will be read without a guard and crash on the second font. A format that
  # does not state a value answers the EMPTY STRING for it.
  #
  # "NOT STATED" IS NOT "ZERO", and it is not a computed substitute either.
  # The font descriptor has to write a cap height whatever the file says, and
  # it derives one where the file is silent (see [FontDescriptorPairs]: the
  # top of the H, or the ascender). This command must not report that number:
  # it answers what the FILE says, and a derived value reported as the file's
  # is how a caller comes to believe a face states something it does not.
  #
  # WHAT WAS DELIBERATELY LEFT OUT. The GSUB and GPOS feature tags were asked
  # for and are not here. A flat list of them would be the wrong answer to the
  # question it invites: features are registered PER SCRIPT and per language
  # system, and a face that lists "liga" may list it under latn alone - so
  # "the face has liga" is true of the file and false of the text at hand.
  # The honest form of that answer is a table, and a table is a piece of its
  # own rather than a key in a summary. What a caller actually wants to know -
  # will this text get its ligatures - the drawing already answers.
  method FontInfo {alias} {
    set fonts [my state fonts]
    if {![dict exists $fonts $alias]} {
      return -code error "tclpdf: no embedded font named \"$alias\""
    }
    set entry [dict get $fonts $alias]
    # A Type 3 font has no file to ask - its glyphs are content streams in
    # this very document - so the module that made it answers instead. The
    # keys it does not know are filled in around its answer rather than added
    # to it: type3.tcl owns what it says, and this owns the promise that the
    # whole set is there.
    if {[dict get $entry kind] eq "type3"} {
      return [dict merge [my FontInfoStated type3] [my Type3Info $alias]]
    }
    if {[dict get $entry kind] eq "type1"} {
      set metrics [dict get $entry metrics]
      set cff [dict exists $entry cff]
      # No fsType: neither a Type 1 program nor a bare CFF carries an
      # embedding permission at all. That is a property of the format, not
      # something unknown about this file, so it is reported as such rather
      # than guessed at.
      set format [expr {$cff ? {cff} : {type1}}]
      return [dict merge [my FontInfoStated $format] [dict create \
          family [dict get $metrics family] \
          postScript [dict get $metrics name] \
          glyphs [dict size [dict get $metrics widths]] \
          unitsPerEm [expr {[dict exists $entry unitsPerEm] ?
              [dict get $entry unitsPerEm] : 1000}] \
          fsType {} \
          permission [expr {$cff ?
              {not stated - a bare CFF has no fsType} :
              {not stated - Type 1 has no fsType}}] \
          ascender [my FontStated $metrics ascender] \
          descender [my FontStated $metrics descender] \
          capHeight [my FontStated $metrics capHeight] \
          xHeight [my FontStated $metrics xHeight] \
          characters [dict size [dict get $entry names]]]]
    }
    set parsed [dict get $entry parsed]
    set os2 [dict get $parsed os2]
    # postScript is the name the face is embedded under - for an instance of
    # a variable font the instance's name by TN 5902 (FontBaseName), not name
    # id 6, which names the file's default: measured, "-instance Bold"
    # answered Roboto-Regular while the file said Roboto-Bold.
    #
    # The three hhea numbers and the two OS/2 heights are in the FACE'S OWN
    # units, which is why unitsPerEm stands beside them: an ascender of 1901
    # means nothing until it is read against the 2048 of the same dictionary.
    # Converting them to thousandths here would have been the other choice and
    # was not taken - it would make [font info] disagree with the file it
    # claims to be quoting.
    # varFont is loaded to ASK, not only to answer: whether a face is variable
    # is one table lookup, and writing that lookup out here instead would be
    # the same sentence in two modules, free to disagree the day fvar stops
    # being the whole test. [font info] is not a hot path.
    package require tclpdf::varFont 1.0-
    set axes {}
    if {[::tclpdf::varFont isVariable $parsed]} {
      foreach axis [::tclpdf::varFont axes $parsed] {
        lappend axes [lrange $axis 0 3]
      }
    }
    # NOT through [expr]: a name that comes out of the FILE is a string, and
    # expr reads a numeric literal wherever it sees one. Measured on
    # DejaVu Sans with its name table patched to say "Infinity" - the family
    # came back as "Inf". "1e3" would come back as 1000.0 and "nan" would
    # raise "domain error"; sfnt.tcl reads the CFF's own names the same way,
    # and for the same reason.
    set family {}
    if {[dict exists [dict get $parsed names] family]} {
      set family [dict get $parsed names family]
    }
    return [dict merge [my FontInfoStated [dict get $parsed outlines]] \
        [dict create \
            family $family \
            postScript [my FontBaseName $entry $alias 0] \
            glyphs [dict get $parsed numGlyphs] \
            unitsPerEm [dict get $parsed unitsPerEm] \
            fsType [dict get $parsed fsType] \
            permission [::tclpdf::sfnt permission [dict get $parsed fsType]] \
            ascender [dict get $parsed ascender] \
            descender [dict get $parsed descender] \
            lineGap [dict get $parsed lineGap] \
            capHeight [dict get $os2 capHeight] \
            xHeight [dict get $os2 xHeight] \
            vertical [my FontHasVertical $alias] \
            variable [expr {[llength $axes] > 0}] \
            axes $axes \
            characters [dict size [dict get $parsed cmap]]]]
  }

  # The keys of [font info] that a format may leave unanswered, at their "not
  # stated" value - the frame every kind's answer is merged onto, so that the
  # SET of keys is the same whatever was embedded.
  method FontInfoStated {format} {
    return [dict create format $format ascender {} descender {} lineGap {} \
        capHeight {} xHeight {} vertical 0 variable 0 axes {}]
  }

  # One metric an AFM may carry - as the file states it, or {} where it does
  # not. ZERO counts as absent: the URW metrics in this tree write
  # "Ascender 0" and "Descender 0", which are fields that are there and say
  # nothing, and [FontAscender] has treated them that way since it was
  # written. A face has no zero ascender.
  method FontStated {metrics key} {
    if {![dict exists $metrics $key]} {
      return {}
    }
    set value [dict get $metrics $key]
    if {$value eq {} || $value == 0} {
      return {}
    }
    return $value
  }

  # A string as the glyphs that will be drawn for it.
  #
  # THE single place that turns characters into glyphs. Measuring, kerning and
  # encoding all go through it, because with ligatures they can no longer
  # agree by accident: three characters may become one glyph, and a width
  # counted per character would then disagree with what is drawn.
  #
  # The result is a list of entries {glyph codes}, where codes are the
  # character code points the glyph stands for - one for an ordinary glyph,
  # several for a ligature. That provenance is not decoration: it is what the
  # ToUnicode CMap is built from, and without it a ligature would extract as
  # one unknown character instead of "ffi".
  #
  # A character the font has no glyph for is an ERROR. This is the only place
  # in the chain that notices: the reader shows a blank, the validator says
  # nothing, and the recipient sees an invoice with a gap where the amount
  # should be.
  # The run is LOGICAL in both directions: -direction rtl is not handled here
  # but where the run is drawn, because ligatures and kerning are defined on
  # the logical order and reversing before them would look up the wrong pairs.
  # What the direction settles here is only whether a script that needs
  # nothing but the order may pass at all.
  method FontRun {alias text {ligatures 0} {unshaped 0} {direction ltr}} {
    # Refused BEFORE anything is looked up: a script that needs shaping would
    # otherwise come out as isolated glyphs in the wrong order, which looks
    # like text and is not. Same rule as the missing glyph below, and the same
    # reason - this is the only place in the chain that notices.
    #
    # A CURSIVE script is the one case that is not settled here alone: whether
    # Arabic can be set depends on the FACE, which shaping.tcl has never seen.
    # So the answer comes back as a question, the face is asked, and the walk
    # is repeated with the answer - the second walk being the one that can
    # still find a vowel sign further along the line, which needs mark
    # placement and is refused as it always was.
    set cursive {}
    if {!$unshaped} {
      package require tclpdf::shaping 1.0-
      set finding [::tclpdf::shaping needed $text $direction]
      if {[llength $finding] && [lindex $finding 4] eq "forms"
          && $direction eq "rtl"} {
        if {[my FontLayoutState $alias forms] eq {}} {
          return -code error [::tclpdf::shaping message $finding $alias]
        }
        # Noted, not kept: all that is still asked of the finding below is
        # that there WAS one, because the second walk ends at {} and the run
        # is no longer refused for the marks it carries.
        set cursive 1
        set finding [::tclpdf::shaping needed $text $direction 1]
      }
      if {[llength $finding]} {
        return -code error [::tclpdf::shaping message $finding]
      }
    }
    # Direction rather than script, and only a right-to-left line has either
    # question to ask - which is why the module is loaded here and not above:
    # a document that never sets one never pays for it.
    if {$direction eq "rtl"} {
      package require tclpdf::bidi 1.0-
      # The other half of the shaping rule. A character that runs LEFT TO
      # RIGHT in a right-to-left line - a Latin word, a Cyrillic name - needs
      # the bidi algorithm to decide where it goes, and this package does not
      # have it. Reversing the run around it produced "gnunhceR", and nothing
      # said so.
      #
      # Behind the same -unshaped gate as the shaping refusal, and for the
      # same reason: that option is the one place a caller says "I know what
      # this does, draw it anyway", and a second escape hatch beside it would
      # be one more thing to explain.
      if {!$unshaped} {
        set opposite [::tclpdf::bidi opposite $text $direction]
        if {[llength $opposite]} {
          return -code error [::tclpdf::bidi message $opposite]
        }
      }
    }
    set entry [dict get [my state fonts] $alias]
    set cmap [dict get $entry parsed cmap]
    set run {}
    set position 0
    foreach char [split $text {}] {
      set code [scan $char %c]
      # A soft hyphen is a permission, not a character: it says a word may be
      # broken here. The breaker has already put a real hyphen wherever it took
      # the offer, so from here on the mark itself has to vanish - it must not
      # reach a glyph, a width or the ToUnicode map. A face that HAS a glyph at
      # U+00AD would otherwise set a hyphen in the middle of an unbroken word,
      # which is how it looked before: "Silben-trennung", measured 4.33 pt
      # wider than the same word without the mark.
      # The zero width space U+200B is the same kind of thing: a break
      # opportunity the breaker has already used or dropped, with nothing to
      # draw. Most faces have no glyph for it and would refuse the string;
      # the few that do would carry an empty glyph into the file. Neither is
      # what anyone wrote it for. U+FEFF, the byte order mark that a file
      # read without stripping it carries in front of its first word, is the
      # third: ZERO WIDTH NO-BREAK SPACE, nothing to draw either - and it
      # used to be refused as an Arabic mark, because the presentation forms
      # block it closes was taken whole.
      if {$code == 0x00AD || $code == 0x200B || $code == 0xFEFF} {
        incr position
        continue
      }
      # A paired bracket is DRAWN mirrored in a right-to-left line: U+0028 is
      # the OPENING bracket, and the opening bracket of a line that runs the
      # other way looks like ")". Unicode calls this mirroring (UAX #9,
      # section 3.4) and it is a display property, not a different character.
      #
      # Done as a swap of the code point before the character map is asked,
      # which is what a shaper does when the face carries no rtlm feature -
      # measured, DejaVu Sans carries none, and HarfBuzz returns the mirrored
      # glyph for it all the same. The ToUnicode map therefore says what the
      # GLYPH is; what the CHARACTER was is written beside the glyph as an
      # ActualText span, in text.tcl, so that the line extracts as it was
      # given.
      set drawn $code
      if {$direction eq "rtl"} {
        set drawn [::tclpdf::bidi mirror $code]
      }
      # The MIRRORED code is the one named when it is missing: that is the
      # glyph the face would have to carry, and naming the one the caller
      # typed would send them looking at a character the face has.
      if {![dict exists $cmap $drawn]} {
        # Same -errorcode as the three refusals in [afm encodeWidths]; the
        # contract is described there and in the manual under "Error codes".
        set u U+[format %04X $drawn]
        return -code error \
            -errorcode [list TCLPDF FONT GLYPH $u $position $alias] \
            "tclpdf: the font \"$alias\" has no glyph for\
            $u (position $position) - it cannot be written\
            with this face"
      }
      lappend run [list [dict get $cmap $drawn] [list $drawn]]
      incr position
    }
    # The contextual forms come FIRST, and not by preference: they are the
    # shaping of the script, while ligatures are a typographic option the
    # caller switched on. A lam-alef that a required ligature makes out of two
    # joined shapes cannot be found before those shapes exist, and a standard
    # ligature that fired on the isolated letters would have hidden them.
    if {[llength $cursive]} {
      # A face that writes its letters as a skeleton plus separate dots comes
      # out of this LONGER than it went in, and the dots it added are placed
      # by GPOS mark attachment - [FontRunMarks] reads it and text.tcl draws
      # them where the anchors say. Until that existed such a run was refused
      # here, because a dot drawn at the pen position lands beside the letter
      # it belongs to instead of under it. Measured in NotoNaskhArabic on the
      # run U+0628 U+064E, which shapes to three glyphs: the dot belongs 464
      # units to the LEFT of where the pen leaves it and the fatha 506.
      set run [::tclpdf::forms apply [my FontLayoutState $alias forms] $run]
    }
    if {$ligatures && [llength $run] > 1} {
      set run [::tclpdf::liga apply [my FontLayoutState $alias liga] $run]
    }
    # LAST, after everything else has settled which glyphs there are: vert
    # substitutes the FINAL glyph of a position for its vertical form, and a
    # ligature or a cursive form applied afterwards would look for a glyph
    # that is no longer in the run. This is the order a shaper uses and the
    # reason it is the last line here rather than the first.
    if {$direction eq "ttb"} {
      set prepared [my FontLayoutState $alias vertForms \
          [list ::tclpdf::font::vertForms]]
      if {[llength $prepared]} {
        set run [::tclpdf::gsubApply apply $prepared $run]
      }
    }
    return $run
  }

  # -- vertical writing -----------------------------------------------------
  #
  # Has this face a metric for vertical writing of its own? A face that has
  # none is not refused - PDF defines a default for exactly that case - but
  # the answer is worth having, and [font info] reports it.
  method FontHasVertical {alias} {
    set entry [dict get [my state fonts] $alias]
    if {[dict get $entry kind] ne "truetype"} {
      return 0
    }
    return [::tclpdf::sfnt hasVertical [dict get $entry parsed]]
  }

  # The advance HEIGHT of one glyph, in font units - what the pen travels
  # downwards, and nothing hmtx knows about. Everything that measures a
  # vertical line goes through here, as everything horizontal goes through
  # [FontAdvance].
  #
  # THE FALLBACK IS THE STANDARD'S, not a guess: ISO 32000-2, 9.7.4.3 gives
  # /DW2 the default [880 -1000], so a glyph with no vertical metric advances
  # one em. A face without vmtx therefore sets a vertical line of square
  # cells, which is right for CJK and is the only defined answer for anything
  # else.
  method FontVerticalAdvance {alias parsed glyph} {
    set height [::tclpdf::sfnt verticalAdvance $parsed $glyph]
    if {$height eq {}} {
      return [dict get $parsed unitsPerEm]
    }
    return $height
  }

  # The y of the point a glyph HANGS FROM in vertical writing, in font units.
  #
  # The other half of the metric, and the half that is easy to forget: the
  # advance alone puts the glyphs at the right distance from one another and
  # the whole column at the wrong height, because a glyph is drawn from its
  # origin and its vertical origin is not its horizontal one. The default is
  # the standard's again - 880 thousandths of the em, /DW2's first number.
  method FontVerticalOrigin {alias parsed glyph} {
    set y [::tclpdf::sfnt verticalOriginY $parsed $glyph \
        [my FontGlyphYMax $alias $parsed $glyph]]
    if {$y eq {}} {
      return [expr {[dict get $parsed unitsPerEm] * 0.88}]
    }
    return $y
  }

  # The extent of a prepared run ALONG A VERTICAL LINE, in points - the
  # counterpart of [FontRunWidth], and what a vertical line is measured by.
  #
  # No kerning: the pairs in GPOS "kern" are horizontal, and adding a
  # horizontal correction to a vertical advance moves the glyphs by a number
  # that has nothing to do with the gap it is meant to close. A face that
  # carries vertical kerning names it "vkrn", which this package does not
  # read - said here rather than left to be discovered from a line that is
  # subtly the wrong length.
  method FontRunHeight {alias run size} {
    set parsed [dict get [my state fonts] $alias parsed]
    set total 0
    foreach item $run {
      set total [expr {$total + [my FontVerticalAdvance $alias $parsed \
          [lindex $item 0]]}]
    }
    return [expr {double($total) * $size / [dict get $parsed unitsPerEm]}]
  }

  # Two-byte glyph numbers for a run, recording which glyphs were used and
  # what each of them stands for.
  #
  # One glyph can be reached in more than one way, and a ToUnicode CMap has
  # room for only one destination per CID. In DejaVu Sans glyph 5044 is both
  # the GSUB output of "ffi" and the cmap entry for U+FB03, the precomposed
  # ligature character. Whichever was written last used to win, so a document
  # that drew "office" before it drew U+FB03 extracted the word as
  # o U+FB03 c e - rendering perfectly, validating cleanly, and no longer
  # findable by searching for "office".
  #
  # The longer decomposition therefore wins, and the order stops mattering:
  # three characters say more about the glyph than one does, and "ffi" is what
  # a reader wants back from a search either way.
  #
  # This does NOT settle the older ambiguity of two characters sharing one
  # glyph through the cmap alone - Roboto maps U+0394 and U+2206 to the same
  # glyph, both lists are one long, and there is no answer that is right for
  # both. There the first one recorded stays.
  method FontRunEncode {alias run} {
    set fonts [my state fonts]
    set entry [dict get $fonts $alias]
    set used [dict get $entry used]
    set bytes {}
    foreach item $run {
      lassign $item glyph codes
      if {![dict exists $used $glyph]
          || [llength $codes] > [llength [dict get $used $glyph]]} {
        dict set used $glyph $codes
      }
      append bytes [binary format Su $glyph]
    }
    dict set entry used $used
    dict set fonts $alias $entry
    my state fonts $fonts
    return $bytes
  }

  # Encode text directly. Kept for the callers that have a string and no
  # reason to hold a run.
  method FontEncode {alias text {ligatures 0} {unshaped 0}} {
    return [my FontRunEncode $alias [my FontRun $alias $text $ligatures $unshaped]]
  }

  # The width of a prepared run, in points.
  #
  # A ligature contributes ITS advance, not the sum of the advances of the
  # characters it replaced - which is the whole point of measuring the run
  # rather than the string.
  #
  # A POSITIONED MARK adds nothing here, and that is deliberate. Mark
  # attachment moves a glyph, it does not move the pen: [TextEmit] shifts the
  # mark and gives the same amount straight back, so the run is as wide with
  # the offsets as without them. Measured in DejaVu Sans at 20 pt: "Marz", the
  # same word with a precomposed U+00E1, and the same word again with a plus
  # U+0301 all come to 48.232421875 pt, and the combining acute has an advance
  # of 0.
  #
  # The other half of that is the honest one: an anchor has an X as well, and
  # this method does NOT measure it. That is right while the X only displaces
  # the mark - and whoever ever makes it a real change of advance has to
  # change the measuring and the drawing in the same breath, or a line comes
  # out wider than it was measured and justified text frays at the margin.
  method FontRunWidth {alias run size {kerning 0}} {
    set parsed [dict get [my state fonts] $alias parsed]
    set units [dict get $parsed unitsPerEm]
    set total 0
    foreach item $run {
      set total [expr {$total + [my FontAdvance $alias $parsed \
          [lindex $item 0]]}]
    }
    set points [expr {double($total) * $size / $units}]
    if {$kerning} {
      set thousandths 0
      foreach adjust [my FontRunKern $alias $run] {
        set thousandths [expr {$thousandths + $adjust}]
      }
      set points [expr {$points + $thousandths * $size / 1000.0}]
    }
    return $points
  }

  # The kerning of a run: one adjustment per gap between two GLYPHS, in
  # thousandths of the em - the unit a TJ number is written in, so that the
  # measurement and the drawing cannot drift apart through two conversions.
  #
  # Per glyph, not per character: after "ffi" has become one glyph the pair to
  # look up is that ligature and its neighbour, and the pairs that used to sit
  # between f and f are gone with them.
  # The whole run goes down in one piece, not pair by pair: a lookup that
  # ignores marks kerns A against V across the acute between them, and a caller
  # that asked for one pair at a time could never see that pair.
  method FontRunKern {alias run} {
    if {[llength $run] < 2} {
      return {}
    }
    set glyphs {}
    foreach item $run {
      lappend glyphs [lindex $item 0]
    }
    set units [dict get [my state fonts] $alias parsed unitsPerEm]
    set adjustments {}
    foreach value [::tclpdf::kern run [my FontLayoutState $alias kern] $glyphs] {
      lappend adjustments [expr {$value * 1000.0 / $units}]
    }
    return $adjustments
  }

  # Where the combining marks of a run belong: one {dx dy} per glyph in
  # thousandths of the em, positionally aligned with the run, and {} for a run
  # that has no mark to place.
  #
  # The same shape as [FontRunKern] above and for the same reason - a second
  # list beside the run rather than a wider tuple, so that everything already
  # reading {glyph codes} goes on reading it.
  #
  # {} rather than a list of zeroes when nothing moves, and that is not
  # tidiness: it is what lets [TextEmit] write the bytes it has always written
  # for text without marks. A run of Latin prose asks this question, gets {},
  # and no operator is added anywhere.
  #
  # The offsets are LOGICAL, like everything else built here: they say where a
  # mark sits when the glyphs are drawn in the order the run holds them. A
  # right-to-left line draws them in another order, and text.tcl keeps a mark
  # with the glyph it hangs on for exactly that reason - see [TextCluster].
  method FontRunMarks {alias run} {
    if {[llength $run] < 2} {
      return {}
    }
    set state [my FontLayoutState $alias markPos]
    if {$state eq {}} {
      return {}
    }
    set offsets [::tclpdf::markPos run $state $run]
    foreach offset $offsets {
      lassign $offset dx dy
      if {$dx != 0 || $dy != 0} {
        return $offsets
      }
    }
    return {}
  }

  # One prepared layout table of a face, read once and kept.
  #
  # KEY is the topic and, in all three cases, also the package and the
  # namespace that reads it: kern for the pair kerning out of GPOS, liga for
  # the standard ligatures, forms for the cursive shapes. Each answers [build]
  # with something to hand to its own [apply], and {} for a face that has
  # nothing of the kind - which is an answer and gets cached like any other.
  #
  # The three used to be three methods with the same nine lines in them, and
  # the third one is what made that a duplicate rather than a coincidence.
  #
  # The package is loaded HERE rather than at the top of the file, and that is
  # the point of the arrangement: a document that never kerns never parses a
  # GPOS table - the largest thing in many fonts - and a document of Latin
  # text never walks the Arabic script table of its faces.
  # BUILDER is for the one topic that has no module of its own: the vertical
  # forms are four lines over gsubApply and live in this file, so there is no
  # tclpdf::vertForms to require. Everything else - the caching, the lazy
  # answer, the {} that is an answer - is the same, which is the whole reason
  # the parameter exists rather than a second copy of this method.
  method FontLayoutState {alias key {builder {}}} {
    set fonts [my state fonts]
    set entry [dict get $fonts $alias]
    if {[dict exists $entry $key]} {
      return [dict get $entry $key]
    }
    if {$builder eq {}} {
      package require tclpdf::$key 1.0-
      set builder [list ::tclpdf::$key build]
    }
    set state [{*}$builder [dict get $entry parsed]]
    dict set entry $key $state
    dict set fonts $alias $entry
    my state fonts $fonts
    return $state
  }

  # The resource name, registered on first use.
  #
  # The alias goes into the name AS IT IS, and pdfObj name escapes whatever
  # a PDF name cannot carry bare (7.3.5, #xx from PDF 1.2 on - which font
  # embed already requires). It used to strip the spaces first, and that made
  # two aliases one resource: "a b" and "ab" both became FEab, the second
  # face never got an object, and its text was drawn through the first face's
  # CIDToGIDMap. Measured before this: two embeds, one FontDescriptor,
  # pdffonts listing one face. Anything injective would do; keeping the alias
  # readable in the file is worth the escape.
  #
  # The PREFIX is a parameter because a second kind of font registers itself
  # the same way: a Type 3 font (type3.tcl) has an entry in the same state
  # dictionary and needs the same object reserved on first use, and only the
  # name it goes into the resource dictionary under differs. Written twice
  # the two would drift - one of them would learn something about a second
  # write and the other would not.
  method FontResource {alias {prefix FE}} {
    set name $prefix$alias
    if {[my resource Font $name] eq {}} {
      set fonts [my state fonts]
      set entry [dict get $fonts $alias]
      # Reserved now, filled at write time - only then is it known which
      # glyphs were used.
      dict set entry number [[my writer] reserve]
      dict set fonts $alias $entry
      my state fonts $fonts
      my resource Font $name [[my writer] ref [dict get $entry number]]
    }
    return [::tclpdf::pdfObj name $name]
  }

  # The resource name of a face's VERTICAL writing mode.
  #
  # A second Type 0 font object over the SAME descendant, the same descriptor
  # and the same embedded file - everything but the /Encoding, which is
  # Identity-V there and Identity-H here. That is what the writing mode is in
  # PDF: a property of the CMap the Type 0 font names (9.7.4.3), not of the
  # face and not of the text object, so a document that sets the same face
  # both ways needs two font dictionaries and exactly one font file.
  #
  # Reserved on first use like [FontResource], and reserved in the SLOTS
  # rather than beside [entry number]: the slots are what survive a second
  # write of the same document, and a vertical font that took a fresh object
  # number on every write would leave the first one referenced by a resource
  # dictionary that no longer names it.
  method FontVerticalResource {alias} {
    set name FV$alias
    if {[my resource Font $name] eq {}} {
      my resource Font $name [[my writer] ref [my FontSlot $alias vertical]]
    }
    return [::tclpdf::pdfObj name $name]
  }

  # Was this face ever set vertically? The question the writer asks, and the
  # reason it is asked of the SLOT: the slot exists exactly when
  # [FontVerticalResource] has been called, which is exactly when a line was
  # drawn with -direction ttb. A face used only horizontally therefore writes
  # the bytes it always wrote - no /DW2, no /W2, no second font object.
  method FontUsedVertically {alias} {
    return [dict exists [my state fonts] $alias slots vertical]
  }

  # -- writing ------------------------------------------------------------

  # The object number one piece of an embedded face is written under - the
  # font file, the descriptor, the CID font, the maps - reserved the first
  # time it is asked for and the SAME on every write after that.
  #
  # The write events fire on every write of a document, and this used to add
  # fresh objects each time: a document written twice carried two font files,
  # two descriptors and two CIDToGIDMaps for one face, the first set of them
  # referenced by nothing. Measured before this: the second write of a
  # one-font document had two FontDescriptors and was 8451 bytes to the
  # first's 4711. Now the numbers live with the face, and the second write fills the
  # same slots again - with the glyphs used by then, which is the point of
  # writing at write time.
  method FontSlot {alias key} {
    set fonts [my state fonts]
    if {![dict exists $fonts $alias slots $key]} {
      dict set fonts $alias slots $key [[my writer] reserve]
      my state fonts $fonts
    }
    return [dict get $fonts $alias slots $key]
  }

  method FontWrite {} {
    dict for {alias entry} [my state fonts] {
      if {[dict get $entry number] eq {}
          && ![dict exists $entry slots vertical]} {
        # Embedded but never used - no objects for it.
        #
        # "Used" now has two ways of being true. A face set ONLY vertically
        # never asks [FontResource] for a number and would have been skipped
        # here, leaving the resource dictionary pointing at an object that was
        # reserved and never written - which is the "object(s) reserved but
        # never written" qpdf reports, on a document whose text is simply
        # absent.
        continue
      }
      my FontWriteOne $alias $entry
    }
    return
  }

  # A simple font addressed by single bytes: a Type 1 program with its AFM, or
  # a bare CFF, which is a "Type 1-equivalent font program" and goes down the
  # same road for that reason (ISO 32000-1, Table 126).
  #
  # Nonsymbolic (bit 6, value 32) - the opposite of the TrueType road below,
  # and it follows from how the face is addressed: single bytes through
  # WinAnsiEncoding, which is a standard encoding, rather than glyph numbers.
  #
  # THE TWO FORK ONLY HERE, at the stream and at the descriptor key. A Type 1
  # program goes in as it came, in the three pieces it already consists of,
  # under /FontFile with the three lengths that say where they part. A CFF is
  # ONE piece with no lengths to state, and goes under /FontFile3 with
  # /Subtype /Type1C - the entry that says "this is a Type 1 program written
  # in the compact format". Everything else about the font dictionary is the
  # same, because everything else about how it is addressed is the same.
  method FontWriteType1 {alias entry} {
    set writer [my writer]
    set metrics [dict get $entry metrics]
    set widths [dict get $entry widths]

    if {[dict exists $entry cff]} {
      set fontFileNumber [$writer stream [my FontSlot $alias fontFile] \
          [list Subtype /Type1C Filter /FlateDecode] \
          [::tclpdf::filter encodeFlate [dict get $entry cff]]]
    } else {
      set program [dict get $entry program]
      set fontBytes [string cat [dict get $program clear] \
          [dict get $program encrypted] [dict get $program trailer]]
      set fontFileNumber [$writer stream [my FontSlot $alias fontFile] \
          [list Length1 [dict get $program length1] \
              Length2 [dict get $program length2] \
              Length3 [dict get $program length3] \
              Filter /FlateDecode] \
          [::tclpdf::filter encodeFlate $fontBytes]]
    }

    set baseName [dict get $metrics name]
    if {$baseName eq {} && [dict get $entry program] ne {}} {
      set baseName [dict get $entry program name]
    }
    if {$baseName eq {}} {
      set baseName $alias
    }
    set descriptorNumber [$writer put [my FontSlot $alias descriptor] \
        [::tclpdf::pdfObj dictionary [my FontType1DescriptorPairs $entry \
            $baseName [$writer ref $fontFileNumber]]]]

    # FirstChar to LastChar covers the whole encoding rather than only what
    # was used: nothing is subsetted here, every one of those glyphs is in the
    # file, and a Widths array that starts where the text happens to start
    # would have to be rebuilt whenever the text changes.
    set first 32
    set last 255
    set entries {}
    for {set code $first} {$code <= $last} {incr code} {
      lappend entries [::tclpdf::pdfObj num [lindex $widths $code]]
    }
    $writer put [dict get $entry number] [::tclpdf::pdfObj dictionary [list \
        Type /Font \
        Subtype /Type1 \
        BaseFont [::tclpdf::pdfObj name $baseName] \
        FirstChar $first \
        LastChar $last \
        Widths [$writer ref [$writer put [my FontSlot $alias widths] \
            [::tclpdf::pdfObj arr $entries]]] \
        Encoding /WinAnsiEncoding \
        FontDescriptor [$writer ref $descriptorNumber]]]
    return
  }

  method FontType1DescriptorPairs {entry baseName fontFileRef} {
    set metrics [dict get $entry metrics]
    set program [dict get $entry program]
    set bbox [dict get $metrics bbox]
    if {![llength $bbox] && $program ne {}} {
      set bbox [dict get $program bbox]
    }
    if {[llength $bbox] != 4} {
      set bbox {-200 -250 1000 1000}
    }
    set italic [dict get $metrics italicAngle]
    # Nonsymbolic, plus italic (bit 7) and fixed pitch (bit 1) where the
    # metrics say so.
    set flags 32
    if {$italic != 0} {
      incr flags 64
    }
    if {[dict get $metrics fixedPitch]} {
      incr flags 1
    }
    # Ascent, descent and cap height are required (9.8.1 Table 122). An AFM
    # may leave any of them out - or write a zero, which the URW metrics here
    # do and which means the same thing. The bounding box is then the honest
    # substitute, measured from the same outlines.
    set ascent [dict get $metrics ascender]
    if {$ascent eq {} || $ascent == 0} {
      set ascent [lindex $bbox 3]
    }
    set descent [dict get $metrics descender]
    if {$descent eq {} || $descent == 0} {
      set descent [lindex $bbox 1]
    }
    set capHeight [dict get $metrics capHeight]
    if {$capHeight eq {} || $capHeight == 0} {
      set capHeight $ascent
    }
    # StemV has no counterpart in an AFM that is guaranteed to be there -
    # StdVW is optional and both faces in this tree omit it. 80 is a middling
    # value, close to the 87 the TrueType road estimates for a regular
    # weight; a wrong StemV affects hinting hints, not the glyphs.
    set stemV [dict get $metrics stemV]
    if {$stemV eq {}} {
      set stemV 80
    }
    return [list Type /FontDescriptor \
        FontName [::tclpdf::pdfObj name $baseName] \
        Flags $flags \
        FontBBox [::tclpdf::pdfObj arr [lmap number $bbox {
          ::tclpdf::pdfObj num $number
        }]] \
        ItalicAngle [::tclpdf::pdfObj num $italic] \
        Ascent [::tclpdf::pdfObj num $ascent] \
        Descent [::tclpdf::pdfObj num $descent] \
        CapHeight [::tclpdf::pdfObj num $capHeight] \
        StemV $stemV \
        [expr {[dict exists $entry cff] ? {FontFile3} : {FontFile}}] \
        $fontFileRef]
  }

  # Which road an entry takes at write time - ONE switch over the kinds, and
  # a default that refuses.
  #
  # [state fonts] is shared: the type3 module (type3.tcl) puts its own
  # entries into the same dictionary and writes them itself, on the same
  # event. This used to ask only whether the kind was "type1" and let
  # everything else fall into the sfnt road below, so a document that had a
  # drawn font AND an embedded face - the ordinary case, since a Type 3 font
  # exists for the characters a real face has no glyph for - died at write
  # time on [dict get $entry parsed] with a bare Tcl "key \"parsed\" not
  # known in dictionary", from six levels down and naming nothing a caller
  # could act on. A kind with no road here now says so by its name.
  method FontWriteOne {alias entry} {
    set kind [dict get $entry kind]
    switch -exact -- $kind {
      type1 {
        my FontWriteType1 $alias $entry
      }
      truetype {
        my FontWriteSfnt $alias $entry
      }
      type3 {
        # Not this module's. [Type3Write] walks the same dictionary and
        # writes it, and doing it here as well would write it twice.
      }
      default {
        return -code error -errorcode [list TCLPDF FONT KIND $kind $alias] \
            "tclpdf: the font \"$alias\" is of kind \"$kind\", which has no\
            way of being written - the kinds this package writes are\
            truetype, type1 and type3"
      }
    }
    return
  }

  # An sfnt face - TrueType outlines or CFF - as a Type 0 font with
  # Identity-H and a ToUnicode CMap.
  method FontWriteSfnt {alias entry} {
    set writer [my writer]
    set parsed [dict get $entry parsed]
    set used [dict get $entry used]
    set units [dict get $parsed unitsPerEm]

    # CFF outlines are embedded whole. Subsetting rewrites loca and glyf, and
    # a CFF font has neither - its outlines are charstrings in a table this
    # package reads no further than its Top DICT (sfnt.tcl, the CID-keyed
    # question). Everything else about the face is the same sfnt
    # structure, which is why the road forks here and not earlier.
    set cff [expr {[dict get $parsed outlines] eq "cff"}]
    if {$cff} {
      set fontBytes [dict get $parsed bytes]
      set mapping {}
      foreach glyph [dict keys $used] {
        dict set mapping $glyph $glyph
      }
    } elseif {[dict get $entry subset]} {
      set built [::tclpdf::subset build $parsed [dict keys $used] \
          [my FontInstanced $alias]]
      set fontBytes [dict get $built bytes]
      set mapping [dict get $built glyphs]
    } elseif {[llength [dict get $entry coordinates]]} {
      # -subset 0 on an instance of a variable face: EVERY glyph goes in, but
      # through the instancer, not as the file. The file is the variable
      # face - fvar, gvar, avar and the rest - and PDF knows nothing of
      # variation, so a reader would draw its default outlines under the
      # instance's widths: Regular shapes spaced as Bold. Measured before this
      # branch existed, the embedded FontFile2 carried 22 tables including
      # gvar, and /W carried the Bold advances. The instance exists only as
      # the glyphs written for it, so with -subset 0 those are all of them;
      # every glyph keeps its number, and no subset tag is written because
      # none is missing.
      set all {}
      for {set glyph 0} {$glyph < [dict get $parsed numGlyphs]} {incr glyph} {
        lappend all $glyph
      }
      set built [::tclpdf::subset build $parsed $all [my FontInstanced $alias]]
      set fontBytes [dict get $built bytes]
      set mapping [dict get $built glyphs]
    } else {
      set fontBytes [dict get $parsed bytes]
      set mapping {}
      foreach glyph [dict keys $used] {
        dict set mapping $glyph $glyph
      }
    }

    # The font file itself.
    #
    # TrueType goes in as FontFile2 with /Length1, the uncompressed length
    # (9.9). CFF goes in as FontFile3 with /Subtype /OpenType, which is the
    # entry for a complete OpenType file rather than a bare CFF table - the
    # whole sfnt is handed over, cmap and all, and the reader takes what it
    # needs. /Length1 has no meaning there and is left out.
    if {$cff} {
      set fontFileNumber [$writer stream [my FontSlot $alias fontFile] \
          [list Subtype /OpenType Filter /FlateDecode] \
          [::tclpdf::filter encodeFlate $fontBytes]]
    } else {
      set fontFileNumber [$writer stream [my FontSlot $alias fontFile] \
          [list Length1 [string length $fontBytes] Filter /FlateDecode] \
          [::tclpdf::filter encodeFlate $fontBytes]]
    }

    # Derived once and passed on: the name has to be the SAME in all three
    # places (descriptor, CID font, Type0 font), and deriving it three times is
    # how two of them would one day disagree.
    #
    # No subset prefix for CFF: the tag MEANS subset (9.9.2), and nothing was
    # subsetted here.
    set baseName [my FontBaseName $entry $alias \
        [expr {!$cff && [dict get $entry subset]}]]

    set descriptorNumber [$writer put [my FontSlot $alias descriptor] \
        [::tclpdf::pdfObj dictionary [my FontDescriptorPairs $alias $entry $baseName \
            [$writer ref $fontFileNumber] $cff]]]

    # The CID font.
    #
    # The CID is the glyph number of the ORIGINAL face, which is what the
    # content stream carries - it is written long before the subset exists and
    # cannot know the new numbering. CIDToGIDMap is the table that bridges the
    # two, and this is exactly what it is for.
    #
    # Declaring /Identity here instead is the trap: it says "CID equals glyph
    # number in the embedded file", which is false as soon as anything is
    # subsetted. The document then renders - with the wrong glyphs, and the
    # extracted text is noise. qpdf reports nothing, pdffonts still says the
    # ToUnicode map is present.
    #
    # CIDToGIDMap belongs to CIDFontType2 and to nothing else. A CFF face is a
    # CIDFontType0, where the mapping from CID to glyph is the font's own
    # business - and with Identity ordering and no subsetting the two are the
    # same number anyway.
    set pairs [list \
        Type /Font Subtype [expr {$cff ? {/CIDFontType0} : {/CIDFontType2}}] \
        BaseFont [::tclpdf::pdfObj name $baseName] \
        CIDSystemInfo [::tclpdf::pdfObj dictionary [list \
            Registry [my Str Adobe] \
            Ordering [my Str Identity] \
            Supplement 0]] \
        FontDescriptor [$writer ref $descriptorNumber] \
        DW 1000 \
        W [my FontWidthArray $alias $parsed $used $units]]
    # The vertical metric, and ONLY for a face something was set vertically
    # with. /DW2 and /W2 belong to the CID font, which both writing modes
    # share, and a reader consults them only through a CMap whose WMode is 1 -
    # so writing them always would be harmless and would still change the
    # bytes of every document this package has ever produced.
    #
    # /DW2 is written at its own default [880 -1000] rather than left out.
    # The default is what nearly every glyph of a CJK face wants (measured at
    # [FontVerticalWidthArray]), and saying it in the file costs sixteen bytes
    # and spares whoever opens the file with qpdf the question of which
    # default is in force.
    if {[my FontUsedVertically $alias]} {
      lappend pairs DW2 [::tclpdf::pdfObj arr [list \
          [::tclpdf::pdfObj num 880] [::tclpdf::pdfObj num -1000]]]
      set vertical [my FontVerticalWidthArray $alias $parsed $used $units]
      if {$vertical ne {}} {
        lappend pairs W2 $vertical
      }
    }
    if {!$cff} {
      set cidToGidNumber [$writer stream [my FontSlot $alias cidToGid] \
          {Filter /FlateDecode} \
          [::tclpdf::filter encodeFlate [my FontCidToGid $mapping]]]
      lappend pairs CIDToGIDMap [$writer ref $cidToGidNumber]
    }
    set descendantNumber [$writer put [my FontSlot $alias descendant] \
        [::tclpdf::pdfObj dictionary $pairs]]

    set toUnicodeNumber [$writer stream [my FontSlot $alias toUnicode] \
        {Filter /FlateDecode} \
        [::tclpdf::filter encodeFlate [my FontToUnicode $used]]]

    # ONE Type 0 font per writing mode, over the one descendant written
    # above. Horizontal only where a line was actually set that way - a face
    # used purely vertically writes no Identity-H object at all, rather than
    # one nothing references.
    if {[dict get $entry number] ne {}} {
      $writer put [dict get $entry number] \
          [my FontType0 $baseName $cff Identity-H $descendantNumber \
              $toUnicodeNumber]
    }
    if {[my FontUsedVertically $alias]} {
      $writer put [my FontSlot $alias vertical] \
          [my FontType0 $baseName $cff Identity-V $descendantNumber \
              $toUnicodeNumber]
    }
    return
  }

  # The Type 0 font dictionary for ONE writing mode.
  #
  # Identity-H and Identity-V are the same CMap in the two directions: both
  # map a two-byte code to the CID of the same number, and the ONLY thing that
  # differs is the WMode the CMap declares (9.7.4.3). That is why the two
  # objects share everything below them - descendant, descriptor, font file -
  # and why the ToUnicode map is the same object as well: it maps CIDs to
  # characters and knows nothing of direction. Mapping it "the other way" for
  # the vertical font is the mistake that makes a vertical line extract
  # backwards while it renders perfectly.
  #
  # The name: for a CIDFontType0 descendant, 9.7.6.1 says it should be the
  # descendant's BaseFont with the CMap name behind a hyphen -
  # NimbusSans-Regular-Identity-H - and for a CIDFontType2 the descendant's
  # name alone. Neither costs anything, and a "should" that is free is
  # followed.
  method FontType0 {baseName cff cmap descendantNumber toUnicodeNumber} {
    set writer [my writer]
    set type0Name $baseName
    if {$cff} {
      append type0Name -$cmap
    }
    return [::tclpdf::pdfObj dictionary [list \
        Type /Font Subtype /Type0 \
        BaseFont [::tclpdf::pdfObj name $type0Name] \
        Encoding /$cmap \
        DescendantFonts [::tclpdf::pdfObj arr [list [$writer ref $descendantNumber]]] \
        ToUnicode [$writer ref $toUnicodeNumber]]]
  }

  # The name a face is embedded under, with the subset tag in front where one
  # belongs.
  #
  # The name is the PostScript name of the file - or, for an instance of a
  # variable face, the name of THAT instance by TN 5902 (varFont
  # postScriptName): Roboto-Bold for the named one, Roboto_620wght for a
  # point in between. Name id 6 of a variable file names its default, and
  # writing it for every weight told a reader nine times over that a
  # different font was Roboto-Regular.
  #
  # The six-letter tag says "this is a subset" (9.9.2) - so a face embedded
  # WHOLE, through "font embed -subset 0", must not carry one. It did until
  # now, which named a complete DejaVuSans a subset of itself: a reader
  # merging fonts across documents is told to keep two incompatible copies,
  # and a preflight tool is entitled to reject the file.
  #
  # The tag is derived from WHAT WAS SUBSETTED - the name, the glyphs used and
  # the point on the axes - because 9.6.4 asks that different subsets of one
  # face in one file carry different tags. It used to be a function of the
  # name alone, and 02.10 then embedded twenty-four instances of Roboto all
  # tagged SZGNUB+: a reader entitled to treat same tag and same name as the
  # same font would have drawn Thin with the glyphs of Black. Same input, same
  # tag, so two writes of one document stay byte-identical; a document that
  # sets one letter more gets a different tag, which is exactly right, since
  # it is a different subset.
  method FontBaseName {entry alias {subsetted 1}} {
    set parsed [dict get $entry parsed]
    if {[dict exists $entry axes] && [dict size [dict get $entry axes]]} {
      package require tclpdf::varFont 1.0-
      set name [::tclpdf::varFont postScriptName $parsed [dict get $entry axes]]
    } elseif {[dict exists [dict get $parsed names] postScript]} {
      set name [dict get $parsed names postScript]
    } else {
      set name $alias
    }
    set name [string map {{ } {}} $name]
    if {!$subsetted} {
      return $name
    }
    set key "$name|[lsort -integer [dict keys [dict get $entry used]]]|[dict get $entry coordinates]"
    # CRC-32 of the key, spelt as six capital letters - 26^6 is 308 million
    # tags, of which the checksum picks one; the top four bits of it are not
    # used. Not a cryptographic hash and not meant as one: two subsets that
    # collide would have to differ in glyphs and agree in checksum, and a
    # reader confuses two fonts only when tag AND name AND file agree.
    set crc [zlib crc32 [encoding convertto utf-8 $key]]
    set tag {}
    for {set index 0} {$index < 6} {incr index} {
      append tag [format %c [expr {65 + $crc % 26}]]
      set crc [expr {$crc / 26}]
    }
    return "$tag+$name"
  }

  # The font descriptor (9.8.1, Table 122). Every value in it comes from the
  # file except StemV, which TrueType has no field for.
  #
  # ItalicAngle is post.italicAngle - written as 0 for every face until it was
  # read, so Nimbus Sans Oblique declared itself upright. CapHeight is OS/2
  # sCapHeight where the table is version 2 or later and the field is filled,
  # else the ascender - it was the ascender for every face, which put the cap
  # height of Roboto at 928 instead of 711. StemV is estimated from
  # usWeightClass by the rule tFPDF and mPDF use, 50 + (weight / 65)^2 - 87
  # for a regular face, 166 for a bold one; a wrong StemV affects hinting
  # hints, not the glyphs, and a constant 80 for a Black cut was wrong by a
  # factor of three. For an instance of a variable face the wght axis IS its
  # weight class, and the estimate follows the axis rather than the file's
  # default.
  #
  # FontBBox is the file's box - the whole face, not the glyphs the subset
  # keeps, which is what fontTools' subsetter leaves in head as well unless
  # told to recalculate - or,
  # for an instance of a variable face, the box of the MOVED face from the
  # instanced glyphs (varFont bounds), which is also what the subset's head
  # table carries. The file's box describes the default outlines, and none of
  # them is embedded for an instance: measured on Roboto at wght 900, the
  # instance reaches 130 units (63 thousandths of an em) further right than
  # the file's box says.
  #
  # An instance on a slnt or ital axis is a slanted face however upright the
  # file's post table says the default is: the slnt value IS the italic angle
  # (both are degrees counter-clockwise from the vertical, OpenType "slnt",
  # negative for a right lean), and ital at 0.5 or more is the italic design.
  # Both set the italic flag (Table 123, bit 7). Measured before this:
  # Bitcount at slnt -8 wrote ItalicAngle 0 and Flags 4 under outlines that
  # lean.
  #
  # CapHeight where OS/2 is older than version 2 and has no sCapHeight: the
  # top of the H (U+0048), which is what the field measures - not the
  # ascender, which is where the ascender is. DejaVu Sans, OS/2 version 1,
  # wrote 928 for a cap height of 729. Only a face without an H, or a CFF
  # face without OS/2 v2 (whose glyph boxes this package does not read),
  # still falls back to the ascender.
  method FontDescriptorPairs {alias entry baseName fontFileRef {cff 0}} {
    set parsed [dict get $entry parsed]
    set units [dict get $parsed unitsPerEm]
    set bbox [dict get $parsed bbox]
    if {[llength [dict get $entry coordinates]]} {
      package require tclpdf::varFont 1.0-
      set bbox [::tclpdf::varFont bounds [my FontInstanced $alias]]
    }
    lassign $bbox xMin yMin xMax yMax
    set scale [expr {1000.0 / $units}]
    set italicAngle [dict get $parsed italicAngle]
    set italicAxis 0
    if {[dict exists $entry axes]} {
      set axes [dict get $entry axes]
      if {[dict exists $axes slnt] && [dict get $axes slnt] != 0} {
        set italicAngle [::tclpdf::pdfObj num [dict get $axes slnt]]
        set italicAxis 1
      }
      if {[dict exists $axes ital] && [dict get $axes ital] >= 0.5} {
        set italicAxis 1
      }
    }
    # Symbolic (bit 3) rather than nonsymbolic: the font is addressed by glyph
    # id, so no standard encoding applies to it.
    set flags 4
    if {[dict get $parsed macStyle] & 2 || $italicAngle != 0 || $italicAxis} {
      incr flags 64
    }
    set ascent [expr {[dict get $parsed ascender] * $scale}]
    # OS/2 (Table 122 asks for CapHeight, TrueType keeps it here). Read with
    # the rest of the file in sfnt.tcl since [font info] came to want the same
    # two numbers - the alternative was a second scan of the same table here,
    # free to drift from the first.
    set os2 [dict get $parsed os2]
    set weight [dict get $os2 weightClass]
    set capHeight [dict get $os2 capHeight]
    if {$capHeight ne {}} {
      set capHeight [expr {$capHeight * $scale}]
    }
    if {$capHeight eq {}} {
      set top [my FontGlyphTop $alias $parsed 72]
      set capHeight [expr {$top eq {} ? $ascent : $top * $scale}]
    }
    if {[dict exists $entry axes] && [dict exists [dict get $entry axes] wght]} {
      set weight [dict get $entry axes wght]
    }
    set stemV [expr {int(50 + ($weight / 65.0) ** 2)}]
    return [list Type /FontDescriptor \
        FontName [::tclpdf::pdfObj name $baseName] \
        Flags $flags \
        FontBBox [::tclpdf::pdfObj arr [list \
            [::tclpdf::pdfObj num [expr {$xMin * $scale}]] \
            [::tclpdf::pdfObj num [expr {$yMin * $scale}]] \
            [::tclpdf::pdfObj num [expr {$xMax * $scale}]] \
            [::tclpdf::pdfObj num [expr {$yMax * $scale}]]]] \
        ItalicAngle [::tclpdf::pdfObj num $italicAngle] \
        Ascent [::tclpdf::pdfObj num $ascent] \
        Descent [::tclpdf::pdfObj num [expr {[dict get $parsed descender] * $scale}]] \
        CapHeight [::tclpdf::pdfObj num $capHeight] \
        StemV $stemV \
        [expr {$cff ? {FontFile3} : {FontFile2}}] $fontFileRef]
  }

  # The yMax of the glyph a character maps to, in font units, read off the
  # glyph record's header - of the instanced glyph where the face is an
  # instance, since that is the glyph the file will carry - or {} where there
  # is none to read: no such character, an empty glyph, or CFF outlines,
  # which this package does not walk. The code is a decimal code point, as
  # the cmap keys are: a dict compares strings, and 0x0048 is not 72 to it.
  method FontGlyphTop {alias parsed code} {
    set cmap [dict get $parsed cmap]
    if {![dict exists $cmap $code]} {
      return {}
    }
    return [my FontGlyphYMax $alias $parsed [dict get $cmap $code]]
  }

  # The same measurement asked of a GLYPH rather than a character, which is
  # what the vertical origin needs: vmtx keys on the glyph and knows no
  # characters. [FontGlyphTop] is this method with a cmap lookup in front of
  # it - split when the second caller appeared, rather than written twice
  # with the instance branch in both.
  method FontGlyphYMax {alias parsed glyph} {
    if {[dict get $parsed outlines] ne "truetype"} {
      return {}
    }
    set instanced [my FontInstanced $alias]
    if {[dict exists $instanced $glyph]} {
      set data [dict get $instanced $glyph bytes]
    } else {
      set loca [dict get $parsed loca]
      set start [lindex $loca $glyph]
      set stop [lindex $loca [expr {$glyph + 1}]]
      set data [expr {$start >= $stop ? {} :
          [string range [::tclpdf::sfnt table $parsed glyf] $start [expr {$stop - 1}]]}]
    }
    if {[string length $data] < 10} {
      return {}
    }
    binary scan $data @8S yMax
    return $yMax
  }

  # The /W array: widths per CID, in 1/1000 em. Written as individual entries
  # rather than as ranges - a range that is one CID off shifts every following
  # width, and the saving is a few dozen bytes.
  method FontWidthArray {alias parsed used units} {
    set scale [expr {1000.0 / $units}]
    set entries {}
    foreach glyph [lsort -integer [dict keys $used]] {
      set width [expr {[my FontAdvance $alias $parsed $glyph] * $scale}]
      lappend entries $glyph [::tclpdf::pdfObj arr [list [::tclpdf::pdfObj num $width]]]
    }
    return [::tclpdf::pdfObj arr $entries]
  }

  # The /W2 array: the metric of VERTICAL writing per CID (ISO 32000-2,
  # 9.7.4.3), in 1/1000 em. Three numbers per glyph where /W has one:
  #
  #   w1y   the vertical displacement - NEGATIVE, because the line runs down
  #   v     the position vector, the point of the glyph that lands on the
  #         current point: its x is half the HORIZONTAL advance, which is
  #         what centres a glyph over the column, and its y is the vertical
  #         origin out of vmtx or VORG
  #
  # ONLY WHAT DIFFERS FROM /DW2 is written, and that is not a saving of a few
  # bytes as it is with /W - it is the difference between an array of three
  # numbers per glyph and an array of nothing at all. Measured in Noto Sans
  # JP: 16522 of its 17103 glyphs sit at the default origin 880 and 17096 of
  # them advance the default 1000, so a document of ordinary Japanese writes
  # an empty /W2 and gets every metric right from /DW2.
  #
  # The position vector's x never triggers an entry by itself: the default IS
  # half the horizontal advance (9.4.4), so a glyph whose height and origin
  # are both the default needs nothing said about it. But an entry written
  # for either of the other two has to carry x as well, because /W2 gives all
  # three or none.
  method FontVerticalWidthArray {alias parsed used units} {
    set scale [expr {1000.0 / $units}]
    set entries {}
    foreach glyph [lsort -integer [dict keys $used]] {
      set displacement [expr {-[my FontVerticalAdvance $alias $parsed $glyph]
          * $scale}]
      set originY [expr {[my FontVerticalOrigin $alias $parsed $glyph] * $scale}]
      if {$displacement == -1000 && $originY == 880} {
        continue
      }
      set originX [expr {[my FontAdvance $alias $parsed $glyph] * $scale / 2.0}]
      lappend entries $glyph [::tclpdf::pdfObj arr [list \
          [::tclpdf::pdfObj num $displacement] \
          [::tclpdf::pdfObj num $originX] \
          [::tclpdf::pdfObj num $originY]]]
    }
    if {![llength $entries]} {
      return {}
    }
    return [::tclpdf::pdfObj arr $entries]
  }

  # CID to glyph id in the embedded file: two bytes per CID, from 0 to the
  # highest one used. Unused positions hold 0, which is .notdef - a reader
  # that lands there shows the fallback rather than a random glyph.
  method FontCidToGid {mapping} {
    set highest 0
    dict for {original new} $mapping {
      if {$original > $highest} {
        set highest $original
      }
    }
    set bytes {}
    for {set cid 0} {$cid <= $highest} {incr cid} {
      append bytes [binary format Su [expr {[dict exists $mapping $cid] ?
          [dict get $mapping $cid] : 0}]]
    }
    return $bytes
  }

  # The ToUnicode CMap (9.10.3). Without it the text is glyph numbers and
  # cannot be copied or searched - and no tool reports the omission.
  # BYTES is the width of a character code in the font this map belongs to:
  # two for the Identity-H road below, one for a Type 3 font (type3.tcl),
  # which is addressed by single bytes. It decides the codespace range and
  # how wide the source of a bfchar is written - both have to match the font
  # or the reader maps nothing at all, and no validator says a word about it.
  method FontToUnicode {used {bytes 2}} {
    set width [expr {2 * $bytes}]
    set lines {}
    foreach glyph [lsort -integer [dict keys $used]] {
      set cid $glyph
      # One glyph may stand for several characters: a ligature. The
      # destination of a bfchar is a UTF-16BE STRING, not a single value, so
      # "ffi" is written as three code units and extracts as three letters.
      # Writing only the first would turn every ligature into a lost word.
      set target {}
      foreach code [dict get $used $glyph] {
        if {$code > 0xFFFF} {
          # Outside the BMP: the target is a surrogate pair.
          set value [expr {$code - 0x10000}]
          append target [format %04X%04X [expr {0xD800 | ($value >> 10)}] \
              [expr {0xDC00 | ($value & 0x3FF)}]]
        } else {
          append target [format %04X $code]
        }
      }
      lappend lines "<[format %0*X $width $cid]> <$target>"
    }
    set map "/CIDInit /ProcSet findresource begin\n"
    append map "12 dict begin\nbegincmap\n"
    append map "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
    append map "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
    append map "1 begincodespacerange\n<[string repeat 0 $width]>\
        <[string repeat F $width]>\nendcodespacerange\n"
    # bfchar takes at most 100 entries per block (9.10.3).
    set total [llength $lines]
    for {set start 0} {$start < $total} {incr start 100} {
      set chunk [lrange $lines $start [expr {$start + 99}]]
      append map "[llength $chunk] beginbfchar\n[join $chunk \n]\nendbfchar\n"
    }
    append map "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    return $map
  }

  # Which font resources of this document carry no font program, by family
  # name. Empty when every one of them is embedded.
  #
  # Asked by two standards for different reasons - PDF/A 6.2.11.4 and PDF/UA
  # 7.21.4 Note 5 - and the answer is the same fact, so it is established
  # once here and judged there. The wording has to differ: PDF/A can suggest
  # dropping the declaration, PDF/UA has to say that Symbol and ZapfDingbats
  # rule the document out entirely.
  #
  # Checked against the OBJECTS rather than against a list of intentions: a
  # font resource exists only once something was set in it, and its dictionary
  # either names a font file or it does not. That catches the case nobody
  # notices - a table theme defaulting to Helvetica in a document whose text
  # is all in an embedded face.
  method fontsWithoutProgram {} {
    set missing {}
    dict for {name reference} [my resource Font] {
      if {![regexp {(\d+) 0 R} $reference -> number]} {
        continue
      }
      if {[my FontHasProgram $number 3]} {
        continue
      }
      # Name the FAMILY, not the resource - "F1 is not embedded" tells a
      # caller nothing about which call to fix.
      unset -nocomplain family
      regexp {/BaseFont /(\S+?)[ />]} [[my writer] body $number] -> family
      lappend missing [expr {[info exists family] ? $family : $name}]
    }
    return [lsort -unique $missing]
  }

  # Does this font object, or anything it points at, carry a font program?
  #
  # Following the references rather than looking in one place, because how
  # deep the file sits depends on the kind of font: a simple TrueType font
  # names its descriptor directly, while a Type0 goes Type0 -> CIDFont ->
  # FontDescriptor -> FontFile2. Checking only one level reports every
  # embedded Type0 face as missing, which is what a first attempt here did.
  method FontHasProgram {number depth} {
    if {$depth <= 0} {
      return 0
    }
    set body [[my writer] body $number]
    if {[regexp {/FontFile[23]?\s} $body]} {
      return 1
    }
    # A Type 3 font never has one and never needs one: its glyphs ARE in the
    # file, as the content streams of its CharProcs dictionary (ISO 32000-2,
    # 9.6.4). Without this line every PDF/A and PDF/UA document with a drawn
    # font was refused for a font program that cannot exist - measured, the
    # message named the resource, because there is no /BaseFont to read
    # either.
    if {[string match {*/Subtype /Type3*} $body]} {
      return 1
    }
    foreach reference [regexp -all -inline {(\d+) 0 R} $body] {
      if {![string is integer -strict $reference]} {
        continue
      }
      if {[my FontHasProgram $reference [expr {$depth - 1}]]} {
        return 1
      }
    }
    return 0
  }
}

package provide tclpdf::font 1.13