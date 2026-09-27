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
# THE TREE WINS, whatever is installed on the machine. Two rules of Tcl's
# package mechanism decide that, both measured on 2026-09-27: for an EQUAL
# version the ifneeded script registered LAST is the one that runs, and
# [package unknown] walks auto_path from its END to its FRONT when it sources
# the pkgIndex files - so the first directory of auto_path has the last word.
# Appended with lappend, the tree was sourced first and an installed copy of
# the same version overrode it: the suite passed against /opt/tcl/8.6/lib
# while the tree had changed. So the tree goes to the FRONT, and its index
# is sourced here once more, explicitly and last, so that no later scan can
# take the registration away again. A test in the project directory tests
# the project directory.
set auto_path [linsert $auto_path 0 $libdir]
apply {{dir} {source [file join $dir pkgIndex.tcl]}} $libdir
package require tclpdf

# Every module is required here, not only in the test file that exercises it:
# one that is missing from pkgIndex.tcl or broken at load time then fails once
# and clearly, rather than as a puzzling error inside some unrelated test.
#
# Third of the three lists to keep in sync - the others are
# TEA_ADD_TCL_SOURCES in configure.ac and the module pairs in pkgIndex.tcl.in.
foreach tclpdfPkg {
    tclpdf::pdfObj
    tclpdf::pdfFunction
    tclpdf::filter
    tclpdf::filterCcitt
    tclpdf::crypto
    tclpdf::encrypt
    tclpdf::sign
    tclpdf::field
    tclpdf::fieldButton
    tclpdf::fieldChoice
    tclpdf::fieldText
    tclpdf::timestamp
    tclpdf::update
    tclpdf::layer
    tclpdf::type3
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
    tclpdf::textRun
    tclpdf::markup
    tclpdf::markdown
    tclpdf::textAvoid
    tclpdf::textPath
    tclpdf::leader
    tclpdf::pageNumber
    tclpdf::xObject
    tclpdf::importRead
    tclpdf::import
    tclpdf::importInfo
    tclpdf::io
    tclpdf::attach
    tclpdf::sfnt
    tclpdf::glyfOutline
    tclpdf::type1
    tclpdf::varFont
    tclpdf::shaping
    tclpdf::bidiData
    tclpdf::bidi
    tclpdf::subset
    tclpdf::font
    tclpdf::otLayout
    tclpdf::gdef
    tclpdf::kernGpos
    tclpdf::markPos
    tclpdf::glyfPath
    tclpdf::colr
    tclpdf::colrPaint
    tclpdf::sbix
    tclpdf::morx
    tclpdf::colorFont
    tclpdf::colorFontBand
    tclpdf::colorFontPaint
    tclpdf::colorFontRegion
    tclpdf::colorFontBitmap
    tclpdf::imageTiff
    tclpdf::imageTiffStreams
    tclpdf::hyphenate
    tclpdf::kern
    tclpdf::gsubContext
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
    tclpdf::shadingMesh
    tclpdf::pattern
    tclpdf::tableLayout
    tclpdf::tableDraw
    tclpdf::table
    tclpdf::link
    tclpdf::annot
    tclpdf::annotMark
    tclpdf::annotShape
    tclpdf::outline
    tclpdf::xml
    tclpdf::svgPath
    tclpdf::svg
    tclpdf::svgElement
    tclpdf::svgPaint
    tclpdf::svgClip
    tclpdf::viewerPreferences
    tclpdf::pageLabel
    tclpdf::structure
    tclpdf::structureWrite
    tclpdf::structureReport
    tclpdf::structureDest
} {
    package require $tclpdfPkg
}
unset -nocomplain tclpdfPkg

# The four that build or read the XMP packet stand apart because they need
# tdom, which the package does not require of anyone else: a document that
# claims no conformance never loads them. Required unconditionally here, the
# whole suite died on a machine without tdom - 1551 tests taken down by an
# optional dependency of four modules. Now they are asked for where they can
# be had, and the tests that use them carry the haveTdom constraint from
# helper.tcl, so such a machine skips those and runs everything else.
foreach tclpdfPkg {tclpdf::xmp tclpdf::pdfa tclpdf::zugferd tclpdf::ua} {
    catch {package require $tclpdfPkg}
}
unset -nocomplain tclpdfPkg

testConstraint mutation false

runAllTests
proc exit args {}
