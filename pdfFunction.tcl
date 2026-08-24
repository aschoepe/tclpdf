#
# tclpdf - PDF functions, types 2, 3 and 4 (7.10)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A PDF function is a black box that turns m numbers into n numbers, and the
# standard gives four ways to write one down (7.10.1, Table 37). Two places
# in this package need one, and they arrived at it from opposite directions:
#
#   colour    the tint transform of a Separation is what one plate looks like
#             in an alternate space (8.6.6.4) - a type 2 from "no ink" to the
#             colour of the plate. A DeviceN needs the same answer for n
#             plates at once, which no one-input function can give, so it is
#             a type 4.
#   shading   the colour run of a gradient is a type 2 between two stops, or
#             a type 3 stitching one type 2 per segment (8.7.4.5.3); a
#             function-based shading hands the reader a type 4 and lets it
#             compute the colour of every point.
#
# Both wrote the dictionary themselves, and the two copies had already begun
# to differ in what they put in it - which is the whole reason for this
# module: a function is written HERE, and the callers say what it computes.
#
# Type 0, the sampled function, is not here. It has no caller: a tint
# transform of six inks would need 4 x m^6 samples, which is the case the
# standard itself points at type 4 for (7.10.5.1, NOTE 1), and a gradient
# says its colours as stops rather than as a raster. Writing it now would be
# a fifth thing to keep correct with nothing reading it.
#
# What is NOT here either: the moment a function is refused. A type 4 body
# has to be checked - see [checkCalculator] - but it is checked by the
# CALLER, at the caller's earliest moment: shading judges the -expression
# while it is still reading options, before it pins the version floor and
# before a single object is written, because a refusal that comes later
# leaves an object behind that no reader ever reaches and every validator
# counts. A builder that checked on its own would move that moment to the
# write.
#
# Section numbers in the comments refer to ISO 32000-2 (PDF 2.0).
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::pdfFunction {
  namespace export {[a-z]*}
  namespace ensemble create
}

oo::define ::tclpdf::document::document {

  # A type 2 function, the exponential interpolation (7.10.3): one input from
  # 0 to 1, and the straight run from C0 to C1. Returns the object number.
  #
  # /Domain [0 1] and /N 1 are written rather than asked for. Both callers
  # want the same thing and want it for the same reason - a tint runs from 0
  # to 1 (8.6.6.4) and so does the parameter of a gradient segment, and
  # "gradient" means LINEAR to everyone who is not writing a raytracer. An
  # exponent other than 1 has no caller, and a domain other than 0..1 would
  # have to be encoded by whoever stitches the function anyway.
  #
  # /Range is optional here (Table 39) and is passed only where it carries a
  # decision: a Lab alternate leaves 0..1 in every component, and a reader
  # that clips to the implicit range flattens the colour.
  method FunctionExponential {c0 c1 {range {}}} {
    set pairs [list \
        FunctionType 2 \
        Domain [::tclpdf::pdfObj arr [::tclpdf::pdfFunction numbers {0 1}]] \
        C0 [::tclpdf::pdfObj arr [::tclpdf::pdfFunction numbers $c0]] \
        C1 [::tclpdf::pdfObj arr [::tclpdf::pdfFunction numbers $c1]] \
        N 1]
    if {[llength $range]} {
      lappend pairs Range [::tclpdf::pdfObj arr \
          [::tclpdf::pdfFunction numbers $range]]
    }
    return [[my writer] add [::tclpdf::pdfObj dictionary $pairs]]
  }

  # A type 3 function, the stitching function (7.10.4): k sub-functions laid
  # side by side over 0..1, with the k-1 bounds between them. "functions" are
  # object numbers, in order; "bounds" are the inner boundaries and shall be
  # strictly increasing and strictly inside the domain
  # (Domain0 < Bounds0 < ... < Domain1), which is the caller's to check
  # before it writes the sub-functions.
  #
  # /Encode is derived rather than passed: every sub-function here is written
  # over 0..1 by [FunctionExponential], so each subdomain maps onto 0 1. An
  # Encode of 1 0 would run that segment backwards, and there is no caller
  # who wants that; deriving it also makes the array impossible to get out of
  # step with the number of functions, which is the mistake a reader answers
  # by painting nothing.
  method FunctionStitching {functions bounds} {
    if {[llength $bounds] != [llength $functions] - 1} {
      return -code error "tclpdf: a stitching function of [llength $functions]\
          functions needs [expr {[llength $functions] - 1}] bounds, got\
          [llength $bounds]"
    }
    set encode {}
    foreach function $functions {
      lappend encode 0 1
    }
    return [[my writer] add [::tclpdf::pdfObj dictionary [list \
        FunctionType 3 \
        Domain [::tclpdf::pdfObj arr [::tclpdf::pdfFunction numbers {0 1}]] \
        Functions [::tclpdf::pdfObj arr \
            [lmap number $functions {[my writer] ref $number}]] \
        Bounds [::tclpdf::pdfObj arr [::tclpdf::pdfFunction numbers $bounds]] \
        Encode [::tclpdf::pdfObj arr [::tclpdf::pdfFunction numbers $encode]]]]]
  }

  # A type 4 function, the PostScript calculator (7.10.5). The body arrives
  # WITHOUT the outer braces - they are written here, so that there is one
  # answer to "who wraps it" instead of one per caller.
  #
  # This is the one function type that is a STREAM rather than a dictionary,
  # so it goes through [streamObject] and is deflated with everything else.
  # /Range is not optional for it (Table 38) and is not decoration: it is
  # what clips the sum of two solid inks back to 1, and what tells the reader
  # how many numbers the calculation leaves behind.
  #
  # The body is not checked here; see the head of this file for why, and
  # [checkCalculator] for what a check would look at.
  method FunctionCalculator {domain range body} {
    return [my streamObject [list \
        FunctionType 4 \
        Domain [::tclpdf::pdfObj arr [::tclpdf::pdfFunction numbers $domain]] \
        Range [::tclpdf::pdfObj arr [::tclpdf::pdfFunction numbers $range]]] \
        "\{ $body \}"]
  }
}

