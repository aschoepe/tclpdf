#
# tclpdf - PDF generation for Tcl
#
# imagePngAlpha - the one computed path: un-filtering and channel separation
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# PDF has no image format that carries its own alpha channel. A PNG with
# transparency therefore has to be taken apart: the colour samples become the
# image, the alpha samples an /SMask referenced from it. Taking it apart means
# decompressing and reversing the per-row filters first.
#
# THIS IS THE ONLY EXPENSIVE PATH IN THE PACKAGE, measured at 4.3 s per
# megapixel, and it is expensive for a structural reason: the Paeth predictor
# reads the byte to the left of the one it is computing, so a row cannot be
# vectorised - each byte depends on its predecessor. A logo of 300x100 pixels
# costs about 0.13 s, which is fine; a full-page photograph is not.
#
# It lives in a file of its own precisely because of that. It is the one
# candidate for the optional C accelerator, and an optional accelerator is
# only replaceable when there is a single, named place to replace.
#
# Anything without an alpha channel never reaches this file - imagePng.tcl
# hands those to the reader untouched. This is a private sub-module behind the
# [image] facade.
#

package require Tcl 8.6.11-
package require tclpdf::filter 1.0-

namespace eval ::tclpdf::imagePngAlpha {
  namespace export {[a-z]*}
  namespace ensemble create
}

# Separate a parsed PNG into colour and alpha bytes.
#
# Returns a dict with "color" and "alpha", both raw (uncompressed, unfiltered)
# and both ready to be deflated into a stream of their own.
proc ::tclpdf::imagePngAlpha::separate {parsed} {
  set width [dict get $parsed width]
  set height [dict get $parsed height]
  set depth [dict get $parsed bitDepth]
  set channels [dict get $parsed channels]
  if {$depth ni {8 16}} {
    # The format only allows 8 and 16 for colour types 4 and 6, so this can
    # only be reached with a damaged file.
    return -code error "tclpdf: a PNG with an alpha channel cannot have a bit\
        depth of $depth"
  }
  set pixels [unfilter [::tclpdf::filter decodeFlate [dict get $parsed idat]] \
      $width $height $depth $channels]

  set color {}
  set alpha {}
  if {$depth == 8} {
    if {$channels == 2} {
      foreach {gray a} $pixels {
        lappend color $gray
        lappend alpha $a
      }
    } else {
      foreach {r g b a} $pixels {
        lappend color $r $g $b
        lappend alpha $a
      }
    }
  } else {
    if {$channels == 2} {
      foreach {g0 g1 a0 a1} $pixels {
        lappend color $g0 $g1
        lappend alpha $a0 $a1
      }
    } else {
      foreach {r0 r1 g0 g1 b0 b1 a0 a1} $pixels {
        lappend color $r0 $r1 $g0 $g1 $b0 $b1
        lappend alpha $a0 $a1
      }
    }
  }
  return [dict create color [binary format c* $color] \
      alpha [binary format c* $alpha]]
}

