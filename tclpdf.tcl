#
# tclpdf - PDF generation for Tcl
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#

# Minimum version 8.6.11, open ended - that is what makes the requirement hold
# under Tcl 9 as well. The open form is necessary: "package require Tcl 8.6"
# alone is rejected by Tcl 9 with a version conflict.
package require Tcl 8.6.11-

namespace eval ::tclpdf {
  namespace export {[a-z]*}
  namespace ensemble create

  # zlib is a built-in COMMAND, not a package: Tcl 8.6 additionally ships a
  # dummy package of that name, Tcl 9 does not. So check for the command and
  # request nothing.
  if {![llength [info commands ::zlib]]} {
    return -code error "tclpdf: the built-in command \"zlib\" is missing - this Tcl build was compiled without zlib"
  }
}

# Create a document:
#
#   set doc [tclpdf new -format a4 -orientation portrait -unit mm]
#
# The topical package is required HERE and not at the top of the file: loading
# tclpdf must stay cheap, and a caller who only wants the page format table
# should not pay for the document machinery. "package require" is idempotent
# and costs nothing after the first call, so laziness is free at run time.
proc ::tclpdf::new {args} {
  package require tclpdf::document
  return [::tclpdf::document::document new {*}$args]
}

# The known page formats - "tclpdf formats" without building a document.
proc ::tclpdf::formats {} {
  package require tclpdf::geometry
  return [::tclpdf::geometry formats]
}

# -- loading a module by using it -----------------------------------------

# Tcl calls [unknown] when a command does not exist. This one is installed
# for the ::tclpdf namespace ONLY - a replacement for the global [unknown]
# would reach into every script that happens to load this package, which is
# not ours to do.
#
# What it buys: writing
#
#   ::tclpdf::svgPath operators $data $transform
#
# loads tclpdf::svgPath if it is not there yet, instead of failing with
# "invalid command name". The modules still require their dependencies at the
# top of the file - that is what documents them, and it is what makes a
# missing module fail at load time rather than three calls later. This is the
# safety net underneath, not a substitute for it.
#
# Only names that match a module are handled. Anything else is passed on to
# the global [unknown] unchanged, so a genuine typo still reports itself as a
# typo rather than as a missing package.
namespace eval ::tclpdf {
  variable loadable {}
}

proc ::tclpdf::unknown {name args} {
  variable loadable

  if {![llength $loadable]} {
    # Which packages exist is asked of the package machinery rather than kept
    # in a second list here: [package names] already knows, and a list that
    # has to be maintained alongside pkgIndex.tcl is a list that will
    # eventually disagree with it.
    foreach candidate [package names] {
      if {[string match ::tclpdf::* ::$candidate]} {
        lappend loadable [namespace tail $candidate]
      }
    }
  }

  set topic [namespace tail $name]
  if {$topic in $loadable && ![catch {package require tclpdf::$topic}]} {
    if {[llength [info commands ::tclpdf::$topic]]} {
      return [uplevel 1 [list ::tclpdf::$topic {*}$args]]
    }
  }
  return -code error "invalid command name \"$name\""
}

namespace eval ::tclpdf {
  # The handler is only reachable from inside this namespace, and only for
  # commands that are not found there.
  namespace unknown ::tclpdf::unknown
}

# NOTE: second place carrying the version number. The first one is AC_INIT in
# configure.ac. Both must agree - tests/version.test checks that, so a drift
# shows up at build time instead of at the user's site.
package provide tclpdf 1.0
