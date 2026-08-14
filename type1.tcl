#
# tclpdf - PDF generation for Tcl
#
# type1 - reading Type 1 font programs and their metrics
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A private sub-module behind the font facade - nothing outside font.tcl loads
# this. It knows the file format and nothing about PDF.
#
# WHY THIS IS SMALL. A Type 1 font program is already in the three pieces PDF
# asks for as Length1, Length2 and Length3 (ISO 32000-1 9.9.1): a PostScript
# header in the clear, the eexec-encrypted body, and 512 zeros with
# "cleartomark" behind them. Embedding is therefore a matter of finding the
# two boundaries and copying the bytes - nothing is decrypted, no charstring
# is read. That is the whole difference to OpenType/CFF, where the table has
# to be understood before it can be cut down.
#
# TWO CONTAINERS, one format. A .pfb wraps the same three pieces in 6-byte
# segment markers that state their lengths; a .t1 or .pfa carries them raw and
# the lengths have to be found in the content. Both are handled, and the
# lengths are compared against each other where both sources exist.
#
# WHAT IS NOT DONE, on purpose:
#
#   subsetting     would mean decrypting eexec and reading Type 1 charstrings.
#                  A whole face here is 25 to 105 KB, which is the price.
#   widths         come from the AFM beside the font, not from the program.
#                  They are in the charstrings (hsbw), behind the encryption.
#   hinting, seac  never looked at - the bytes are passed through.
#

package require Tcl 8.6.11-
package require tclpdf::io 1.0-

namespace eval ::tclpdf::type1 {
  namespace export {[a-z]*}
  namespace ensemble create

  # WinAnsi position -> the glyph names that character may go by.
  #
  # SEVERAL names per position, not one, and that is the whole point: which
  # name a font actually carries differs between fonts, so the choice cannot
  # be made here - it is made per font, by taking the first name its metrics
  # know. tools/mkafm.tcl does the same for the standard fourteen, and taking
  # only the first AGL name would pick "nbspace" and "sfthyphen" where every
  # real AFM says "space" and "hyphen".
  #
  # Built from cp1252 - which is what WinAnsiEncoding is - through Adobe's
  # glyph list in tools/agl/glyphlist.txt. Two positions carry a name the AGL
  # does not give them: 160 and 173 use the glyphs of space and hyphen, as
  # ISO 32000-1 Annex D states for WinAnsiEncoding. Position 127 is dropped;
  # it is not a printable character.
  variable winAnsi {
    32 {space spacehackarabic} 33 {exclam} 34 {quotedbl} 35 {numbersign}
    36 {dollar} 37 {percent} 38 {ampersand} 39 {quotesingle} 40 {parenleft}
    41 {parenright} 42 {asterisk} 43 {plus} 44 {comma} 45 {hyphen}
    46 {period} 47 {slash} 48 {zero} 49 {one} 50 {two} 51 {three} 52 {four}
    53 {five} 54 {six} 55 {seven} 56 {eight} 57 {nine} 58 {colon}
    59 {semicolon} 60 {less} 61 {equal} 62 {greater} 63 {question} 64 {at}
    65 {A} 66 {B} 67 {C} 68 {D} 69 {E} 70 {F} 71 {G} 72 {H} 73 {I} 74 {J}
    75 {K} 76 {L} 77 {M} 78 {N} 79 {O} 80 {P} 81 {Q} 82 {R} 83 {S} 84 {T}
    85 {U} 86 {V} 87 {W} 88 {X} 89 {Y} 90 {Z} 91 {bracketleft}
    92 {backslash} 93 {bracketright} 94 {asciicircum} 95 {underscore}
    96 {grave} 97 {a} 98 {b} 99 {c} 100 {d} 101 {e} 102 {f} 103 {g} 104 {h}
    105 {i} 106 {j} 107 {k} 108 {l} 109 {m} 110 {n} 111 {o} 112 {p} 113 {q}
    114 {r} 115 {s} 116 {t} 117 {u} 118 {v} 119 {w} 120 {x} 121 {y} 122 {z}
    123 {braceleft} 124 {bar verticalbar} 125 {braceright} 126 {asciitilde}
    128 {Euro euro} 130 {quotesinglbase} 131 {florin}
    132 {quotedblbase} 133 {ellipsis} 134 {dagger} 135 {daggerdbl}
    136 {circumflex} 137 {perthousand} 138 {Scaron} 139 {guilsinglleft}
    140 {OE} 142 {Zcaron} 145 {quoteleft} 146 {quoteright}
    147 {quotedblleft} 148 {quotedblright} 149 {bullet} 150 {endash}
    151 {emdash} 152 {ilde tilde} 153 {trademark} 154 {scaron}
    155 {guilsinglright} 156 {oe} 158 {zcaron} 159 {Ydieresis}
    160 {space nbspace nonbreakingspace} 161 {exclamdown} 162 {cent}
    163 {sterling} 164 {currency} 165 {yen} 166 {brokenbar} 167 {section}
    168 {dieresis} 169 {copyright} 170 {ordfeminine} 171 {guillemotleft}
    172 {logicalnot} 173 {hyphen sfthyphen softhyphen} 174 {registered}
    175 {macron overscore} 176 {degree} 177 {plusminus} 178 {twosuperior}
    179 {threesuperior} 180 {acute} 181 {mu mu1} 182 {paragraph}
    183 {middot periodcentered} 184 {cedilla} 185 {onesuperior}
    186 {ordmasculine} 187 {guillemotright} 188 {onequarter} 189 {onehalf}
    190 {threequarters} 191 {questiondown} 192 {Agrave} 193 {Aacute}
    194 {Acircumflex} 195 {Atilde} 196 {Adieresis} 197 {Aring} 198 {AE}
    199 {Ccedilla} 200 {Egrave} 201 {Eacute} 202 {Ecircumflex}
    203 {Edieresis} 204 {Igrave} 205 {Iacute} 206 {Icircumflex}
    207 {Idieresis} 208 {Eth} 209 {Ntilde} 210 {Ograve} 211 {Oacute}
    212 {Ocircumflex} 213 {Otilde} 214 {Odieresis} 215 {multiply}
    216 {Oslash} 217 {Ugrave} 218 {Uacute} 219 {Ucircumflex}
    220 {Udieresis} 221 {Yacute} 222 {Thorn} 223 {germandbls} 224 {agrave}
    225 {aacute} 226 {acircumflex} 227 {atilde} 228 {adieresis} 229 {aring}
    230 {ae} 231 {ccedilla} 232 {egrave} 233 {eacute} 234 {ecircumflex}
    235 {edieresis} 236 {igrave} 237 {iacute} 238 {icircumflex}
    239 {idieresis} 240 {eth} 241 {ntilde} 242 {ograve} 243 {oacute}
    244 {ocircumflex} 245 {otilde} 246 {odieresis} 247 {divide}
    248 {oslash} 249 {ugrave} 250 {uacute} 251 {ucircumflex}
    252 {udieresis} 253 {yacute} 254 {thorn} 255 {ydieresis}
  }
}

