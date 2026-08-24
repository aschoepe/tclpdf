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
#
# The class word stands where the hierarchy stands in every other code of this
# package, and the caller's own spelling is a fact behind it rather than the
# class itself: a code of TCLPDF OPTION -recht would read the mistyped word as
# a class of its own, and no prefix below TCLPDF OPTION could then be trapped.
#

package require Tcl 8.6.11-

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
  return $value
}

proc ::tclpdf::option::Where {context} {
  if {$context eq {}} {
    return {}
  }
  return " for $context"
}

package provide tclpdf::option 1.2
