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
    return -code error "tclpdf: options come in pairs[Where $context], got\
        \"$arguments\""
  }
  foreach {option value} $arguments {
    set name [string trimleft $option -]
    if {![dict exists $defaults $name]} {
      return -code error "tclpdf: unknown option \"$option\"[Where $context] -\
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
    return -code error "tclpdf: options come in pairs, got \"$arguments\""
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
    return -code error "tclpdf: $context needs $option {x y}"
  }
  if {[catch {llength $value} count] || $count != 2
      || ![string is double -strict [lindex $value 0]]
      || ![string is double -strict [lindex $value 1]]} {
    return -code error "tclpdf: $option takes two numbers {x y}, got\
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

package provide tclpdf::option 1.0
