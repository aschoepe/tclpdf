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
# -- how a Lab colour is spelled, and why (8.6.5.4) -------------------------
#
# {lab 53.2 80.1 67.2} - three numbers, like {rgb ...} and {cmyk ...}, and
# the two parameters of the SPACE as options behind them:
#
#     {lab L a b ?-whitePoint {Xw Yw Zw}? ?-range {amin amax bmin bmax}?}
#
# Three reasons for that shape rather than a registration call of its own:
#
#   - A Lab colour is a colour, not a resource. The alternative would have
#     been [lab define alias ...] plus {lab alias L a b}, the road [icc
#     embed] takes - but a profile is a FILE the caller has to hand over
#     once, while a Lab space is two short arrays with defaults that cover
#     nearly every use. A registration for something nobody has to configure
#     is ceremony.
#   - The values are what a caller has. A spot colour arrives as three
#     numbers out of a colour book or a measurement, and the whole point of
#     this posting is that a catalogue of such numbers is NOT shipped: the
#     explicit way in has to be the short one.
#   - The two options are only ever the space, never the colour, so no
#     component can be mistaken for one - and a* is routinely negative,
#     which is why the components are the first THREE words and the options
#     start after them rather than at the first leading dash.
#
# The resource name of the space is derived from its parameters, not counted
# up: [operator] gets nothing but the colour and has to name the same
# resource that [LabColourUsed] registered. The default space is "Lab", any
# other one "Lab" and eight hexadecimal digits over its parameters - which is
# why neither a separation nor an ICC alias may take those names.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::io 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

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

  # The two parameters of a Lab colour space, and the values a colour that
  # names neither of them gets (8.6.5.4, Table 64 - the table is numbered 64
  # in ISO 32000-2:2020, not 65).
  #
  # WhitePoint is REQUIRED by the table and constrained by it: "The numbers
  # XW and ZW shall be positive, and YW shall be 1.0." There is no default in
  # the standard, so this one is a decision, and it is D50 - the illuminant
  # of the ICC profile connection space, and the one every printed colour is
  # measured under (ISO 13655). Lab values for a spot colour come out of a
  # colour book or off a spectrophotometer, and both are D50; a D65 white
  # point would silently shift every one of them. The example in 8.6.5.4
  # writes the D65 point [0.9505 1.00 1.0890] instead, which is the right
  # default for a colour converted from sRGB - hence -whitePoint.
  #
  # Range is optional and its default is the standard's own: "Default value:
  # [-100 100 -100 100]". The wider [-128 127 -128 127] of the example in
  # 8.6.5.4 is the usual choice in prepress, and -range takes it; what is not
  # done is quietly widening the default, because a value outside Range is
  # clamped rather than refused ("Component values falling outside the
  # specified range shall be adjusted to the nearest valid value without
  # error indication") and a caller who never said -range should get the
  # range the standard says they get.
  #
  # Both are written in the form [Double] produces, decimal point and all:
  # the default space is recognised by comparing the two lists as strings
  # (see [labResource]), and {-100 100 -100 100} typed as -range would
  # otherwise be a second space with the same numbers in it.
  variable labWhitePoint {0.9642 1.0 0.8249}
  variable labRange {-100.0 100.0 -100.0 100.0}
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
#   {icc alias components...}
#   {lab 53.2 80.1 67.2}  and the space's own -whitePoint / -range
#
# Components are 0..1, not 0..255. That is the PDF convention and mixing the
# two is the classic source of a picture that comes out white.
proc ::tclpdf::color::parse {spec} {
  variable names

  if {[llength $spec] == 1} {
    set single [lindex $spec 0]
    if {[string index $single 0] eq "#"} {
      return [Achromatic [Hex [string range $single 1 end]]]
    }
    if {[string is double -strict $single]} {
      return [list gray [list [Clamp $single]]]
    }
    set key [string tolower $single]
    if {[dict exists $names $key]} {
      return [Achromatic [Hex [dict get $names $key]]]
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
      #
      # The name is a colourant and has to name one: empty, it went out as
      # "/ cs" until 2026-08-18, a name of nothing. All and None are the
      # two special colourants of 8.6.6.4 - every plate, and no plate - and
      # are written as they stand: [/Separation /All ...] is exactly what
      # the norm defines for a registration mark, and nothing here has to
      # know it is special.
      lassign $spec -> separationName alternate tint
      if {$separationName eq {}} {
        return -code error "tclpdf: a separation needs a name -\
            {separation Name alternate ?tint?}"
      }
      # The alternate is a device or CIE-based space (8.6.6.4: "the alternate
      # colour space, which may be any device or CIE-based colour space but
      # may not be another special colour space (Pattern, Indexed,
      # Separation, or DeviceN)"): a separation, a pattern, an indexed space
      # cannot stand in. Refused here, before anything is recorded - a
      # separation over a separation used to be recorded as a use of the
      # colour space "Separation" and die a line later, looking up its
      # "no ink" colour.
      #
      # Lab is admitted since 2026-08-21 and is the reason the whole space
      # exists here: a spot colour is specified to the press as Lab, not as
      # a CMYK approximation. ICCBased is not - it would be legal by 8.6.6.4,
      # but the tint transform would then have to know the profile's
      # component count and its "no ink", which is the profile's business
      # and not this module's.
      set parsedAlternate [parse $alternate]
      if {[lindex $parsedAlternate 0] ni {gray rgb cmyk lab}} {
        return -code error "tclpdf: the alternate of separation\
            \"$separationName\" is a device or CIE-based colour - grey, RGB,\
            CMYK or Lab - not {$alternate} (ISO 32000-1, 8.6.6.4)"
      }
      if {$tint eq {}} {
        set tint 1
      }
      return [list separation [list $separationName $parsedAlternate [Clamp $tint]]]
    }
    pattern {
      # {pattern Name} - a tiling or shading pattern standing in for a
      # colour (8.7.3.1). The name is the RESOURCE name; translating a
      # caller's alias into it is the document's job, not this module's.
      return [list pattern [list [lindex $spec 1]]]
    }
    icc {
      # {icc alias components...} - a colour in an ICC based space
      # (8.6.5.5). The alias names a profile registered with [icc embed];
      # how many components follow is that profile's business, and it is
      # checked where the profile is known - in [ColourUsed] below. The
      # values are clamped here like every other component.
      set alias [lindex $spec 1]
      if {$alias eq {}} {
        return -code error "tclpdf: an ICC colour needs the alias of an\
            embedded profile - {icc alias components...}"
      }
      return [list icc [list $alias \
          [lmap value [lrange $spec 2 end] {Clamp $value}]]]
    }
    lab {
      # {lab L a b ?-whitePoint {Xw Yw Zw}? ?-range {amin amax bmin bmax}?} -
      # a colour in a CIE 1976 L*a*b* space (8.6.5.4). Why the components
      # come first and the space follows as options is argued at the head of
      # this file.
      return [list lab [LabColour [lrange $spec 1 end]]]
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
      # The name refers to a resource entry the document provides through
      # [ColourUsed] below; this proc only produces the operator.
      lassign $values separationName alternate tint
      set code scn
      set prefix "[::tclpdf::pdfObj name $separationName] cs"
      if {$which eq "stroke"} {
        set prefix "[::tclpdf::pdfObj name $separationName] CS"
        set code SCN
      }
      return "$prefix\n[::tclpdf::pdfObj num $tint] $code"
    }
    icc - lab {
      # Like a separation: a resource entry [ColourUsed] provides, followed
      # by the components in that space. The entry is named by the caller
      # for a profile - the alias - and derived from the space's own
      # parameters for Lab, because [operator] is handed the colour and
      # nothing else and still has to hit the name that was registered.
      set entry [expr {$space eq "icc" ? [lindex $values 0] : [labResource $values]}]
      set marker [expr {$which eq "stroke" ? "CS" : "cs"}]
      set code [expr {$which eq "stroke" ? "SCN" : "scn"}]
      return "[::tclpdf::pdfObj name $entry] $marker\n$numbers $code"
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

# -- what the document does with a colour ---------------------------------
#
# Two things, and both are the document's business rather than the parser's,
# because both need the writer, the resources or the page: the record of
# which colour SPACES the document uses, and the object behind a separation.
#
# The record exists for PDF/A. ISO 19005-2, 6.2.4.3 admits DeviceRGB only
# under an RGB output intent and DeviceCMYK only under a CMYK one (DeviceGray
# under any), and 6.2.4.4 holds the alternate of a separation to the same
# rule - measured with veraPDF 1.30.2 over every road a colour takes in this
# package: fill and stroke, text, a picture's colour space, an Indexed base,
# a shading, a tiling pattern's content, a form's content, a separation's
# alternate. Every one of them fails the same clause under the wrong intent,
# and every one passes under the right one. The record is kept whether or not
# [pdfa] is ever declared, because the declaration may come after the
# drawing; pdfa.tcl judges it at write time. The facts are established here,
# where the colour goes through, and judged there - the same division as
# [fontsWithoutProgram] and [undescribedGraphics].
#
# "/Varnish cs 1 scn" names a resource, and until 2026-08-16 nothing wrote
# it: the operator went out, no [/Separation ...] object and no /ColorSpace
# entry ever existed, and poppler answered "Bad color space 'Varnish'" -
# measured on the shipped colour example, where it had been since the first
# check-in. The operator is still made by [operator] above; what the document
# has to add is the object the name points at (8.6.6.4).

oo::define ::tclpdf::document::document {

  # A colour is about to be painted: record its space, register its
  # separation if it is one, and hand the specification back unchanged - so
  # a caller can wrap it around whatever it was going to parse. Every module
  # that turns a colour into an operator routes it through here, which is
  # what makes a text in a spot colour work as well as a rectangle, and what
  # makes the record complete. "what" names the call for the record: "rect",
  # "text", "svg" - the word a refusal will use.
  #
  # A pattern is not a colour and carries no space of its own; whatever its
  # tile or shading paints was recorded when the pattern was made.
  #
  # The separation object is [/Separation /Name alternate tintTransform]: the
  # alternate is the device space of the colour given, the transform a type
  # 2 function from tint 0 to tint 1. Tint 0 is NO ink - and what "no ink"
  # looks like depends on the alternate: 0 0 0 0 in CMYK, but 1 1 1 in RGB
  # and 1 in grey, because those two count light, not ink. Get that wrong and
  # a light tint of a varnish comes out as a dark grey.
  method ColourUsed {spec what} {
    set parsed [::tclpdf::color parse $spec]
    if {[lindex $parsed 0] eq "pattern"} {
      return $spec
    }
    if {[lindex $parsed 0] eq "icc"} {
      return [my IccColourUsed $parsed $what $spec]
    }
    if {[lindex $parsed 0] eq "lab"} {
      return [my LabColourUsed $parsed $what $spec]
    }
    if {[lindex $parsed 0] ne "separation"} {
      my ColourSpaceUsed [::tclpdf::color space $parsed] $what
      return $spec
    }
    lassign [lindex $parsed 1] name alternate tint
    # Some names never refer to the ColorSpace resources (8.6.8, cs): a
    # separation called Pattern would write "/Pattern cs" and mean the
    # pattern space, silently, and one called Lab would take the entry a Lab
    # colour paints through.
    if {[set why [::tclpdf::color::Reserved $name]] ne {}} {
      return -code error "tclpdf: \"$name\" cannot be the name of a\
          separation - $why"
    }
    # Separations and ICC profiles share the ColorSpace resource dictionary,
    # so one name cannot be both - the second definition would silently
    # shadow the first in every "cs" that follows. The mirror check sits in
    # [IccEmbed].
    if {[dict exists [my state iccProfiles] $name]} {
      return -code error "tclpdf: \"$name\" already names an ICC profile -\
          a separation cannot reuse it"
    }
    lassign $alternate space components
    set known [my state separations]
    # One name, one plate: the same name with another alternate would be
    # a second object under the first one's resource entry, and PDF/A-2
    # 6.2.4.4 forbids two definitions of one separation outright. Checked
    # before anything is recorded: a refused redefinition must leave no
    # record and no version floor.
    if {[dict exists $known $name] && [dict get $known $name] ne $alternate} {
      return -code error "tclpdf: separation \"$name\" is already defined\
          with the alternate {[join [dict get $known $name]]} - one name,\
          one alternate colour"
    }
    # The Separation colour space is PDF 1.2 (Reference 1.7, Table 4.12) -
    # past the last refusal, before the record and the objects, the same
    # order as [IccColourUsed] below.
    my RequireVersion 1.2 "a separation colour"
    # The alternate is what a reader without the plate paints, so it counts
    # as a use of that space (ISO 19005-2, 6.2.4.4) - and it is recorded
    # under the separation's name, because that is the colour the caller
    # wrote and has to change. A Lab alternate is an ARRAY rather than a
    # family name, so the record is named here; [space] refuses it on
    # purpose, see there.
    my ColourSpaceUsed [expr {$space eq "lab" ? "Lab" :
        [::tclpdf::color space $alternate]}] "separation \"$name\" in $what"
    if {[dict exists $known $name]} {
      return $spec
    }
    # The tint transform, and the alternate as it stands in the Separation
    # array. A Lab alternate differs in three ways and in no other: tint 0 is
    # L* 100 - paper, not ink, and not the {0 0 0} that would print a light
    # tint of a spot colour black; the alternate is an object, shared with
    # any Lab colour of the same space; and the function says its /Range,
    # because Lab values leave 0..1 and a reader clipping to the function's
    # implicit range would flatten the colour.
    set pairs [list FunctionType 2 Domain [::tclpdf::pdfObj arr {0 1}]]
    if {$space eq "lab"} {
      lassign $components values whitePoint range
      set none {100 0 0}
      set alternateSpace [[my writer] ref [my LabSpaceObject $whitePoint $range]]
      set tail [list N 1 Range [::tclpdf::pdfObj arr \
          [lmap value [list 0 100 {*}$range] {::tclpdf::pdfObj num $value}]]]
    } else {
      set none [dict get {gray 1 rgb {1 1 1} cmyk {0 0 0 0}} $space]
      set values $components
      set alternateSpace /[::tclpdf::color space $alternate]
      set tail {N 1}
    }
    lappend pairs C0 [::tclpdf::pdfObj arr $none] \
        C1 [::tclpdf::pdfObj arr [lmap value $values {::tclpdf::pdfObj num $value}]] \
        {*}$tail
    set function [[my writer] add [::tclpdf::pdfObj dictionary $pairs]]
    set object [[my writer] add [::tclpdf::pdfObj arr [list /Separation \
        [::tclpdf::pdfObj name $name] $alternateSpace \
        [[my writer] ref $function]]]]
    # Under the separation's own name: that is what [operator] writes after
    # "cs", and the resource dictionary escapes it the same way.
    my resource ColorSpace $name [[my writer] ref $object]
    dict set known $name $alternate
    my state separations $known
    return $spec
  }

  # -- ICC based colour spaces (8.6.5.5) ----------------------------------
  #
  # An ICCBased space is a stream holding the profile, with /N for the
  # component count - the space every colour-managed workflow hands around,
  # and by count the most common colour space in foreign PDFs measured
  # (302 of 539 documents). Because it is anchored to a profile rather than
  # to the device, it is admissible under EVERY PDF/A output intent -
  # measured with veraPDF 1.30.2: an ICC sRGB fill passes 3B under a CMYK
  # intent where the same colour as DeviceRGB fails 6.2.4.3 - which is why
  # it is recorded under its own name and the intent check leaves it alone.

  # $doc icc embed <alias> <path>    register a profile under an alias
  # $doc icc names                   the aliases registered so far
  #
  # After [icc embed press ISOcoated.icc], {icc press 0 1 1 0} is a colour
  # wherever one is taken: fill, stroke, text. The registration only reads
  # and checks the profile; objects are written on first use, the rule
  # [font embed] and [image embed] follow.
  method icc {subcommand args} {
    switch -- $subcommand {
      embed {return [my IccEmbed {*}$args]}
      names {return [dict keys [my state iccProfiles]]}
      default {
        return -code error "tclpdf: unknown icc subcommand \"$subcommand\" -\
            known are: embed, names"
      }
    }
  }

  # Register a profile. Everything here is a CHECK - a refused call leaves
  # no state - and the header is read by the one ICC reader this package
  # has, the same one the output intent uses (pdfa.tcl), so the two cannot
  # disagree about what a profile describes.
  method IccEmbed {alias path} {
    if {$alias eq {}} {
      return -code error "tclpdf: icc embed needs an alias and a file name"
    }
    # The same reserved names as a separation, for the same reason: an alias
    # called Pattern would write "/Pattern cs" and mean the pattern space,
    # silently, and one called Lab would collide with a Lab colour's entry.
    if {[set why [::tclpdf::color::Reserved $alias]] ne {}} {
      return -code error "tclpdf: \"$alias\" cannot be the alias of an ICC\
          profile - $why"
    }
    set known [my state iccProfiles]
    if {[dict exists $known $alias]} {
      return -code error "tclpdf: an ICC profile named \"$alias\" is already\
          embedded"
    }
    if {[dict exists [my state separations] $alias]} {
      return -code error "tclpdf: \"$alias\" already names a separation - an\
          ICC profile cannot reuse it"
    }
    set bytes [::tclpdf::io read $path]
    lassign [my IccInspect $bytes "\"$path\""] space components
    dict set known $alias [dict create path [file normalize $path] \
        bytes $bytes space $space components $components object {}]
    my state iccProfiles $known
    return $alias
  }

  # The worker behind an {icc ...} colour in [ColourUsed]: check, record,
  # and write the objects once. Everything that can be refused is refused
  # before the record and before the first object - a rejected colour must
  # leave neither.
  method IccColourUsed {parsed what spec} {
    lassign [lindex $parsed 1] alias values
    set known [my state iccProfiles]
    if {![dict exists $known $alias]} {
      set hint ""
      if {[llength [dict keys $known]]} {
        set hint " - known are: [join [dict keys $known] {, }]"
      }
      return -code error "tclpdf: no ICC profile named \"$alias\" - register\
          it with \"icc embed\" first$hint"
    }
    set profile [dict get $known $alias]
    if {[llength $values] != [dict get $profile components]} {
      return -code error "tclpdf: \"$alias\" is a [dict get $profile space]\
          profile and takes [dict get $profile components] component[expr\
          {[dict get $profile components] == 1 ? {} : {s}}], got\
          [llength $values]: \"$values\""
    }
    # ICCBased is PDF 1.3 (Reference 1.7, 4.5.4) - said before anything is
    # written or recorded.
    my RequireVersion 1.3 "an ICC based colour"
    my ColourSpaceUsed ICCBased "icc \"$alias\" in $what"
    if {[dict get $profile object] eq {}} {
      set stream [my IccProfileObject [dict get $profile bytes] \
          [dict get $profile components]]
      set object [[my writer] add [::tclpdf::pdfObj arr \
          [list /ICCBased [[my writer] ref $stream]]]]
      # Under the alias: that is what [operator] writes after "cs", and the
      # resource dictionary escapes it the same way.
      my resource ColorSpace $alias [[my writer] ref $object]
      dict set known $alias object $object
      my state iccProfiles $known
    }
    return $spec
  }

  # Read an ICC profile header: {GRAY 1}, {RGB 3} or {CMYK 4}, or an error
  # naming what is wrong. The reader sits in this module because colour is
  # what it is about; it used to live in pdfa.tcl, and an ICC colour then
  # loaded the PDF/A machinery and tdom with it.
  method IccInspect {bytes what} {
    return [::tclpdf::color::iccSpace $bytes $what]
  }

  # The stream object of a profile, written ONCE per document however many
  # roads it arrives by: a registered colour space, a picture's embedded
  # profile, the PDF/A output intent - pdfa.tcl asks here before writing its
  # own. Keyed by the bytes, not by a path, because a picture's profile
  # never had one; on the freak chance of a digest collision the bytes are
  # compared and a second stream is simply written.
  method IccProfileObject {bytes components} {
    set streams [my state iccStreams]
    set digest "[string length $bytes]:[zlib crc32 $bytes]"
    if {[dict exists $streams $digest]
        && [lindex [dict get $streams $digest] 1] eq $bytes} {
      return [lindex [dict get $streams $digest] 0]
    }
    set number [my streamObject [list N $components] $bytes]
    dict set streams $digest [list $number $bytes]
    my state iccStreams $streams
    return $number
  }

  # -- Lab colour spaces (8.6.5.4) ----------------------------------------
  #
  # A Lab space is [/Lab << /WhitePoint [...] /Range [...] >>] and holds no
  # data of its own, which is what makes it the space prepress asks for: a
  # spot colour is handed to the press as three measured numbers, and a
  # colour catalogue is deliberately not shipped here (the data is
  # licensed), so the explicit road has to be open. Like ICCBased and unlike
  # the device spaces it is anchored to a white point rather than to a
  # device, so PDF/A admits it under every output intent - measured with
  # veraPDF 1.30.2, see [PdfaCheckColour] in pdfa.tcl.

  # The worker behind a {lab ...} colour in [ColourUsed]. Nothing here can be
  # refused - [parse] has checked the white point, the range and the count -
  # so the order is only version, record, objects.
  method LabColourUsed {parsed what spec} {
    lassign [lindex $parsed 1] - whitePoint range
    # "PDF 1.1 supports three CIE-based colour space families, named
    # CalGray, CalRGB, and Lab" (ISO 32000-2, 8.6.5.1).
    my RequireVersion 1.1 "a Lab colour"
    my ColourSpaceUsed Lab "lab in $what"
    # Under the derived name: that is what [operator] writes before "cs", and
    # the entry is set again on every colour of the space rather than guarded
    # by a flag - it is the same object each time, and one lookup less to
    # keep in step.
    my resource ColorSpace [::tclpdf::color labResource [lindex $parsed 1]] \
        [[my writer] ref [my LabSpaceObject $whitePoint $range]]
    return $spec
  }

  # The colour space object of one Lab space, written ONCE per document
  # however many roads it arrives by - a painted colour and any number of
  # separations that take it as their alternate. Keyed by the parameters,
  # which are what makes two Lab spaces the same space.
  method LabSpaceObject {whitePoint range} {
    set known [my state labSpaces]
    set key [list $whitePoint $range]
    if {[dict exists $known $key]} {
      return [dict get $known $key]
    }
    set object [[my writer] add [::tclpdf::color labArray $whitePoint $range]]
    dict set known $key $object
    my state labSpaces $known
    return $object
  }

  # Record one use of a colour space: DeviceGray, DeviceRGB, DeviceCMYK,
  # ICCBased or Lab, by the call named in "what", on the current page. Called by
  # [ColourUsed] for every painted colour, by image.tcl for a picture's
  # colour space and by shading.tcl for a gradient's - each site names its
  # own space, so no module reads another's structures.
  #
  # Kept small on purpose: the first three DISTINCT users of a space and a
  # flag that there were more. A refusal that lists three places is one a
  # caller can act on; one that lists every rectangle of a table is not, and
  # a document with ten thousand text runs should not pay for a list nobody
  # will read. Users repeat - a table paints "rect on page 3" hundreds of
  # times - which is why the list holds distinct entries rather than the
  # first three calls.
  method ColourSpaceUsed {space what} {
    set page [my page current]
    if {$page >= 0} {
      append what " on page [expr {$page + 1}]"
    }
    set spaces [my state colourSpaces]
    if {![dict exists $spaces $space]} {
      dict set spaces $space [dict create users [list $what] more 0]
    } else {
      set users [dict get $spaces $space users]
      if {$what ni $users} {
        if {[llength $users] < 3} {
          dict set spaces $space users [linsert $users end $what]
        } else {
          dict set spaces $space more 1
        }
      }
    }
    my state colourSpaces $spaces
    return
  }

  # Which colour spaces the document uses, and where: a dict from
  # DeviceGray, DeviceRGB, DeviceCMYK, ICCBased to {users {...} more 0|1},
  # the users being up to three "what on page N" strings. Empty until
  # something is painted. What pdfa.tcl holds against the output intent -
  # the device spaces; ICCBased is in the record as a fact, and stays
  # unjudged there because a profile-anchored space fits every intent.
  method colourSpacesUsed {} {
    return [my state colourSpaces]
  }
}

# What an ICC profile says it describes: {GRAY 1}, {RGB 3} or {CMYK 4}, or an
# error naming what is wrong. It lived in pdfa.tcl, where the output intent
# needed it first, and every ICC colour therefore pulled the PDF/A machinery
# in behind it - and with it tdom, which nothing about reading twenty bytes of
# a header needs. Three callers now: the output intent, [icc embed] and a
# picture's embedded profile.
proc ::tclpdf::color::iccSpace {bytes profile} {
  # "profile" is the caller's noun phrase for the source - a quoted file
  # name, or a description like "the ICC profile in the picture data" -
  # dropped into the message as it is. Quoting it here wrapped whole
  # descriptions in quotation marks; the caller knows what to call it.
  if {[string range $bytes 36 39] ne "acsp"} {
    return -code error "tclpdf: $profile is not an ICC profile - the\
        signature \"acsp\" is missing from its header"
  }
  set space [string trimright [string range $bytes 16 19]]
  set spaces {GRAY 1 RGB 3 CMYK 4}
  if {![dict exists $spaces $space]} {
    # Worded for every caller alike - the output intent, [icc embed], a
    # picture's embedded profile all read through here.
    return -code error "tclpdf: $profile describes colour space \"$space\" -\
        a device space profile is needed: GRAY, RGB and CMYK"
  }
  return [list $space [dict get $spaces $space]]
}

# A grey stop between coloured ones: the same grey, said in the other space.
# A shading (and anything else that needs its colours in ONE space) calls
# this on every stop with the space the coloured stops use; a grey becomes
# {g g g} in RGB and {0 0 0 1-g} in CMYK, a colour already in that space is
# returned as it is, and anything else is left for the caller to refuse.
# Needed since "white" and "#808080" parse as grey: {white steelblue} is an
# RGB gradient, and it would be absurd to refuse it.
proc ::tclpdf::color::promote {parsed space} {
  if {[lindex $parsed 0] ne "gray" || $space eq "gray"} {
    return $parsed
  }
  set g [lindex $parsed 1 0]
  switch -- $space {
    rgb {return [list rgb [list $g $g $g]]}
    cmyk {return [list cmyk [list 0 0 0 [expr {1 - $g}]]]}
  }
  return $parsed
}

# The name of the colour space as it appears in a resource dictionary.
proc ::tclpdf::color::space {parsed} {
  switch -- [lindex $parsed 0] {
    gray {return DeviceGray}
    rgb {return DeviceRGB}
    cmyk {return DeviceCMYK}
    separation {return Separation}
    pattern {return Pattern}
    icc {
      # An ICC colour has no family NAME that could stand in a resource or
      # a shading dictionary - its space is an object, written by
      # [ColourUsed], which never asks this question. Whoever does ask -
      # a shading collecting its stops is the one caller - cannot use the
      # answer, and is told so instead of receiving "/ICCBased" and
      # writing it as if it were /DeviceRGB.
      return -code error "tclpdf: an ICC based colour cannot stand here -\
          a gradient names its space by family, and takes grey, RGB or CMYK"
    }
    lab {
      # Same answer for the same reason: a Lab space is the array
      # [/Lab << ... >>] (8.6.5.4), not a family name, so it cannot stand
      # where a name is written. A separation alternate CAN be Lab - that
      # road does not come through here but builds the array itself, see
      # [ColourUsed].
      return -code error "tclpdf: a Lab colour cannot stand here - a gradient\
          names its space by family, and a Lab space is an array (ISO\
          32000-2, 8.6.5.4); give the stops in grey, RGB or CMYK"
    }
  }
  return -code error "tclpdf: unknown colour space \"[lindex $parsed 0]\""
}

# The /ColorSpace resource entry a Lab colour paints through. Derived from
# the space's PARAMETERS rather than counted up, because [operator] is given
# a colour and no document and has to name the entry [LabColourUsed] made.
# The default space keeps the readable name; any other gets the CRC of its
# parameters, which is stable within a document and across two writes of it.
proc ::tclpdf::color::labResource {values} {
  variable labWhitePoint
  variable labRange
  lassign $values - whitePoint range
  if {$whitePoint eq $labWhitePoint && $range eq $labRange} {
    return Lab
  }
  return "Lab[format %08X [zlib crc32 [list $whitePoint $range]]]"
}

# The colour space object itself: [/Lab << /WhitePoint [...] /Range [...] >>]
# (8.6.5.4). BlackPoint is not written - Table 64 makes it optional with the
# default [0.0 0.0 0.0], and there is nothing this package could put there
# that a caller has not measured.
proc ::tclpdf::color::labArray {whitePoint range} {
  return [::tclpdf::pdfObj arr [list /Lab [::tclpdf::pdfObj dictionary [list \
      WhitePoint [::tclpdf::pdfObj arr [lmap value $whitePoint {::tclpdf::pdfObj num $value}]] \
      Range [::tclpdf::pdfObj arr [lmap value $range {::tclpdf::pdfObj num $value}]]]]]]
}

# The three components of a Lab colour and the space they are in, out of what
# the caller wrote after the keyword: {{L a b} {Xw Yw Zw} {amin amax bmin bmax}}.
#
# The components are the first three words and the options follow them,
# because a* and b* are routinely NEGATIVE - splitting at the first leading
# dash would read "-30" as an option and the colour as two components.
proc ::tclpdf::color::LabColour {arguments} {
  variable labWhitePoint
  variable labRange
  if {[llength $arguments] < 3} {
    return -code error "tclpdf: lab needs exactly 3 components - L, a and b -\
        got [llength $arguments]: \"$arguments\""
  }
  set options [::tclpdf::option parse [list whitePoint $labWhitePoint \
      range $labRange] [lrange $arguments 3 end] "a Lab colour"]
  set whitePoint [LabWhitePoint [dict get $options whitePoint]]
  set range [LabRange [dict get $options range]]
  return [list [LabComponents [lrange $arguments 0 2] $range] $whitePoint $range]
}

# The white point, checked against Table 64: "An array of three numbers
# [XW YW ZW] ... The numbers XW and ZW shall be positive, and YW shall be
# 1.0." Refused rather than corrected - unlike a component, which the same
# subclause says to clamp silently, a wrong white point is not a stray value
# but a wrong space, and every colour in it comes out shifted with nothing
# to show for it.
proc ::tclpdf::color::LabWhitePoint {value} {
  if {[llength $value] != 3} {
    return -code error "tclpdf: -whitePoint is three numbers {Xw Yw Zw}, got\
        [llength $value]: \"$value\""
  }
  set value [lmap number $value {Double $number -whitePoint}]
  lassign $value x y z
  if {$x <= 0 || $z <= 0} {
    return -code error "tclpdf: Xw and Zw of -whitePoint shall be positive\
        (ISO 32000-2, 8.6.5.4, Table 64), got \"$value\""
  }
  if {$y != 1.0} {
    return -code error "tclpdf: Yw of -whitePoint shall be 1.0 (ISO 32000-2,\
        8.6.5.4, Table 64), got \"$y\""
  }
  return $value
}

# The range of a* and b*, [amin amax bmin bmax] by Table 64. An inverted pair
# is refused: it is not a range the standard describes, and clamping against
# it would put every colour on one edge without a word.
proc ::tclpdf::color::LabRange {value} {
  if {[llength $value] != 4} {
    return -code error "tclpdf: -range is four numbers {amin amax bmin bmax},\
        got [llength $value]: \"$value\""
  }
  set value [lmap number $value {Double $number -range}]
  lassign $value aMin aMax bMin bMax
  if {$aMin > $aMax || $bMin > $bMax} {
    return -code error "tclpdf: -range runs from the smaller value to the\
        larger, {amin amax bmin bmax}, got \"$value\""
  }
  return $value
}

# L* against 0..100 and a*, b* against the space's own range. Clamped, not
# refused, and that is the standard's instruction rather than this package's
# habit: "Component values falling outside the specified range shall be
# adjusted to the nearest valid value without error indication" (8.6.5.4,
# said twice - for L* in the prose and for a*/b* in Table 64).
proc ::tclpdf::color::LabComponents {values range} {
  lassign $range aMin aMax bMin bMax
  lassign $values l a b
  return [list [Pin $l 0 100] [Pin $a $aMin $aMax] [Pin $b $bMin $bMax]]
}

# A number and nothing else, kept as a double so that two spellings of one
# white point - {0.9642 1 0.8249} and {0.9642 1.0 0.8249} - are one space and
# get one resource entry rather than two.
proc ::tclpdf::color::Double {value option} {
  if {![string is double -strict $value]} {
    return -code error "tclpdf: $option takes numbers, got \"$value\""
  }
  return [expr {double($value)}]
}

# Names that may not be given to a separation or to an ICC alias, and the
# reason in the caller's words. Both live in the SAME /ColorSpace resource
# dictionary as the spaces below, so a clash is not a duplicate name but a
# silently different colour. One list, because it was two identical ones.
proc ::tclpdf::color::Reserved {name} {
  if {$name in {DeviceGray DeviceRGB DeviceCMYK Pattern}} {
    return "it names a colour space family (ISO 32000-1, 8.6.8)"
  }
  if {[regexp {^Lab([0-9A-F]{8})?$} $name]} {
    return "it is how this writer names a Lab colour space (ISO 32000-2,\
        8.6.5.4)"
  }
  return {}
}

# The component values of a parsed colour, without the space.
proc ::tclpdf::color::Numbers {space values} {
  if {$space eq "separation"} {
    return [list [lindex $values 2]]
  }
  if {$space eq "icc"} {
    return [lindex $values 1]
  }
  if {$space eq "lab"} {
    return [lindex $values 0]
  }
  return $values
}

# Split a hexadecimal colour into components. Three digits are the shorthand
# in which each digit is doubled - "#f0a" is "#ff00aa", not "#f00a00".
# A named or hex colour whose three components are equal is a grey, and it
# is written as DeviceGray rather than as DeviceRGB with three equal numbers.
# The picture is the same; what differs is what PDF/A makes of it: DeviceRGB
# is allowed only under an RGB output intent (ISO 19005-2, 6.2.4.3), DeviceGray
# under any. So "black", "white", "gray", "silver" and #808080 stay usable in
# a document whose intent is CMYK, where {0 0 0} would be refused by the
# validator - measured on the example with the ISO Coated v2 intent, where a
# footer in {0.45 0.45 0.5} was the one failed check on the page.
proc ::tclpdf::color::Achromatic {rgb} {
  lassign $rgb r g b
  if {$r == $g && $g == $b} {
    return [list gray [list $r]]
  }
  return [list rgb $rgb]
}

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
  return [Pin $value 0 1]
}

# A component against the range its space gives it - 0..1 for the device
# spaces, 0..100 and the space's own /Range for Lab. The value is returned as
# it was written when it is inside, so that {rgb 0.2 ...} still says 0.2.
proc ::tclpdf::color::Pin {value low high} {
  if {![string is double -strict $value]} {
    return -code error "tclpdf: colour component is not a number: \"$value\""
  }
  if {$value < $low} {
    return $low
  }
  if {$value > $high} {
    return $high
  }
  return $value
}

package provide tclpdf::color 1.5