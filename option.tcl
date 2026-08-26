#
# tclpdf - PDF generation for Tcl
#
# option - reading -name value arguments
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Every public method of this package takes Tcl-style -options, so every one of
# them needs the same four lines: pair count, strip the dash, is it known, set
# it. Written per method, those four lines drift - one place accepts an
# abbreviation the next one rejects, one error message lists the known options
# and the next does not. This module exists so that there is one behaviour and
# one wording.
#
# Every refusal made here carries an -errorcode below TCLPDF OPTION, so that
# [trap {TCLPDF OPTION}] catches a mistake in the CALL - a misspelt option
# name, a value the option cannot take - as one class, wherever in the package
# it was made. Without them a mistyped option was the one refusal in the
# package that arrived as NONE, so a handler written against a module's own
# class caught every wrong value and no wrong name: the case a script is most
# likely to hit was the case it could not see. The second word says which
# mistake it was, then come the facts: the option or key that was named, and
# last the context the caller passed, empty where it passed none.
#
#   TCLPDF OPTION PAIRS    context             an odd number of words
#   TCLPDF OPTION UNKNOWN  option context      no such option
#   TCLPDF OPTION DICT     what context        a dictionary was expected
#   TCLPDF OPTION KEY      key what context    no such dictionary key
#   TCLPDF OPTION REQUIRED option context      an option that has to be given
#   TCLPDF OPTION POINT    option context      not the {x y} a point needs
#   TCLPDF OPTION NUMBER   what context        NaN or Inf where a measurement
#                                              was wanted
#
# The class word stands where the hierarchy stands in every other code of this
# package, and the caller's own spelling is a fact behind it rather than the
# class itself: a code of TCLPDF OPTION -recht would read the mistyped word as
# a class of its own, and no prefix below TCLPDF OPTION could then be trapped.
#

package require Tcl 8.6.11-
# For [pdfObj fits] - the one place the magnitude a PDF real holds stands
# (Annex C.2). pdfObj depends on nothing but Tcl, so the infrastructure stays
# the one-way street it is meant to be, and the range a file can hold is
# asked HERE, at the call, instead of at the moment of writing - by which
# time a "q", a "BT" or a marked-content bracket is already out.
package require tclpdf::pdfObj 1.0-

