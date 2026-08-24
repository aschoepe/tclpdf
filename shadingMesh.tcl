#
# tclpdf - PDF generation for Tcl
#
# shadingMesh - the mesh shadings, types 4 to 7 (8.7.4.5.5 to 8.7.4.5.8)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Types 2 and 3 say where a colour run goes and let the reader work out every
# point in between; types 4 to 7 hand the reader the points themselves. The
# shading is no longer a dictionary but a STREAM of packed numbers, and that
# stream is the whole of the difference:
#
#   4  triangles  free-form Gouraud mesh: a vertex is a point and a colour,
#                 and an edge flag says whether it starts a new triangle or
#                 hangs off the previous one
#   5  lattice    the same vertices without the flags, read as rows of a
#                 fixed width - a grid, which is what most meshes are
#   6  coons      a patch bounded by four cubic Bezier edges: twelve control
#                 points and one colour per corner
#   7  tensor     the same with four interior points on top, sixteen in all,
#                 which lets the inside of the patch be shaped as well
#
# All four pack their numbers the same way, so the packing lives ONCE, in
# [MeshStream] - the alternative is four encoders, three of which are never
# looked at again.
#
# The field widths are fixed at 16 bits per coordinate, 8 per colour
# component and 8 for the flag. Not for want of options: chosen so that every
# field is a whole number of BYTES. The standard allows 1, 2, 4, 12 and 32
# bits as well (Table 79), and any of those turns [binary format] into a bit
# shifter for no gain - 16 bits over the mesh's own bounding box is a
# resolution of one part in 65535 of the drawing, far below what a reader
# renders, and 8 bits per component is what the vertex colours of a Gouraud
# mesh are interpolated FROM, not the number of shades that come out.
#
# /Decode is the range those integers stand for (8.7.4.5.5, Table 79): the
# bounding box of the mesh for the coordinates, 0 to 1 for every component.
# It is computed from the points that are actually there rather than from the
# page, because the encoding resolution is spent on the range it names - a
# mesh of two millimetres inside an A4 Decode would quantise to a handful of
# distinct positions.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::color 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::shadingMesh {}

