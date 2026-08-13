#
# tclpdf - PDF generation for Tcl
#
# color - colour spaces and colour names (8.6)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The name table below is the reason this module exists as its own file. The
# convenient way to resolve "steelblue" is [winfo rgb . steelblue] - and that
# pulls in Tk and with it a display connection, so the package would stop
# loading in a CGI or batch context. pdf4tcl takes that route (line 2861); we
# do not. The table is 148 entries and costs nothing at load time.
#
# DeviceCMYK carries a caveat worth knowing: the conversion is not
# colorimetric, and combined with an sRGB output intent it is a PDF/A risk.
# It is offered because 23.1 % of the measured corpus uses it, not because it
# is the better choice for screen output.
#

package require Tcl 8.6.11-
package require tclpdf::pdfObj 1.0-

namespace eval ::tclpdf::color {
  namespace export {[a-z]*}
  namespace ensemble create

  # The CSS/X11 names, the set every designer and every stylesheet expects.
  variable names {
    aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4
    azure f0ffff beige f5f5dc bisque ffe4c4 black 000000
    blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a
    burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e
    coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c
    cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b
    darkgray a9a9a9 darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b
    darkmagenta 8b008b darkolivegreen 556b2f darkorange ff8c00
    darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f
    darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f
    darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493
    deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff
    firebrick b22222 floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff
    gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 goldenrod daa520
    gray 808080 green 008000 greenyellow adff2f grey 808080
    honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082
    ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5
    lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080
    lightcyan e0ffff lightgoldenrodyellow fafad2 lightgray d3d3d3
    lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 lightsalmon ffa07a
    lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899
    lightslategrey 778899 lightsteelblue b0c4de lightyellow ffffe0
    lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff
    maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd
    mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371
    mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc
    mediumvioletred c71585 midnightblue 191970 mintcream f5fffa
    mistyrose ffe4e1 moccasin ffe4b5 navajowhite ffdead navy 000080
    oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500
    orangered ff4500 orchid da70d6 palegoldenrod eee8aa palegreen 98fb98
    paleturquoise afeeee palevioletred db7093 papayawhip ffefd5
    peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd
    powderblue b0e0e6 purple 800080 rebeccapurple 663399 red ff0000
    rosybrown bc8f8f royalblue 4169e1 saddlebrown 8b4513 salmon fa8072
    sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d
    silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090
    slategrey 708090 snow fffafa springgreen 00ff7f steelblue 4682b4
    tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347
    turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff
    whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32
  }
}

# Resolve a colour specification into a canonical {space values} pair.
#
# Accepted forms, in the order they are tried:
#
#   #rgb / #rrggbb        hexadecimal, the CSS spelling
#   steelblue             a name from the table above
#   0.5                   one number: grey
#   {r g b}               three numbers: RGB
#   {c m y k}             four numbers: CMYK
#   {gray 0.5}            explicit, and the only way to be sure
#   {rgb 1 0 0}
#   {cmyk 0 1 1 0}
#   {separation Name alternateSpace tint}
#
# Components are 0..1, not 0..255. That is the PDF convention and mixing the
# two is the classic source of a picture that comes out white.
proc ::tclpdf::color::parse {spec} {
  variable names

  if {[llength $spec] == 1} {
    set single [lindex $spec 0]
    if {[string index $single 0] eq "#"} {
      return [list rgb [Hex [string range $single 1 end]]]
    }
    if {[string is double -strict $single]} {
      return [list gray [list [Clamp $single]]]
    }
    set key [string tolower $single]
    if {[dict exists $names $key]} {
      return [list rgb [Hex [dict get $names $key]]]
    }
    return -code error "tclpdf: unknown colour \"$single\""
  }

  set head [string tolower [lindex $spec 0]]
  switch -- $head {
    gray - grey {
      return [list gray [Components gray [lrange $spec 1 end] 1]]
    }
    rgb {
      return [list rgb [Components rgb [lrange $spec 1 end] 3]]
    }
    cmyk {
      return [list cmyk [Components cmyk [lrange $spec 1 end] 4]]
    }
    separation {
      # {separation Name alternate tint} - the alternate space is what a
      # reader falls back to when it cannot render the spot colour itself.
      lassign $spec -> separationName alternate tint
      if {$tint eq {}} {
        set tint 1
      }
      return [list separation [list $separationName [parse $alternate] [Clamp $tint]]]
    }
    pattern {
      # {pattern Name} - a tiling or shading pattern standing in for a
      # colour (8.7.3.1). The name is the RESOURCE name; translating a
      # caller's alias into it is the document's job, not this module's.
      return [list pattern [list [lindex $spec 1]]]
    }
  }

  # No keyword: decide by the number of components.
  switch -- [llength $spec] {
    3 {
      return [list rgb [lmap value $spec {Clamp $value}]]
    }
    4 {
      return [list cmyk [lmap value $spec {Clamp $value}]]
    }
  }
  return -code error "tclpdf: cannot read colour \"$spec\""
}

