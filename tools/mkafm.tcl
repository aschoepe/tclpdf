#!/bin/sh
#\
exec tclsh "$0" "$@"

#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# Generate afmData.tcl - the metrics of the 14 standard fonts - from the
# original Adobe AFM files.
#
# Usage: mkafm.tcl <afm-directory> > afmData.tcl
#
# This is a BUILD-TIME tool. It does not ship and it is not needed to use the
# package; it exists so that the numbers in afmData.tcl can be reproduced and
# checked against their source rather than being trusted.
#
# Why a generator at all: the alternative is 3 500 numbers typed or recalled,
# and a single wrong width shows up as text that overflows its column - in one
# font, at one size, in one document. Nothing reports it.
#
# The mapping from a byte to a width takes three steps:
#
#   1. byte -> Unicode      via cp1252, which is what WinAnsiEncoding is built
#                           on. Measured: the encoding exists in Tcl 8.6 and 9.
#   2. Unicode -> glyph name  via the Adobe Glyph List
#   3. glyph name -> width    from the AFM file
#
# Symbol and ZapfDingbats are different: they carry their own built-in
# encoding, so their AFM character codes are used directly and cp1252 does not
# apply to them.
#

if {[llength $argv] != 1} {
  puts stderr "usage: [file tail [info script]] <afm-directory>"
  exit 1
}

lassign $argv afmDirectory

# The 14 standard fonts (9.6.2.2). The order is the one they are listed in.
set fonts {
  Courier Courier-Bold Courier-Oblique Courier-BoldOblique
  Helvetica Helvetica-Bold Helvetica-Oblique Helvetica-BoldOblique
  Times-Roman Times-Bold Times-Italic Times-BoldItalic
  Symbol ZapfDingbats
}

# Fonts with a built-in encoding - cp1252 says nothing about them.
set symbolic {Symbol ZapfDingbats}

# Two positions carry a glyph the AGL does not give them: ISO 32000-1 Annex
# D.2 (footnotes to "space" and "hyphen") makes 0xA0 in WinAnsiEncoding a
# second code for space - the no-break space - and 0xAD a second code for
# hyphen. A reader draws those glyphs there, so their widths belong there
# too. Through the AGL alone the two positions come out as "nbspace" and
# "sfthyphen", which no AFM knows, and held 0 - measured 2026-08-16: U+00A0
# in Helvetica was refused as "no glyph". type1.tcl carries the same two
# aliases for an embedded Type 1 face; this is the standard-fourteen half of
# that rule.
set annexD {160 space 173 hyphen}

# --- glyph name -> Unicode, from the Adobe Glyph List ----------------------
#
# agl/glyphlist.txt is the list itself, verbatim from Adobe, with its own BSD
# licence header. It lives here rather than being fetched or borrowed: this
# generator used to take the table as a second argument and read it out of a
# pdf4tcl installation, which meant afmData.tcl could not be reproduced
# without another project on the disk - a dependency that appeared nowhere but
# in an unnamed argv parameter.
#
# Entries with more than one code point (ligature names such as "dalethatafpatah")
# are skipped: they name a sequence, not a character, and nothing here can use
# them.
set glyphToUni {}
set channel [open [file join [file dirname [info script]] agl glyphlist.txt] r]
foreach line [split [read $channel] \n] {
  if {[string index $line 0] eq "#" || $line eq ""} {
    continue
  }
  lassign [split $line ";"] name codes
  if {[llength $codes] != 1} {
    continue
  }
  dict set glyphToUni $name [scan $codes %x]
}
close $channel

# ALL names per code point, not one. Several names map to the same character
# (Euro/euro, Delta/uni0394), and which of them a font actually carries differs
# between fonts - so the choice cannot be made here. It is made per font, by
# taking the first name the AFM file knows.
#
# Picking one name up front looks harmless and is not: it silently produced
# width 0 for the Euro sign in all 14 fonts, which would have placed every
# amount on an invoice a few points off - in a document that opens fine and
# that no validator complains about.
#
# The names of one code point keep the order of the list, which is
# alphabetical - deterministic, unlike the hash order an array would have
# given. Two runs of this generator therefore produce the same file.
set uniToGlyphs {}
dict for {name code} $glyphToUni {
  dict lappend uniToGlyphs $code $name
}

# --- read one AFM file ----------------------------------------------------

proc readAfm {path} {
  set channel [open $path r]
  fconfigure $channel -translation auto
  set widths {}
  set codes {}
  set header {}
  while {[gets $channel line] >= 0} {
    if {[string match "C *" $line]} {
      # C 32 ; WX 278 ; N space ; B 0 0 0 0 ;
      if {[regexp {C\s+(-?\d+)\s*;\s*WX\s+(\d+)\s*;\s*N\s+(\S+)} $line -> code width name]} {
        dict set widths $name $width
        if {$code >= 0} {
          dict set codes $code $name
        }
      }
      continue
    }
    foreach key {FontBBox CapHeight XHeight Ascender Descender ItalicAngle
                 IsFixedPitch StdVW FontName UnderlinePosition UnderlineThickness} {
      if {[string match "$key *" $line]} {
        dict set header $key [string trim [string range $line [string length $key] end]]
      }
    }
  }
  close $channel
  return [list $widths $codes $header]
}