# Numbers into PDF syntax, one place. Trivial, and it is here because it was
# NOT trivial in the two copies this module replaces: one of them put its
# /Domain and /Range into the array as bare Tcl values and only got away with
# it because every value it ever wrote was 0 or 1. A stop of 1e-05 is written
# by Tcl in exponential notation, a reader reads that as three tokens, and
# the object is corrupt - which is precisely what [pdfObj num] exists for.
proc ::tclpdf::pdfFunction::numbers {values} {
  return [lmap value $values {::tclpdf::pdfObj num $value}]
}

# The range of a function whose n outputs are each 0..1 - every colour
# component of every device space this package writes. Both callers computed
# it with a loop of their own.
proc ::tclpdf::pdfFunction::unitRange {count} {
  return [lrepeat $count 0 1]
}

# What a type 4 body may contain (7.10.5, Table 42) and nothing else. A type
# 4 function is NOT PostScript: there is no dictionary, no name, no procedure
# other than the branches of if and ifelse - which is why the list can be
# written out.
proc ::tclpdf::pdfFunction::operators {} {
  return {abs add atan ceiling cos cvi cvr div exp floor idiv ln log mod
      mul neg round sin sqrt sub truncate
      and bitshift eq false ge gt le lt ne not or true xor
      if ifelse
      copy dup exch index pop roll}
}

# Read a type 4 body and refuse what can be decided by reading it.
#
# Whether the right NUMBER of values is left on the stack cannot: [if],
# [ifelse] and [roll] make that depend on the values. What can be decided is
# whether every word is a word the calculator knows and whether the braces
# close - and a misspelt operator is the ordinary mistake, which a reader
# answers by painting nothing at all.
#
# "subject" names the thing being read, in the caller's words, and goes into
# every message; "errorcode" is the caller's own -errorcode. Both are the
# caller's because this proc is asked by two very different callers: one
# reads what a script wrote, the other reads what THIS PACKAGE generated.
#
# It runs on generated code as well, and that is a decision rather than an
# oversight. The tint transform of a DeviceN space is assembled token by
# token in colour.tcl, and the failure mode of a wrong token there is the
# worst one in this package: a valid PDF whose spot colours paint nothing.
# Reading a hundred tokens costs nothing measurable next to writing the
# stream, and it turns a future edit to the generator into an error at the
# call that made it instead of into a blank rectangle in a print shop.
proc ::tclpdf::pdfFunction::checkCalculator {body subject errorcode} {
  if {[string trim $body] eq {}} {
    return -code error -errorcode $errorcode \
        "tclpdf: $subject is empty - a PostScript calculator function\
        (ISO 32000-2, 7.10.5) needs at least one operator"
  }
  set tokens [regexp -all -inline {\{|\}|[^\s{}]+} $body]
  if {[lindex $tokens 0] eq "\{"} {
    # A caller who wrapped the body in braces has written a PROCEDURE and
    # pushed it on the stack, which is what [if] takes and what a function
    # body is not. Silence here is a function that computes nothing.
    return -code error -errorcode $errorcode \
        "tclpdf: $subject carries the outer braces of the function body, and\
        those are written here - give the operators alone, braces only around\
        the branches of if and ifelse"
  }
  set depth 0
  foreach token $tokens {
    if {$token eq "\{"} {
      incr depth
      continue
    }
    if {$token eq "\}"} {
      incr depth -1
      if {$depth < 0} {
        return -code error -errorcode $errorcode \
            "tclpdf: $subject closes a brace that was never opened"
      }
      continue
    }
    if {[string is double -strict $token]} {
      continue
    }
    if {$token ni [operators]} {
      return -code error -errorcode $errorcode \
          "tclpdf: \"$token\" is not an operator of a PostScript calculator\
          function (ISO 32000-2, 7.10.5, Table 42) in $subject - the\
          operators are: [join [operators] { }]"
    }
  }
  if {$depth} {
    return -code error -errorcode $errorcode \
        "tclpdf: $subject leaves $depth brace[expr {$depth == 1 ? {} : {s}}]\
        open"
  }
  return $body
}

package provide tclpdf::pdfFunction 1.0