# The glyph names this face is addressed by, per byte value: for each WinAnsi
# position the first candidate the metrics actually carry.
#
# This is the one place that decides a name, and [widths] below reads its
# answer rather than deciding again - two loops over the same table would be
# free to disagree, and a width that belongs to a different glyph than the one
# drawn is invisible in every check a PDF goes through.
proc ::tclpdf::type1::names {metrics} {
  variable winAnsi
  set known [dict get $metrics widths]
  set result {}
  foreach {code candidates} $winAnsi {
    foreach name $candidates {
      if {[dict exists $known $name]} {
        dict set result $code $name
        break
      }
    }
  }
  return $result
}

# The widths of a face by byte value under WinAnsiEncoding, as the 256-entry
# list the rest of the package measures with. An unmapped position holds 0,
# which is what [afm encodeWidths] reads as "this face cannot set that".
proc ::tclpdf::type1::widths {metrics} {
  set known [dict get $metrics widths]
  set list [lrepeat 256 0]
  foreach {code name} [names $metrics] {
    lset list $code [dict get $known $name]
  }
  return $list
}

# Read a font program and return the three pieces plus what the header says
# about the face.
proc ::tclpdf::type1::read {path} {
  return [parse [::tclpdf::io read $path]]
}

proc ::tclpdf::type1::parse {bytes} {
  if {[string length $bytes] < 64} {
    return -code error "tclpdf: not a Type 1 font program - too short"
  }
  # 0x80 introduces a PFB segment. Anything else has to start with the
  # PostScript magic, or this is not a Type 1 program at all.
  if {[string index $bytes 0] eq "\x80"} {
    set pieces [Segments $bytes]
  } elseif {[string range $bytes 0 15] eq "%!PS-AdobeFont-1"
      || [string range $bytes 0 13] eq "%!FontType1-1"} {
    set pieces [Boundaries $bytes]
  } else {
    binary scan [string range $bytes 0 3] H* signature
    return -code error "tclpdf: not a Type 1 font program (starts with\
        0x$signature) - .pfb, .pfa and .t1 are read here"
  }
  lassign $pieces clear encrypted trailer
  set font [dict create \
      clear $clear encrypted $encrypted trailer $trailer \
      length1 [string length $clear] \
      length2 [string length $encrypted] \
      length3 [string length $trailer]]
  return [dict merge $font [Header $clear]]
}

