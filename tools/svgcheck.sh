#!/bin/sh
#
# svgcheck - render every SVG test drawing twice and compare
#
#   tools/svgcheck.sh ?pattern?
#
# Once through rsvg-convert as the reference, once through tclpdf into a PDF
# and back to a raster, then count the differing pixels.
#
# Why this exists: the tcltest suite checks that the right operators come out.
# It cannot see that a shape sits in the wrong place, that a gradient runs the
# wrong way or that a glyph is upside down - the file is valid either way. In
# this project every defect worth the name has been of that kind, so the check
# that matters is the picture.
#
# NOT rendered through ImageMagick. Measured: "magick drawing.svg out.png"
# uses ImageMagick's own MSVG path even with librsvg installed, and gives up
# on a <text> element ("unable to read font"). It would compare tclpdf against
# something that is itself wrong. ImageMagick is used only to compare.
#
# Requires: librsvg (rsvg-convert), poppler (pdftoppm), ImageMagick (magick).
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

set -e

# The redirection is not decoration: with CDPATH set, [cd] prints the
# directory it changed to, and $here would hold two lines - every path built
# from it then silently misses.
here=$(CDPATH= cd -- "$(dirname "$0")/.." > /dev/null && pwd)
images="$here/examples/assets/images"
work="${TMPDIR:-/tmp}/tclpdf-svgcheck"
pattern="${1:-svg-*}"

for tool in rsvg-convert pdftoppm magick; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "svgcheck: $tool is missing." >&2
        case $tool in
            rsvg-convert) echo "  brew install librsvg" >&2 ;;
            pdftoppm)     echo "  brew install poppler" >&2 ;;
            magick)       echo "  brew install imagemagick" >&2 ;;
        esac
        exit 1
    fi
done

tclsh=${TCLSH:-tclsh8.6}
rm -rf "$work"
mkdir -p "$work"

# The width both sides are rendered at. High enough that a millimetre of
# displacement shows, low enough to stay quick.
width=800
dpi=96

# A drawing is placed on a page of its own size, so the comparison is about
# the drawing and not about a margin. -unit pt with the viewBox numbers taken
# as points keeps the two rasters the same shape.
cat > "$work/render.tcl" <<'TCL'
lappend auto_path [lindex $argv 0]
package require tclpdf
set source [lindex $argv 1]
set target [lindex $argv 2]

set doc [tclpdf new -unit pt]
lassign [$doc svg size $source] width height
$doc page add -format [list $width $height]
$doc svg $source -at {0 0} -size [list $width $height]
set skipped [$doc svg info]
$doc write $target
$doc destroy
if {[dict size $skipped]} {
    puts $skipped
}
TCL

total=0
failed=0
printf '%-24s %10s %8s  %s\n' drawing pixels share note
printf '%s\n' '------------------------------------------------------------'

for source in "$images"/$pattern.svg; do
    [ -e "$source" ] || continue
    name=$(basename "$source" .svg)
    total=$((total + 1))

    rsvg-convert -w $width "$source" -o "$work/$name-ref.png"

    note=$("$tclsh" "$work/render.tcl" "$here" "$source" "$work/$name.pdf" 2>&1) || {
        printf '%-24s %10s %8s  %s\n' "$name" - - "FAILED: $(echo "$note" | head -1)"
        failed=$((failed + 1))
        continue
    }
    pdftoppm -png -r $dpi -f 1 -l 1 "$work/$name.pdf" "$work/$name-own"
    own=$(ls "$work/$name-own"*.png 2>/dev/null | head -1)
    [ -n "$own" ] || {
        printf '%-24s %10s %8s  %s\n' "$name" - - "FAILED: nothing rendered"
        failed=$((failed + 1))
        continue
    }

    # EXACTLY the same size before comparing, height included. The two
    # renderers round the page height differently and land a pixel apart -
    # 1120 against 1121 - and [magick compare] answers a size mismatch with
    # the full pixel count, which reads as "everything is wrong" when nothing
    # is. Measured: that alone put ten of eleven drawings at 100 %.
    magick "$work/$name-ref.png" -resize "${width}x" -background white \
        -alpha remove "$work/$name-ref2.png"
    geometry=$(magick identify -format '%wx%h!' "$work/$name-ref2.png")
    magick "$own" -resize "$geometry" -background white -alpha remove \
        "$work/$name-own.png"
    size=$(magick identify -format '%[fx:w*h]' "$work/$name-ref2.png")
    # The "|| true" belongs INSIDE the substitution: [magick compare] exits 1
    # as soon as the images differ at all, which is the normal case here, and
    # with the guard outside the variable came back empty and every drawing
    # was reported as 100 % different.
    differing=$(magick compare -metric AE "$work/$name-ref2.png" \
        "$work/$name-own.png" null: 2>&1 || true)
    # AE comes back with a decimal point - "11287.3", not "11287". Rejecting
    # it as "not a number" and falling back to the total was what reported
    # every drawing as 100 % different, twice in a row, while the pictures
    # were three per cent apart.
    differing=$(printf '%s' "$differing" | tr -d '()' | cut -d' ' -f1 \
        | cut -d. -f1)
    case $differing in ''|*[!0-9]*) differing=$size ;; esac

    share=$(awk "BEGIN {printf \"%.2f%%\", 100 * $differing / $size}")
    printf '%-24s %10s %8s  %s\n' "$name" "$differing" "$share" "$note"
done

printf '%s\n' '------------------------------------------------------------'
echo "$total drawing(s), $failed failed to render"
echo "images in $work"
echo
echo "A share of a few per cent is normal: two renderers antialias"
echo "differently and place text a hair apart. A share above ten means"
echo "something is in the wrong place - open the two PNGs side by side."