namespace eval ::tclpdf::option {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Read -name value pairs over a dictionary of defaults.
#
#   set options [::tclpdf::option parse {width 1 color black} $args]
#
# The defaults define which options exist - an unknown one is an error naming
# all the known ones, because a caller who mistyped -colour needs the list, not
# a plain refusal.
#
# "context" appears in the error message ("unknown option ... for rect") and is
# worth passing wherever a caller may have several option sets in play.
proc ::tclpdf::option::parse {defaults arguments {context {}}} {
  if {[llength $arguments] % 2} {
    return -code error -errorcode [list TCLPDF OPTION PAIRS $context] \
        "tclpdf: options come in pairs[Where $context], got \"$arguments\""
  }
  foreach {option value} $arguments {
    set name [string trimleft $option -]
    if {![dict exists $defaults $name]} {
      return -code error \
          -errorcode [list TCLPDF OPTION UNKNOWN $option $context] \
          "tclpdf: unknown option \"$option\"[Where $context] -\
          known are: -[join [dict keys $defaults] { -}]"
    }
    dict set defaults $name $value
  }
  return $defaults
}

# Like parse (named partition, not split: inside this namespace a proc called
# "split" would shadow the core command). Options outside the defaults are collected instead of
# refused - for a method that takes its own options AND passes font or style
# options on. Returns a two-element list: the filled defaults, and the rest.
proc ::tclpdf::option::partition {defaults arguments} {
  if {[llength $arguments] % 2} {
    return -code error -errorcode {TCLPDF OPTION PAIRS {}} \
        "tclpdf: options come in pairs, got \"$arguments\""
  }
  set rest {}
  foreach {option value} $arguments {
    set name [string trimleft $option -]
    if {[dict exists $defaults $name]} {
      dict set defaults $name $value
    } else {
      lappend rest $option $value
    }
  }
  return [list $defaults $rest]
}

# The keys of a dictionary, against the ones that exist.
#
#   ::tclpdf::option keys $cell {text colSpan rowSpan align valign style} \
#       "cell key" table
#
# The counterpart to [parse] for the places a caller writes a DICTIONARY rather
# than -name value pairs: a table cell, a style, a column description. [parse]
# refuses an unknown option; a dictionary merged over defaults refuses nothing,
# so a mistyped key is not an error but SILENCE - it is carried along, read by
# nobody, and the caller sees the default and no message.
#
# Measured on valign written on a cell: accepted and ignored for as long as the
# key existed, in a package that otherwise stops at a character a font has no
# glyph for. Same standard, same place to say so.
proc ::tclpdf::option::keys {value known what {context {}}} {
  if {[catch {dict size $value}]} {
    return -code error -errorcode [list TCLPDF OPTION DICT $what $context] \
        "tclpdf: $what[Where $context] takes a dictionary of\
        key value pairs, got \"$value\""
  }
  dict for {key ->} $value {
    if {$key ni $known} {
      return -code error \
          -errorcode [list TCLPDF OPTION KEY $key $what $context] \
          "tclpdf: unknown $what \"$key\"[Where $context] -\
          known are: [join $known { }]"
    }
  }
  return $value
}

# A point option: two numbers, or an error that names the likely mistake.
#
# Checked rather than left to lassign, because writing -at {20 [expr {$y+5}]}
# is a standing invitation: braces stop the substitution, and Tcl then reports
# "list element in braces followed by ]" from somewhere deep inside a method,
# which says nothing about the actual mistake.
#
# Here rather than in text.tcl: the second caller made it a copy, and a copy of
# an error message is how two commands come to explain the same mistake
# differently.
proc ::tclpdf::option::point {value option context} {
  if {$value eq {}} {
    return -code error \
        -errorcode [list TCLPDF OPTION REQUIRED $option $context] \
        "tclpdf: $context needs $option {x y}"
  }
  if {[catch {llength $value} count] || $count != 2
      || ![string is double -strict [lindex $value 0]]
      || ![string is double -strict [lindex $value 1]]} {
    return -code error -errorcode [list TCLPDF OPTION POINT $option $context] \
        "tclpdf: $option takes two numbers {x y}, got\
        \"$value\" - for a computed position use \[list \$x \$y\], braces do\
        not substitute"
  }
  # And two numbers a page has room for. Kept apart from the shape above
  # because the hint there is about braces, and a caller who arrived here with
  # a NaN did not write braces - the value came out of an arithmetic of their
  # own, a division by a width that was zero being the usual way. Same code:
  # it is the same option that is wrong, and a handler trapping
  # TCLPDF OPTION POINT wants both.
  foreach coordinate $value {
    if {![finite $coordinate]} {
      return -code error \
          -errorcode [list TCLPDF OPTION POINT $option $context] \
          "tclpdf: $option takes two finite numbers {x y}, got \"$value\" -\
          NaN and Inf are doubles to Tcl and name no point on a page"
    }
    # AND TWO NUMBERS THE FILE CAN HOLD. A PDF real carries about
    # +/-3.403e38 (Annex C.2), and a coordinate past that was accepted here
    # and refused by [pdfObj num] at the moment of writing - which is after
    # the "q", the mark and, for an annotation, the appearance stream, so
    # what a caught refusal left behind was a half-written page. Same code
    # as the shape and the NaN above: it is the same option that is wrong.
    if {![::tclpdf::pdfObj fits $coordinate]} {
      return -code error \
          -errorcode [list TCLPDF OPTION POINT $option $context] \
          "tclpdf: $option takes two numbers a PDF file can hold {x y}, got\
          \"$value\" - a real carries about +/-3.403e38 (ISO 32000-1,\
          Annex C.2)"
    }
  }
  return $value
}

# The magnification of an /XYZ destination (12.3.2.2, Table 151).
#
# 0 is a NUMBER A READER ACTS ON and not a mistake - "a zoom value of 0 has
# the same meaning as a null value", so it means "leave the magnification as
# it is" - and below it there is nothing to mean: no reader magnifies by a
# negative factor, and 12.3.2.2 offers a number or null and nothing else.
#
# Here rather than per module, and that is the whole reason it exists: the
# same two conditions and the same clause stood in link.tcl and in
# viewerPreferences.tcl, and [destination] - the third caller, and the public
# one - had neither (measured 2026-08-26: "destination 0 -to {10 10} -zoom -1"
# wrote /XYZ 28.35 811 -1). "context" and "option" name the call, as
# everywhere in this module, so the message says which of the three was wrong.
proc ::tclpdf::option::zoom {value option context} {
  if {![finite $value] || $value < 0} {
    return -code error -errorcode [list TCLPDF OPTION ZOOM $option $context] \
        "tclpdf: $option is a magnification of 0 or more -\
        0 means the magnification the reader is already at (ISO 32000-2,\
        12.3.2.2, Table 151) - not \"$value\""
  }
  return $value
}

# Is this a number something can be MEASURED in?
#
# [string is double -strict] does not answer that question: it is true for
# "NaN" and for "Inf", both of which are doubles to Tcl and neither of which is
# a length, a coordinate or a factor. What they cost when they get through is
# silence. NaN compares false against everything, so a range check written as
# "$value <= 0" and "$value > 100" waves it past - BOTH comparisons are false -
# and it then travels through the arithmetic until [expr] refuses it as an
# operand of "*", far from the call that wrote it, in Tcl's own words rather
# than in this package's: measured on 2026-08-25, "image place -at {NaN 20}"
# answered "can't use non-numeric floating-point value as operand of \"*\"",
# against the promise that every refusal begins with "tclpdf:".
#
# Here rather than per module. The same predicate stood in text.tcl since
# 2026-08-25 because that road hit the trap first; a second copy is how two
# modules come to disagree about what a number is. This is the module every
# other one already loads - it depends on nothing but Tcl - so it is where the
# one copy belongs.
#
# Written as a COMPARISON rather than with an arithmetic function: [expr]
# refuses NaN as an operand of "+" or of abs(), so a test that used one would
# throw the very error it is meant to replace. Comparison is defined for it -
# NaN is the one value not equal to itself (IEEE 754) - and the two bounds
# catch Inf and -Inf, which compare perfectly well and place nothing.
proc ::tclpdf::option::finite {value} {
  if {![string is double -strict $value]} {
    return 0
  }
  return [expr {$value == $value && $value < Inf && $value > -Inf}]
}

# The refusal that goes with it, so that the wording stands once as well.
#
# "what" names the value in the caller's terms ("-scale", "a length"), context
# the call, as everywhere here. NOT the same refusal as [pdfObj num]'s "number
# has no PDF representation": that one is the LAST line of defence, at the
# moment a number is written, and it stays where it is - it also catches a
# perfectly finite value beyond the PDF real range, which is a different
# mistake. This one is made at the call, before anything is written.
proc ::tclpdf::option::number {value what {context {}}} {
  if {![finite $value]} {
    return -code error -errorcode [list TCLPDF OPTION NUMBER $what $context] \
        "tclpdf: $what[Where $context] is a finite number, not \"$value\" -\
        NaN and Inf are doubles to Tcl and place nothing on a page"
  }
  # AND A NUMBER THE FILE CAN HOLD (Annex C.2, about +/-3.403e38), asked
  # through [pdfObj fits] so that the figure stands in one place. [pdfObj
  # num] asks the same question at the moment of WRITING and keeps doing so -
  # but by then the operators of the call are out, and a caller who caught
  # the refusal was left with a "q" without its "Q" and a mark without its
  # end. Measured 2026-08-26: "rect -at {1e39 20}" wrote its style and its
  # bracket before dying.
  if {![::tclpdf::pdfObj fits $value]} {
    return -code error -errorcode [list TCLPDF OPTION NUMBER $what $context] \
        "tclpdf: $what[Where $context] is \"$value\", which is beyond what a\
        PDF number holds - a real carries about +/-3.403e38 (ISO 32000-1,\
        Annex C.2)"
  }
  return $value
}

proc ::tclpdf::option::Where {context} {
  if {$context eq {}} {
    return {}
  }
  return " for $context"
}

package provide tclpdf::option 1.3