# Reverse the per-row filters (PNG 9.2) and return the pixel bytes as a list of
# integers. A list rather than a string because the caller has to pick channels
# apart afterwards, and [foreach] over a list does that in one pass.
proc ::tclpdf::imagePngAlpha::unfilter {raw width height depth channels} {
  # Bytes per pixel, rounded up - the filters address the byte "bpp to the
  # left", and for sub-byte depths that is the byte immediately before.
  set bpp [expr {max(1, ($depth * $channels + 7) / 8)}]
  set stride [expr {($width * $depth * $channels + 7) / 8}]
  set expected [expr {($stride + 1) * $height}]
  if {[string length $raw] < $expected} {
    return -code error "tclpdf: damaged PNG - the image data is\
        [string length $raw] bytes, expected $expected"
  }

  set pixels {}
  set prior [lrepeat $stride 0]
  set offset 0
  for {set row 0} {$row < $height} {incr row} {
    binary scan [string index $raw $offset] cu filterType
    binary scan [string range $raw [expr {$offset + 1}] \
        [expr {$offset + $stride}]] cu* line
    incr offset [expr {$stride + 1}]

    switch -- $filterType {
      0 {}
      1 {
        for {set i $bpp} {$i < $stride} {incr i} {
          lset line $i [expr {([lindex $line $i] +
              [lindex $line [expr {$i - $bpp}]]) & 255}]
        }
      }
      2 {
        # Up has no dependency inside the row, so it goes through [lmap] over
        # both rows at once instead of an indexed loop - measurably the
        # cheapest of the five.
        set line [lmap here $line above $prior {expr {($here + $above) & 255}}]
      }
      3 {
        for {set i 0} {$i < $stride} {incr i} {
          set left [expr {$i >= $bpp ? [lindex $line [expr {$i - $bpp}]] : 0}]
          lset line $i [expr {([lindex $line $i] +
              (($left + [lindex $prior $i]) >> 1)) & 255}]
        }
      }
      4 {
        for {set i 0} {$i < $stride} {incr i} {
          if {$i >= $bpp} {
            set left [lindex $line [expr {$i - $bpp}]]
            set upperLeft [lindex $prior [expr {$i - $bpp}]]
          } else {
            set left 0
            set upperLeft 0
          }
          set above [lindex $prior $i]
          # The predictor picks whichever of the three neighbours the plane
          # through them comes closest to (PNG 9.4).
          set estimate [expr {$left + $above - $upperLeft}]
          set distLeft [expr {abs($estimate - $left)}]
          set distAbove [expr {abs($estimate - $above)}]
          set distUpperLeft [expr {abs($estimate - $upperLeft)}]
          if {$distLeft <= $distAbove && $distLeft <= $distUpperLeft} {
            set predictor $left
          } elseif {$distAbove <= $distUpperLeft} {
            set predictor $above
          } else {
            set predictor $upperLeft
          }
          lset line $i [expr {([lindex $line $i] + $predictor) & 255}]
        }
      }
      default {
        return -code error "tclpdf: damaged PNG - filter type $filterType in\
            row $row is not one of the five defined"
      }
    }
    lappend pixels {*}$line
    set prior $line
  }
  return $pixels
}

# The soft mask of a palette image whose tRNS chunk holds partial values.
#
# Only reached when [paletteTransparency] said "softMask" - a palette that is
# merely opaque-or-not takes the colour-key way and is never decoded.
proc ::tclpdf::imagePngAlpha::paletteMask {parsed} {
  set width [dict get $parsed width]
  set height [dict get $parsed height]
  set depth [dict get $parsed bitDepth]
  binary scan [dict get $parsed transparency] cu* table
  # Indices past the end of tRNS are fully opaque (PNG 11.3.2.1).
  set entries [expr {[string length [dict get $parsed palette]] / 3}]
  while {[llength $table] < $entries} {
    lappend table 255
  }

  set rows [unfilter [::tclpdf::filter decodeFlate [dict get $parsed idat]] \
      $width $height $depth 1]
  set stride [expr {($width * $depth + 7) / 8}]
  set alpha {}
  set offset 0
  for {set row 0} {$row < $height} {incr row} {
    set line [lrange $rows $offset [expr {$offset + $stride - 1}]]
    incr offset $stride
    foreach index [Indices $line $depth $width] {
      lappend alpha [expr {$index < [llength $table] ? [lindex $table $index] : 255}]
    }
  }
  return [binary format c* $alpha]
}

# Unpack one row of palette indices. For depths below 8 several indices share a
# byte, most significant bits first (PNG 7.2).
proc ::tclpdf::imagePngAlpha::Indices {line depth width} {
  if {$depth == 8} {
    return [lrange $line 0 [expr {$width - 1}]]
  }
  set perByte [expr {8 / $depth}]
  set mask [expr {(1 << $depth) - 1}]
  set indices {}
  foreach byte $line {
    for {set slot [expr {$perByte - 1}]} {$slot >= 0} {incr slot -1} {
      lappend indices [expr {($byte >> ($slot * $depth)) & $mask}]
      if {[llength $indices] >= $width} {
        break
      }
    }
    if {[llength $indices] >= $width} {
      break
    }
  }
  return $indices
}

package provide tclpdf::imagePngAlpha 1.0
