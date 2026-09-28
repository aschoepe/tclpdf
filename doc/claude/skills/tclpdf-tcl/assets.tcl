# assets.tcl - the variables the reference snippets refer to, for THIS tree.
#
# Another project edits this file and nothing else: the paths point at what
# that project has - any TrueType face, any JPEG, its own invoice XML. The
# variable names are the contract with reference/*.md (see SKILL.md).
#
# Here they point at the example assets of the tclpdf source tree, relative
# to this file, so the check runs from a checkout without setup.

set root [file normalize [file join [file dirname [info script]] .. .. .. ..]]
set assets [file join $root examples assets]

# The package itself, when it is not installed: a checkout carries pkgIndex.tcl
# at its root, and it goes to the FRONT of auto_path, once - so that the tree
# is checked and not an installed copy of the same version. Tcl runs the
# ifneeded script registered last and reads auto_path from the back, so the
# first directory has the last word; a second copy of the same directory
# further back would be read first and the front one skipped, which is why
# any earlier entry is removed. An installed package needs no line here.
set auto_path [linsert [lsearch -all -inline -not -exact $auto_path $root] 0 $root]

set ttf      [file join $assets fonts DejaVuSans.ttf]
set ttfBold  [file join $assets fonts DejaVuSans-Bold.ttf]
set otf      [file join $assets fonts urw-core35-fonts NimbusSans-Regular.otf]
set type1    [file join $assets fonts urw-core35-fonts NimbusSans-Regular.t1]
set variable [file join $assets fonts google Roboto-Variable.ttf]
# A face with vertical metrics - vhea, vmtx and the GSUB feature "vert" - which
# is what the vertical writing snippets need and what no Latin face carries.
set jpTtf    [file join $assets fonts google NotoSansJP-Regular.ttf]
set jpeg     [file join $assets images sample-photo.jpg]
set png      [file join $assets images sample-rgba.png]
set tiff     [file join $assets images sample-scan.tiff]
set svgFile  [file join $assets images sample-vector.svg]
set iccRgb   [file join $root icc sRGB2014.icc]
set iccCmyk  [file join $root icc ISOcoated_v2_bas.ICC]
set invoiceXml [file join $assets xml zugferd-en16931.xml]
set orderXml   [file join $assets xml order-x-comfort.xml]

# Hyphenation patterns for one language - a libhyphen .dic file, the format
# LibreOffice, Hunspell and the hyphen library install. THE PACKAGE SHIPS
# NONE (licence: every published set has terms of its own, tclpdf is MIT), so
# this path may well not exist here: 03-text.md checks before it uses it and
# says so when it is missing. On most Linux systems /usr/share/hyphen/ holds
# them; on macOS and Windows a LibreOffice dictionary extension does.
set hyphenPatterns [file join $assets languages hyph_de_DE.dic]

# Where the PDFs go, and - one level up - the scripts check.tcl extracts:
# examples/tmp/reference/check-*.tcl beside examples/tmp/reference/out/*.pdf.
# Under "tmp" because that is what it is: nothing here is a source file, and
# "make clean" removes the whole examples/tmp branch.
if {[info exists ::env(TCLPDF_REFERENCE_OUT)]} {
    set out $::env(TCLPDF_REFERENCE_OUT)
} else {
    set out [file join $root examples tmp reference out]
}