# The PFB container: a 6-byte marker before each piece - 0x80, the type, then
# the length as four bytes LITTLE-endian. Little, unlike everything else in a
# font file, because the format comes from the PC side.
proc ::tclpdf::type1::Segments {bytes} {
  set pieces {}
  set at 0
  set total [string length $bytes]
  while {$at + 2 <= $total} {
    binary scan $bytes @${at}cucu marker type
    if {$marker != 0x80} {
      return -code error "tclpdf: damaged PFB - expected a segment marker at\
          offset $at"
    }
    # Type 3 is "end of file" and carries no length.
    if {$type == 3} {
      break
    }
    if {$type != 1 && $type != 2} {
      return -code error "tclpdf: damaged PFB - unknown segment type $type"
    }
    binary scan $bytes @[expr {$at + 2}]iu length
    set start [expr {$at + 6}]
    if {$start + $length > $total} {
      return -code error "tclpdf: damaged PFB - a segment reaches past the\
          end of the file"
    }
    lappend pieces [string range $bytes $start [expr {$start + $length - 1}]]
    set at [expr {$start + $length}]
  }
  # Some writers split the encrypted part over several segments. Joining
  # neighbours of the same kind is what the format intends, and the three
  # pieces PDF wants are clear, encrypted, clear.
  if {[llength $pieces] < 3} {
    return -code error "tclpdf: damaged PFB - [llength $pieces] segments,\
        three are needed"
  }
  if {[llength $pieces] > 3} {
    set pieces [list [lindex $pieces 0] \
        [join [lrange $pieces 1 end-1] {}] [lindex $pieces end]]
  }
  return $pieces
}

# The raw container: no markers, so the two boundaries are read off the
# content. Both are unambiguous and neither is a guess.
proc ::tclpdf::type1::Boundaries {bytes} {
  # The clear part ends after the "eexec" line - the token plus whatever ends
  # that line. Measured: .pfb writes \n here, the URW .t1 files write \r, and
  # a file with \r\n exists as well, so the end of the line is walked rather
  # than assumed.
  set eexec [string first "eexec" $bytes]
  if {$eexec < 0} {
    return -code error "tclpdf: not a Type 1 font program - no eexec"
  }
  set at [expr {$eexec + 5}]
  # Exactly the line ending and nothing more: CR, LF or CRLF. Not "skip all
  # whitespace" - the encrypted bytes that follow are random and may well
  # begin with 0x20 or 0x0A, and swallowing one would shift the whole
  # encrypted part.
  #
  # It has to be taken along, though: a PFB counts it into Length1, and the
  # two containers have to arrive at the same three lengths for the same face.
  # Written as two ifs rather than a membership test - "\r \n \t" is an EMPTY
  # list to Tcl, because those characters are themselves list separators, so
  # that test never matched and the line ending silently stayed on the wrong
  # side.
  if {[string index $bytes $at] eq "\r"} {
    incr at
  }
  if {[string index $bytes $at] eq "\n"} {
    incr at
  }
  set clear [string range $bytes 0 [expr {$at - 1}]]

  # The trailer is the 512 zeros and what follows them. They are written as
  # ASCII "0" in lines, so the first run of 64 is the start of the block -
  # a run that long cannot occur inside encrypted binary by accident, and
  # "cleartomark" behind it confirms it.
  set zeros [string first [string repeat 0 64] $bytes]
  if {$zeros < 0 || [string first "cleartomark" $bytes] < $zeros} {
    return -code error "tclpdf: damaged Type 1 program - no closing block of\
        zeros before cleartomark"
  }
  return [list $clear \
      [string range $bytes $at [expr {$zeros - 1}]] \
      [string range $bytes $zeros end]]
}

