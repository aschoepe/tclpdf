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

# NOTE: second place carrying the version number. The first one is AC_INIT in
# configure.ac. Both must agree - tests/version.test checks that, so a drift
# shows up at build time instead of at the user's site.
package provide tclpdf 1.0
