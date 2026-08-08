# all.tcl --
#
# This file contains a top-level script to run all of the Tcl
# tests.  Execute it by invoking "source all.test" when running tcltest
# in this directory.
#
# Copyright (c) 1998-1999 by Scriptics Corporation.
# Copyright (c) 2000 by Ajuba Solutions
#
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.

package prefer latest
package require Tcl 8.6-
package require tcltest 2.2
namespace import tcltest::*
configure {*}$argv -testdir [file dir [info script]]
if {[singleProcess]} {
    interp debug {} -frame 1
}
set thisdir [file dirname [file normalize [info script]]]

# Run all test files in a single interpreter so that the shared
# package load and helper definitions are available to every test.
configure {*}$argv \
    -testdir $thisdir \
    -singleproc 1

# Load the package under test. Further modules are added here one by one as
# they appear - the same list as in TEA_ADD_TCL_SOURCES (configure.ac).
set libdir [file dirname $thisdir]
source [file join $libdir tclpdf.tcl]

testConstraint mutation false

runAllTests
proc exit args {}