# What the header says about the face. Everything here is optional in the
# sense that a font may omit it; what a PDF descriptor needs and the file does
# not give, the caller fills from the metrics.
proc ::tclpdf::type1::Header {clear} {
  set header [dict create name {} family {} bbox {} italicAngle 0 \
      version {} encoding {}]
  if {[regexp {/FontName\s*/([^\s/]+)} $clear -> value]} {
    dict set header name $value
  }
  if {[regexp {/FamilyName\s*\(([^)]*)\)} $clear -> value]} {
    dict set header family $value
  }
  # The pattern stops at the numbers and never mentions the closing brace: a
  # brace inside a braced word is counted by Tcl whether it is escaped or not,
  # and the procedure body would end in the middle of the regular expression.
  if {[regexp {/FontBBox\s*\{\s*([-0-9. ]+)} $clear -> value]} {
    dict set header bbox [lmap number $value {expr {int($number)}}]
  }
  if {[regexp {/ItalicAngle\s*(-?[0-9.]+)} $clear -> value]} {
    dict set header italicAngle $value
  }
  if {[regexp {/version\s*\(([^)]*)\)} $clear -> value]} {
    dict set header version $value
  }
  # StandardEncoding means the font makes no claim of its own and the
  # document decides; anything else is a built-in encoding this module does
  # not read, and the AFM names are used instead.
  if {[regexp {/Encoding\s+(\S+)} $clear -> value]} {
    dict set header encoding $value
  }
  return $header
}

# The metrics beside the program. An AFM is a plain text file and only two of
# its sections matter here: the per-character metrics and the header values a
# font descriptor needs.
proc ::tclpdf::type1::metrics {path} {
  set text [::tclpdf::io read $path]
  set metrics [dict create name {} family {} bbox {} italicAngle 0 \
      ascender {} descender {} capHeight {} xHeight {} stemV {} \
      widths {} codes {} fixedPitch 0]
  set inChars 0
  foreach line [split $text \n] {
    set line [string trim $line]
    if {$line eq "StartCharMetrics" || [string match "StartCharMetrics *" $line]} {
      set inChars 1
      continue
    }
    if {$line eq "EndCharMetrics"} {
      set inChars 0
      continue
    }
    if {$inChars} {
      # C 32 ; WX 600 ; N space ; B 0 0 0 0 ;
      # The code may be -1, which means the glyph is in the font but not in
      # its default encoding - it still has a width and a name, and a
      # /Differences array can reach it.
      set code -1
      set width {}
      set name {}
      foreach field [split $line \;] {
        set field [string trim $field]
        if {[regexp {^C\s+(-?\d+)$} $field -> value]} {
          set code $value
        } elseif {[regexp {^WX\s+(-?[0-9.]+)$} $field -> value]} {
          set width $value
        } elseif {[regexp {^N\s+(\S+)$} $field -> value]} {
          set name $value
        }
      }
      if {$name ne {} && $width ne {}} {
        dict set metrics widths $name [expr {int($width)}]
        if {$code >= 0} {
          dict set metrics codes $code $name
        }
      }
      continue
    }
    if {[regexp {^FontName\s+(\S+)} $line -> value]} {
      dict set metrics name $value
    } elseif {[regexp {^FamilyName\s+(.+)} $line -> value]} {
      dict set metrics family [string trim $value]
    } elseif {[regexp {^FontBBox\s+(.+)} $line -> value]} {
      dict set metrics bbox [lmap number [string trim $value] {
        expr {int($number)}
      }]
    } elseif {[regexp {^ItalicAngle\s+(-?[0-9.]+)} $line -> value]} {
      dict set metrics italicAngle $value
    } elseif {[regexp {^Ascender\s+(-?[0-9.]+)} $line -> value]} {
      dict set metrics ascender [expr {int($value)}]
    } elseif {[regexp {^Descender\s+(-?[0-9.]+)} $line -> value]} {
      dict set metrics descender [expr {int($value)}]
    } elseif {[regexp {^CapHeight\s+(-?[0-9.]+)} $line -> value]} {
      dict set metrics capHeight [expr {int($value)}]
    } elseif {[regexp {^XHeight\s+(-?[0-9.]+)} $line -> value]} {
      dict set metrics xHeight [expr {int($value)}]
    } elseif {[regexp {^StdVW\s+(-?[0-9.]+)} $line -> value]} {
      dict set metrics stemV [expr {int($value)}]
    } elseif {[regexp {^IsFixedPitch\s+(\S+)} $line -> value]} {
      dict set metrics fixedPitch [expr {$value eq "true"}]
    }
  }
  if {![dict size [dict get $metrics widths]]} {
    return -code error "tclpdf: no character metrics in \"$path\" - is this\
        an AFM file?"
  }
  return $metrics
}

package provide tclpdf::type1 1.0