# --- emit -----------------------------------------------------------------

puts "#"
puts "# tclpdf - PDF generation for Tcl"
puts "#"
puts "# afmData - metrics of the 14 standard fonts"
puts "#"
puts "# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl\@sowaswie.de>"
puts "#"
puts "# See the file \"license.terms\" for information on usage and redistribution"
puts "# of this file (MIT License)."
puts "#"
puts "# GENERATED - do not edit. Produced by tools/mkafm.tcl from the original"
puts "# Adobe AFM files (StartFontMetrics 4.1, Copyright (c) 1985-1997 Adobe"
puts "# Systems Incorporated). Rerun the generator instead of correcting a"
puts "# number here; a hand-fixed value would be lost on the next run and would"
puts "# no longer match its source."
puts "#"
puts "# Widths are in 1/1000 of the em square, indexed by byte value under"
puts "# WinAnsiEncoding - except Symbol and ZapfDingbats, which are indexed by"
puts "# their own built-in encoding. Unmapped positions hold 0."
puts "#"
puts ""
puts "package require Tcl 8.6.11-"
puts ""
puts "namespace eval ::tclpdf::afmData {"
puts "  variable widths"
puts "  variable descriptor"
puts "}"
puts ""

foreach font $fonts {
  lassign [readAfm [file join $afmDirectory $font.afm]] widths codes header

  set table {}
  if {$font in $symbolic} {
    for {set code 0} {$code < 256} {incr code} {
      if {[dict exists $codes $code]} {
        lappend table [dict get $widths [dict get $codes $code]]
      } else {
        lappend table 0
      }
    }
  } else {
    # Byte by byte, and guarded. Five positions are unassigned in cp1252
    # (0x81, 0x8D, 0x8F, 0x90, 0x9D), and the two interpreters disagree about
    # them - measured: Tcl 8.6.18 passes them through, Tcl 9.0.4 throws
    # "unexpected byte sequence". Converting all 256 bytes in one call
    # therefore works under 8.6 and aborts the generator under 9.
    for {set code 0} {$code < 256} {incr code} {
      set width 0
      if {[catch {encoding convertfrom cp1252 [binary format cu $code]} char]} {
        # Unassigned in WinAnsiEncoding - width 0 is the correct answer.
        lappend table $width
        continue
      }
      set unicode [scan $char %c]
      # The Annex D name first: it is the glyph a reader draws at this code,
      # whatever else the AGL may list for the character.
      set names {}
      if {[dict exists $annexD $code]} {
        lappend names [dict get $annexD $code]
      }
      if {[dict exists $uniToGlyphs $unicode]} {
        lappend names {*}[dict get $uniToGlyphs $unicode]
      }
      foreach name $names {
        if {[dict exists $widths $name]} {
          set width [dict get $widths $name]
          break
        }
      }
      lappend table $width
    }
  }

  # Sixteen values per line: one row per 16 byte values, so a position can be
  # found by counting rows rather than by counting numbers.
  puts "set ::tclpdf::afmData::widths($font) \{"
  for {set start 0} {$start < 256} {incr start 16} {
    puts "  [join [lrange $table $start [expr {$start + 15}]] { }]"
  }
  puts "\}"

  # The FontDescriptor values (9.8.1). Needed even for the standard fonts as
  # soon as a document declares an Encoding difference.
  set flags 32
  if {[dict exists $header IsFixedPitch] && [dict get $header IsFixedPitch] eq "true"} {
    incr flags 1
  }
  if {$font in $symbolic} {
    set flags [expr {($flags & ~32) | 4}]
  }
  if {[dict exists $header ItalicAngle] && [dict get $header ItalicAngle] != 0} {
    incr flags 64
  }
  set values {}
  foreach {key default} {FontBBox {0 0 0 0} CapHeight 0 XHeight 0 Ascender 0
                         Descender 0 ItalicAngle 0 StdVW 80
                         UnderlinePosition {} UnderlineThickness {}} {
    set value $default
    if {[dict exists $header $key]} {
      set value [dict get $header $key]
    }
    lappend values $key $value
  }
  lappend values Flags $flags
  puts "set ::tclpdf::afmData::descriptor($font) \{$values\}"
  puts ""
}

# The generator did NOT write this line until 2026-08-13, so the committed
# afmData.tcl carried a hand-added last line while its own header said
# "GENERATED - do not edit, rerun the generator instead". Anyone who followed
# that instruction got a module without a version, and tests/version.test then
# failed on it. The file has to be reproducible in full or the header is a lie.
#
# The number is written out here rather than read from anywhere: a module
# version is raised by the author, deliberately, and a generator that guessed
# it would raise it behind their back.
puts "package provide tclpdf::afmData 1.0"