# The content stream operator for a parsed colour. "fill" and "stroke" differ
# only in case, which is exactly why they are generated rather than typed.
proc ::tclpdf::color::operator {parsed {which fill}} {
  lassign $parsed space values
  if {$which ni {fill stroke}} {
    return -code error "tclpdf: colour target must be fill or stroke, not \"$which\""
  }
  # A pattern has no component values at all, so it is answered before the
  # numbers are formatted - running a resource NAME through [num] would throw.
  if {$space eq "pattern"} {
    set marker [expr {$which eq "stroke" ? "CS" : "cs"}]
    set code [expr {$which eq "stroke" ? "SCN" : "scn"}]
    return "/Pattern $marker\n[::tclpdf::pdfObj name [lindex $values 0]] $code"
  }
  set numbers [join [lmap value [Numbers $space $values] {::tclpdf::pdfObj num $value}] " "]
  switch -- $space {
    gray {set code g}
    rgb {set code rg}
    cmyk {set code k}
    separation {
      # The name refers to a resource entry the document has to provide; this
      # module only produces the operator.
      lassign $values separationName alternate tint
      set code scn
      set prefix "[::tclpdf::pdfObj name $separationName] cs"
      if {$which eq "stroke"} {
        set prefix "[::tclpdf::pdfObj name $separationName] CS"
        set code SCN
      }
      return "$prefix\n[::tclpdf::pdfObj num $tint] $code"
    }
    default {
      return -code error "tclpdf: unknown colour space \"$space\""
    }
  }
  if {$which eq "stroke"} {
    set code [string toupper $code]
  }
  return "$numbers $code"
}

# The name of the colour space as it appears in a resource dictionary.
proc ::tclpdf::color::space {parsed} {
  switch -- [lindex $parsed 0] {
    gray {return DeviceGray}
    rgb {return DeviceRGB}
    cmyk {return DeviceCMYK}
    separation {return Separation}
    pattern {return Pattern}
  }
  return -code error "tclpdf: unknown colour space \"[lindex $parsed 0]\""
}

# The component values of a parsed colour, without the space.
proc ::tclpdf::color::Numbers {space values} {
  if {$space eq "separation"} {
    return [list [lindex $values 2]]
  }
  return $values
}

# Split a hexadecimal colour into components. Three digits are the shorthand
# in which each digit is doubled - "#f0a" is "#ff00aa", not "#f00a00".
proc ::tclpdf::color::Hex {hex} {
  set hex [string trim $hex]
  if {[string length $hex] == 3} {
    set expanded {}
    foreach digit [split $hex {}] {
      append expanded $digit $digit
    }
    set hex $expanded
  }
  if {![regexp {^[0-9a-fA-F]{6}$} $hex]} {
    return -code error "tclpdf: not a hexadecimal colour: \"$hex\""
  }
  set result {}
  foreach {high low} [split $hex {}] {
    # Divided by 255, not by 256: ff has to become exactly 1.0.
    lappend result [expr {[scan $high$low %x] / 255.0}]
  }
  return $result
}

# Exactly as many components as the space has, clamped.
#
# The count is checked rather than trusted. A short list used to be accepted
# and produced an operator with too few operands - "1 0 rg" instead of
# "1 0 0 rg" - which is invalid by 8.6.8 but raises no error anywhere: not in
# this package, not in qpdf, not in a validator. The page simply renders in the
# wrong colour or not at all. A surplus component was dropped just as quietly,
# so {rgb 1 0 0 0} looked like it worked and meant something else.
proc ::tclpdf::color::Components {space values count} {
  if {[llength $values] != $count} {
    return -code error "tclpdf: $space needs exactly $count component[expr\
        {$count == 1 ? {} : {s}}], got [llength $values]: \"$values\""
  }
  return [lmap value $values {Clamp $value}]
}

# Components outside 0..1 are clamped rather than refused: a rounding error in
# a calculated colour should not abort a document.
proc ::tclpdf::color::Clamp {value} {
  if {![string is double -strict $value]} {
    return -code error "tclpdf: colour component is not a number: \"$value\""
  }
  if {$value < 0} {
    return 0
  }
  if {$value > 1} {
    return 1
  }
  return $value
}

package provide tclpdf::color 1.0
