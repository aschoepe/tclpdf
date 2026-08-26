#!/bin/bash -norc
dnl     This file is an input file used by the GNU "autoconf" program to
dnl     generate the file "configure", which is run during Tcl installation
dnl     to configure the system for the local environment.

# Copyright (C) 2026 Alexander Schoepe, Bochum, DE

#-----------------------------------------------------------------------
# This initializes the environment with PACKAGE_NAME and PACKAGE_VERSION
# set as provided.  These will also be added as -D defs in your Makefile
# so you can encode the package version directly into the source files.
# This will also define a special symbol for Windows (BUILD_<PACKAGE_NAME>
# so that we create the export library with the dll.
#-----------------------------------------------------------------------

AC_INIT([tclpdf],[1.2])

#--------------------------------------------------------------------
# Remember whether the user gave --prefix on the command line, before
# TEA_INIT and TEA_PREFIX get their hands on the variables. Needed to
# fix up the exec_prefix after TEA_PREFIX (see below).
#--------------------------------------------------------------------

if test "${prefix}" != "NONE"; then
    user_prefix=yes
fi

#--------------------------------------------------------------------
# Call TEA_INIT as the first TEA_ macro to set up initial vars.
# This will define a ${TEA_PLATFORM} variable == "unix" or "windows"
# as well as PKG_LIB_FILE and PKG_STUB_LIB_FILE.
#--------------------------------------------------------------------

TEA_INIT()

AC_CONFIG_AUX_DIR(tclconfig)

#--------------------------------------------------------------------
# Pure-Tcl package: accept and ignore the usual binary-extension
# options so shared configure invocations (e.g. a central build
# script passing --enable-shared) do not warn about them.
#--------------------------------------------------------------------

AC_ARG_ENABLE([shared],
    [AS_HELP_STRING([--enable-shared],[ignored, pure-Tcl package])],
    [], [])
AC_ARG_ENABLE([threads],
    [AS_HELP_STRING([--enable-threads],[ignored, pure-Tcl package])],
    [], [])

#--------------------------------------------------------------------
# Load the tclConfig.sh file
#--------------------------------------------------------------------

TEA_PATH_TCLCONFIG
TEA_LOAD_TCLCONFIG

#-----------------------------------------------------------------------
# Handle the --prefix=... option by defaulting to what Tcl gave.
# Must be called after TEA_LOAD_TCLCONFIG and before TEA_SETUP_COMPILER.
#-----------------------------------------------------------------------

TEA_PREFIX

#-----------------------------------------------------------------------
# When the user gave --prefix but not --exec-prefix, TEA_INIT sets
# exec_prefix to the prefix but notes exec_prefix_default=yes, which
# makes TEA_PREFIX overwrite it again with the exec prefix recorded in
# tclConfig.sh - the package then installs into the Tcl tree no matter
# what --prefix said (ticket 1a64a34982). Restore the user's choice.
#-----------------------------------------------------------------------

if test x"${user_prefix}" = x"yes" -a x"${exec_prefix_default}" = x"yes"; then
    AC_MSG_NOTICE([--prefix given: overriding exec_prefix back to ${prefix}])
    exec_prefix=$prefix
fi

#-----------------------------------------------------------------------
# Specify the C source files to compile in TEA_ADD_SOURCES,
# public headers that need to be installed in TEA_ADD_HEADERS,
# stub library C source files to compile in TEA_ADD_STUB_SOURCES,
# and runtime Tcl library files in TEA_ADD_TCL_SOURCES.
# This defines PKG(_STUB)_SOURCES, PKG(_STUB)_OBJECTS, PKG_HEADERS
# and PKG_TCL_SOURCES.
#-----------------------------------------------------------------------

# Only files that actually exist belong here - a listed but missing source
# makes "make install" and "make archive" fail. The planned modules (graphics,
# text/fonts, images, tables, ZUGFeRD) are added one by one as they appear.

TEA_ADD_TCL_SOURCES([tclpdf.tcl pdfObj.tcl pdfFunction.tcl filter.tcl filterCcitt.tcl crypto.tcl encrypt.tcl sign.tcl field.tcl fieldButton.tcl fieldChoice.tcl fieldText.tcl event.tcl writer.tcl color.tcl geometry.tcl document.tcl page.tcl graphics.tcl shape.tcl output.tcl option.tcl afmData.tcl afm.tcl text.tcl textBlock.tcl textAvoid.tcl hyphenate.tcl leader.tcl textPath.tcl xObject.tcl importRead.tcl import.tcl importInfo.tcl update.tcl layer.tcl io.tcl attach.tcl sfnt.tcl glyfOutline.tcl glyfPath.tcl type1.tcl varFont.tcl shaping.tcl bidiData.tcl bidi.tcl subset.tcl font.tcl type3.tcl kern.tcl kernGpos.tcl markPos.tcl colr.tcl colrPaint.tcl colorFont.tcl colorFontPaint.tcl otLayout.tcl gdef.tcl gsubContext.tcl gsubApply.tcl liga.tcl joiningData.tcl joining.tcl forms.tcl structure.tcl structureWrite.tcl structureReport.tcl structureDest.tcl imageJpeg.tcl imagePng.tcl imagePngAlpha.tcl imageTiff.tcl imageTiffStreams.tcl image.tcl shading.tcl shadingMesh.tcl pattern.tcl tableLayout.tcl tableDraw.tcl table.tcl pdfa.tcl zugferd.tcl link.tcl annot.tcl annotMark.tcl annotShape.tcl outline.tcl pageLabel.tcl pageNumber.tcl xml.tcl svgPath.tcl svg.tcl svgElement.tcl svgPaint.tcl svgClip.tcl viewerPreferences.tcl xmp.tcl ua.tcl])

#--------------------------------------------------------------------
# You can add more files to clean if your extension creates any extra
# files by extending CLEANFILES.
# Add pkgIndex.tcl if it is generated in the Makefile instead of ./configure
# and change Makefile.in to move it from CONFIG_CLEAN_FILES to BINARIES var.
#
# A few miscellaneous platform-specific items:
# TEA_ADD_* any platform specific compiler/build info here.
#--------------------------------------------------------------------

#CLEANFILES="$CLEANFILES"

#--------------------------------------------------------------------
# Determine the name of the tclsh and/or wish executables in the
# Tcl and Tk build directories or the location they were installed
# into. These paths are used to support running test cases only,
# the Makefile should not be making use of these paths to generate
# a pkgIndex.tcl file or anything else at extension build time.
#--------------------------------------------------------------------

TEA_PROG_TCLSH

#--------------------------------------------------------------------
# Local autoconf addition not worth an own file
#--------------------------------------------------------------------

AC_CHECK_PROG(HAVE_PANDOC,pandoc,yes,no)

#--------------------------------------------------------------------
# Finally, substitute all of the various values into the Makefile.
# You may alternatively have a special pkgIndex.tcl.in or other files
# which require substituting th AC variables in.  Include these here.
#--------------------------------------------------------------------

AC_CONFIG_FILES([Makefile pkgIndex.tcl])
AC_OUTPUT
