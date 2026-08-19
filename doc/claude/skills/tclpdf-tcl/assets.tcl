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
# at its root. An installed package needs no line here.
lappend auto_path $root

set ttf      [file join $assets fonts DejaVuSans.ttf]
set ttfBold  [file join $assets fonts DejaVuSans-Bold.ttf]
set otf      [file join $assets fonts urw-core35-fonts NimbusSans-Regular.otf]
set type1    [file join $assets fonts urw-core35-fonts NimbusSans-Regular.t1]
set variable [file join $assets fonts google Roboto-Variable.ttf]
set jpeg     [file join $assets images sample-photo.jpg]
set png      [file join $assets images sample-rgba.png]
set svgFile  [file join $assets images sample-vector.svg]
set iccRgb   [file join $root icc sRGB2014.icc]
set iccCmyk  [file join $root icc ISOcoated_v2_bas.ICC]
set invoiceXml [file join $assets xml zugferd-en16931.xml]
set orderXml   [file join $assets xml order-x-comfort.xml]

# Where the PDFs go, and - one level up - the scripts check.tcl extracts:
# examples/tmp/reference/check-*.tcl beside examples/tmp/reference/out/*.pdf.
# Under "tmp" because that is what it is: nothing here is a source file, and
# "make clean" removes the whole examples/tmp branch.
if {[info exists ::env(TCLPDF_REFERENCE_OUT)]} {
    set out $::env(TCLPDF_REFERENCE_OUT)
} else {
    set out [file join $root examples tmp reference out]
}
