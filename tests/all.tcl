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

# Load the package under test through the package mechanism, the same way a
# user gets it. That exercises the pkgIndex.tcl written by configure as well,
# so a module missing from it fails here instead of after installation.
set libdir [file dirname $thisdir]
if {![file exists [file join $libdir pkgIndex.tcl]]} {
    puts stderr "tclpdf: pkgIndex.tcl is missing - run ./configure first"
    exit 1
}
lappend auto_path $libdir
package require tclpdf

# Every module is required here, not only in the test file that exercises it:
# one that is missing from pkgIndex.tcl or broken at load time then fails once
# and clearly, rather than as a puzzling error inside some unrelated test.
#
# Third of the three lists to keep in sync - the others are
# TEA_ADD_TCL_SOURCES in configure.ac and the module pairs in pkgIndex.tcl.in.
foreach tclpdfPkg {
    tclpdf::pdfObj
    tclpdf::filter
    tclpdf::event
    tclpdf::writer
    tclpdf::color
    tclpdf::geometry
    tclpdf::document
    tclpdf::page
    tclpdf::graphics
    tclpdf::shape
    tclpdf::output
    tclpdf::option
    tclpdf::afmData
    tclpdf::afm
    tclpdf::text
    tclpdf::textBlock
    tclpdf::textAvoid
    tclpdf::textPath
    tclpdf::leader
    tclpdf::pageNumber
    tclpdf::xObject
    tclpdf::io
    tclpdf::attach
    tclpdf::sfnt
    tclpdf::glyfOutline
    tclpdf::type1
    tclpdf::varFont
    tclpdf::shaping
    tclpdf::bidi
    tclpdf::subset
    tclpdf::font
    tclpdf::otLayout
    tclpdf::gdef
    tclpdf::kernGpos
    tclpdf::kern
    tclpdf::gsubApply
    tclpdf::liga
    tclpdf::joiningData
    tclpdf::joining
    tclpdf::forms
    tclpdf::imageJpeg
    tclpdf::imagePng
    tclpdf::imagePngAlpha
    tclpdf::image
    tclpdf::shading
    tclpdf::pattern
    tclpdf::tableLayout
    tclpdf::tableDraw
    tclpdf::table
    tclpdf::pdfa
    tclpdf::zugferd
    tclpdf::link
    tclpdf::outline
    tclpdf::xml
    tclpdf::svgPath
    tclpdf::svg
    tclpdf::svgElement
    tclpdf::svgPaint
    tclpdf::viewerPreferences
    tclpdf::pageLabel
    tclpdf::structure
    tclpdf::structureWrite
    tclpdf::structureReport
    tclpdf::structureDest
    tclpdf::xmp
    tclpdf::ua
} {
    package require $tclpdfPkg
}
unset -nocomplain tclpdfPkg

testConstraint mutation false

runAllTests
proc exit args {}