oo::define ::tclpdf::document::document {

  # The entry point shading.tcl calls for kinds triangles, lattice, coons and
  # tensor. Returns the object number of the shading stream.
  #
  # The order is the order the rest of shading.tcl keeps and for the same
  # reason: everything that can still be refused is read BEFORE the version
  # floor is pinned, before the colour space is recorded and before a single
  # object is written. A mesh has a lot that can be refused - a vertex that
  # is not a point, an edge flag that starts nothing, a patch with eleven
  # control points - and a stream written for a mesh that is then thrown out
  # is an object no reader ever reaches and every validator counts.
  method ShadingMeshObject {kind options what} {
    switch -- $kind {
      triangles - lattice {set records [my MeshVertices $kind $options $what]}
      coons - tensor {set records [my MeshPatches $kind $options $what]}
      default {
        return -code error -errorcode [list TCLPDF SHADING KIND $kind] \
            "tclpdf: unknown mesh shading kind \"$kind\" - known are:\
            triangles, lattice, coons, tensor"
      }
    }
    # One colour space for the whole mesh, decided over ALL the colours at
    # once: a grey corner among coloured ones is promoted rather than
    # refused, exactly as the stops of a gradient are.
    set specs {}
    foreach record $records {
      lappend specs {*}[lindex $record 2]
    }
    lassign [my ShadingColours $specs $what] space parsed
    # The parsed colours go back into the records they came from, in order.
    set filled {}
    set index 0
    foreach record $records {
      lassign $record flag points colours
      set taken [lrange $parsed $index [expr {$index + [llength $colours] - 1}]]
      incr index [llength $colours]
      lappend filled [list $flag $points $taken]
    }
    set components [llength [lindex $parsed 0 1]]
    lassign [my MeshStream $filled $components] data decode
    # Mesh shadings are PDF 1.3 like every other shading (PDF Reference 1.7,
    # 4.6.3), asked for AFTER the last value that can be refused so that a
    # refused mesh does not pin the floor of a document that never got one.
    my RequireVersion 1.3 "shading"
    my ColourSpaceUsed $space $what
    set pairs [list ShadingType [my MeshType $kind] ColorSpace /$space \
        BitsPerCoordinate 16 BitsPerComponent 8]
    if {$kind eq "lattice"} {
      # Table 80: a lattice mesh has no edge flags at all - the rows say
      # where a triangle ends. Writing /BitsPerFlag anyway would describe a
      # field that is not in the stream.
      lappend pairs VerticesPerRow [dict get $options perRow]
    } else {
      lappend pairs BitsPerFlag 8
    }
    lappend pairs Decode [::tclpdf::pdfObj arr \
        [lmap value $decode {::tclpdf::pdfObj num $value}]]
    return [my streamObject $pairs $data]
  }

  method MeshType {kind} {
    return [dict get {triangles 4 lattice 5 coons 6 tensor 7} $kind]
  }

  # -- the two vertex kinds, 4 and 5 -----------------------------------------

  # A vertex is {x y colour}, with an optional fourth word for the edge flag
  # of a free-form mesh. The flag sits WITH its vertex rather than in a list
  # of its own: a separate -flags is a second list to keep in step with the
  # first, and the day it slips the mesh still writes - as triangles nobody
  # asked for.
  method MeshVertices {kind options what} {
    set vertices [dict get $options vertices]
    if {[llength $vertices] < 3} {
      return -code error -errorcode [list TCLPDF SHADING VERTICES $what] \
          "tclpdf: $what needs -vertices, at least three of them {x y colour}\
          - a mesh is made of triangles"
    }
    set mapped [expr {[dict get $options matrix] eq {}}]
    set records {}
    set flags {}
    set index 0
    foreach vertex $vertices {
      if {[llength $vertex] < 3 || [llength $vertex] > 4} {
        return -code error -errorcode [list TCLPDF SHADING VERTEX $index $what] \
            "tclpdf: vertex $index of $what is {x y colour} with an optional\
            edge flag, not \"$vertex\""
      }
      lassign $vertex x y colour flag
      foreach {name value} [list x $x y $y] {
        if {![string is double -strict $value]} {
          return -code error \
              -errorcode [list TCLPDF SHADING VERTEX $index $what] \
              "tclpdf: the $name of vertex $index of $what is a number, not\
              \"$value\""
        }
      }
      if {$kind eq "lattice"} {
        # Table 80 again, from the other side: a vertex of a lattice mesh
        # carries no flag, so one written here would be read by nobody.
        # Silence is the worse answer - the caller wrote a connection that
        # the type cannot express and would get a grid instead.
        if {[llength $vertex] == 4} {
          return -code error \
              -errorcode [list TCLPDF SHADING FLAG $index $what] \
              "tclpdf: vertex $index of $what carries an edge flag, and a\
              lattice mesh has none - its rows say where a triangle ends\
              (ISO 32000-2, 8.7.4.5.6); use the triangles kind for flags,\
              or drop the flag"
        }
        set flag {}
      } else {
        if {$flag eq {}} {
          set flag 0
        }
        if {$flag ni {0 1 2}} {
          return -code error \
              -errorcode [list TCLPDF SHADING FLAG $index $what] \
              "tclpdf: the edge flag of vertex $index of $what is 0, 1 or 2,\
              not \"$flag\" - 0 begins a triangle, 1 and 2 continue the\
              previous one (ISO 32000-2, 8.7.4.5.5)"
        }
      }
      lappend flags $flag
      lappend records [list $flag [my MeshPoint $x $y $mapped] [list $colour]]
      incr index
    }
    if {$kind eq "lattice"} {
      my MeshRows $options $what [llength $records]
    } else {
      my MeshTriangles $flags $what
    }
    return $records
  }

  # The edge flags of a free-form mesh, held to what 8.7.4.5.5 says they
  # mean. A vertex with flag 0 BEGINS a triangle and shall be followed by two
  # more with flag 0; 1 and 2 each add a single vertex to the triangle before
  # them, so neither can stand first.
  #
  # Without this check the ordinary mistake - four vertices, all flags left at
  # 0 - writes a stream whose last vertex has no triangle. Readers differ on
  # what they do with it: poppler draws the first triangle and drops the rest,
  # and no validator says a word.
  method MeshTriangles {flags what} {
    set count [llength $flags]
    set index 0
    while {$index < $count} {
      if {[lindex $flags $index] == 0} {
        if {$index + 2 >= $count || [lindex $flags $index+1] != 0
            || [lindex $flags $index+2] != 0} {
          return -code error \
              -errorcode [list TCLPDF SHADING TRIANGLE $index $what] \
              "tclpdf: vertex $index of $what begins a triangle, and a\
              triangle needs three vertices with edge flag 0 (ISO 32000-2,\
              8.7.4.5.5) - $count vertices in all; give three, or continue\
              from the previous triangle with flag 1 or 2"
        }
        incr index 3
      } else {
        if {$index == 0} {
          return -code error \
              -errorcode [list TCLPDF SHADING TRIANGLE 0 $what] \
              "tclpdf: the first vertex of $what has edge flag\
              [lindex $flags 0], and there is no previous triangle to\
              continue - the first three vertices carry flag 0"
        }
        incr index
      }
    }
    return
  }

  # -perRow of a lattice mesh: /VerticesPerRow (Table 80), at least 2, and
  # the vertices are read as whole rows of it.
  method MeshRows {options what count} {
    set perRow [dict get $options perRow]
    if {![string is integer -strict $perRow] || $perRow < 2} {
      return -code error -errorcode [list TCLPDF SHADING PERROW $what] \
          "tclpdf: -perRow of $what is a whole number of 2 or more, not\
          \"$perRow\" - it is how many vertices one row of the lattice holds\
          (ISO 32000-2, 8.7.4.5.6)"
      }
    if {$count % $perRow} {
      return -code error -errorcode [list TCLPDF SHADING PERROW $what] \
          "tclpdf: $what has $count vertices, which is not a whole number of\
          rows of $perRow - a lattice mesh is a rectangle of vertices"
    }
    if {$count / $perRow < 2} {
      return -code error -errorcode [list TCLPDF SHADING PERROW $what] \
          "tclpdf: $what has one row of $perRow vertices, and a lattice mesh\
          needs at least two - a row on its own spans no triangle"
    }
    return
  }

  # -- the two patch kinds, 6 and 7 ------------------------------------------

  # A patch is a dictionary {points {...} colors {...}}: twelve control
  # points for a Coons patch, sixteen for a tensor one, and one colour per
  # corner. Written as a dictionary rather than as two positional lists for
  # the reason [option keys] exists - a mistyped key is an error here rather
  # than silence.
  #
  # The points run around the boundary starting at the first corner: four
  # points per edge with the corners shared, so p1 p2 p3 p4 p5 ... p12, and
  # the corner colours belong to points 1, 4, 7 and 10 in that order
  # (Figure 46). A tensor patch adds the four interior points last.
  #
  # Only complete patches - edge flag 0 - are written. Flags 1 to 3 let a
  # patch borrow an edge and two colours from the one before it, which saves
  # bytes and costs a second set of rules for how many points a patch then
  # has; a caller who repeats the shared edge gets the same picture, and the
  # saving is in the file rather than in the drawing.
  method MeshPatches {kind options what} {
    set patches [dict get $options patches]
    if {![llength $patches]} {
      return -code error -errorcode [list TCLPDF SHADING PATCHES $what] \
          "tclpdf: $what needs -patches, each of them a dictionary\
          {points {...} colors {...}}"
    }
    set need [expr {$kind eq "coons" ? 12 : 16}]
    set mapped [expr {[dict get $options matrix] eq {}}]
    set records {}
    set index 0
    foreach patch $patches {
      ::tclpdf::option keys $patch {points colors} "patch key" $what
      foreach key {points colors} {
        if {![dict exists $patch $key]} {
          return -code error \
              -errorcode [list TCLPDF SHADING PATCH $index $what] \
              "tclpdf: patch $index of $what has no \"$key\" - a patch is\
              {points {...} colors {...}}"
        }
      }
      set points [dict get $patch points]
      if {[llength $points] != $need} {
        return -code error \
            -errorcode [list TCLPDF SHADING PATCH $index $what] \
            "tclpdf: patch $index of $what has [llength $points] control\
            points and a $kind patch has $need, each of them {x y} (ISO\
            32000-2, [expr {$kind eq "coons" ? {8.7.4.5.7} : {8.7.4.5.8}}])"
      }
      set colours [dict get $patch colors]
      if {[llength $colours] != 4} {
        return -code error \
            -errorcode [list TCLPDF SHADING PATCH $index $what] \
            "tclpdf: patch $index of $what has [llength $colours] colours and\
            a patch has one per corner, four in all"
      }
      set flat {}
      set at 0
      foreach point $points {
        if {[llength $point] != 2} {
          return -code error \
              -errorcode [list TCLPDF SHADING PATCH $index $what] \
              "tclpdf: control point $at of patch $index of $what is a point\
              {x y}, not \"$point\""
        }
        lassign $point x y
        foreach {name value} [list x $x y $y] {
          if {![string is double -strict $value]} {
            return -code error \
                -errorcode [list TCLPDF SHADING PATCH $index $what] \
                "tclpdf: the $name of control point $at of patch $index of\
                $what is a number, not \"$value\""
          }
        }
        lappend flat {*}[my MeshPoint $x $y $mapped]
        incr at
      }
      lappend records [list 0 $flat $colours]
      incr index
    }
    return $records
  }

  # -- one point, one stream -------------------------------------------------

  # A point of the mesh in the space the shading is written in. The rule is
  # the one [ShadingCoords] follows for types 2 and 3, and it has to be the
  # same one: without -matrix the numbers are document coordinates and go
  # through [coords], which applies the unit and mirrors y; with -matrix the
  # caller has said the numbers are already in the space that matrix maps
  # from, and doing both would apply the transform twice.
  method MeshPoint {x y mapped} {
    if {$mapped} {
      return [my coords $x $y]
    }
    return [list $x $y]
  }

  # The packed stream and the /Decode array that says what its integers mean.
  #
  # A record is {flag points colours}: the flag, or the empty string where
  # the type has none; the points as a flat list of already-mapped x y pairs;
  # the colours as parsed colours, one per corner. Every field is a whole
  # number of bytes, so [binary format] writes it without any bit shifting.
  method MeshStream {records components} {
    set xs {}
    set ys {}
    foreach record $records {
      foreach {x y} [lindex $record 1] {
        lappend xs $x
        lappend ys $y
      }
    }
    lassign [my MeshRange $xs] xMin xMax
    lassign [my MeshRange $ys] yMin yMax
    set decode [list $xMin $xMax $yMin $yMax]
    for {set index 0} {$index < $components} {incr index} {
      lappend decode 0 1
    }
    set data {}
    foreach record $records {
      lassign $record flag points colours
      if {$flag ne {}} {
        append data [binary format c $flag]
      }
      foreach {x y} $points {
        append data [binary format SS [my MeshInteger $x $xMin $xMax 65535] \
            [my MeshInteger $y $yMin $yMax 65535]]
      }
      foreach colour $colours {
        foreach value [lindex $colour 1] {
          append data [binary format c [my MeshInteger $value 0 1 255]]
        }
      }
    }
    return [list $data $decode]
  }

  # The range one axis of the mesh spans. A mesh that is a straight line has
  # none in the other direction, and a /Decode entry whose two numbers are
  # equal makes every coordinate on that axis encode to the same integer -
  # the mesh collapses, the file is valid and the page shows a line or
  # nothing. Widened by a point instead, which the encoding then spends its
  # resolution on and no reader can tell apart from the exact value.
  method MeshRange {values} {
    set low [::tcl::mathfunc::min {*}$values]
    set high [::tcl::mathfunc::max {*}$values]
    if {$high - $low < 1e-9} {
      return [list $low [expr {$low + 1.0}]]
    }
    return [list $low $high]
  }

  # One value as the integer /Decode maps back to it. Clamped: a colour
  # component arrives already held to 0..1 by [color parse], and a coordinate
  # cannot leave the range that was computed from it - the clamp is what
  # keeps a rounding step at the very edge from writing 65536 into a
  # sixteen-bit field, which [binary format] would truncate to 0 and put the
  # corner of the mesh at the opposite side.
  method MeshInteger {value low high span} {
    set number [expr {int(round(($value - $low) / ($high - $low) * $span))}]
    if {$number < 0} {
      return 0
    }
    if {$number > $span} {
      return $span
    }
    return $number
  }
}

package provide tclpdf::shadingMesh 1.0
