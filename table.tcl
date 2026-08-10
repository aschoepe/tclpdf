#
# tclpdf - PDF generation for Tcl
#
# table - the public face of the table topic
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Measuring is in tableLayout.tcl, drawing a cell in tableDraw.tcl; neither is
# loaded from outside. What is here is the run: sections, page breaks, column
# groups and the four hooks.
#
# Usage:
#
#   set y [$doc table \
#       -head {{Pos Artikel Menge Preis}} \
#       -body $rows \
#       -foot {{{text "Summe" colSpan 3 align right} "1.234,00"}} \
#       -at {20 45} -width 170 -theme striped \
#       -columns {{width 12} {} {width 20 align right} {width 25 align right}}]
#
# The return value is the y coordinate BELOW the table, on the page it ended
# on, and the reason a caller can put a total underneath without counting
# rows.
#
# Hooks are command prefixes, called with one dictionary:
#
#   didParseCell   before measuring. Returns the cell, possibly changed - this
#                  is where a negative amount turns red.
#   willDrawCell   before drawing. Return 0 to draw nothing at all.
#   didDrawCell    after drawing, for an overlay.
#   didDrawPage    after each page, for a running header or a page number.
#
# The order matters: didParseCell has to run before anything is measured,
# because changing a font size changes how the text wraps and therefore how
# tall the row comes out.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::tableLayout 1.0-
package require tclpdf::tableDraw 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::table {
  namespace export {[a-z]*}
  namespace ensemble create

  # The themes, as overrides on the defaults. A theme is nothing but three
  # style dictionaries - there is no mechanism behind it, on purpose.
  variable themes {
    plain {
      style {border none}
      headStyle {fontStyle bold}
      bodyStyle {}
      footStyle {fontStyle bold}
      alternateFill {}
    }
    striped {
      style {border horizontal lineColor {0.75 0.75 0.78}}
      headStyle {fill {0.22 0.28 0.40} color white fontStyle bold border none}
      bodyStyle {}
      footStyle {fontStyle bold fill {0.90 0.90 0.93}}
      alternateFill {0.96 0.96 0.98}
    }
    grid {
      style {border all lineColor {0.45 0.45 0.50} lineWidth 0.15}
      headStyle {fill {0.85 0.85 0.88} fontStyle bold}
      bodyStyle {}
      footStyle {fontStyle bold fill {0.85 0.85 0.88}}
      alternateFill {}
    }
  }

  # The style every cell starts from. Sizes are in the document unit except
  # the font size, which is in points like everywhere else.
  variable defaults {
    family helvetica fontStyle {} size 9 leading 1.15 padding 1.5
    fill {} color black align left valign top
    border horizontal lineColor {0.6 0.6 0.6} lineWidth 0.1
  }
}

oo::define ::tclpdf::document::document {

  # $doc table -at {x y} ...        draw, and return the y below it
  # $doc table layout ...           measure only, and return what was measured
  method table {args} {
    if {[llength $args] && [string index [lindex $args 0] 0] ne "-"} {
      switch -- [lindex $args 0] {
        layout {return [my TableLayout {*}[lrange $args 1 end]]}
        themes {return [dict keys $::tclpdf::table::themes]}
        default {
          return -code error "tclpdf: unknown table subcommand\
              \"[lindex $args 0]\" - known are: layout, themes; to draw a\
              table pass options starting with a dash"
        }
      }
    }
    return [my TableDrawAll $args]
  }

  # What a table WOULD come out as, without drawing anything: the column
  # widths, the grid with every cell measured, and the total height.
  #
  # This is what a caller needs to decide whether a table still fits on the
  # page - and what makes the measuring testable without reading it back out
  # of a content stream.
  method TableLayout {args} {
    set options [my TableOptions $args]
    set sections {}
    foreach section {head body foot} {
      dict set sections $section [my TableNormalize \
          [dict get $options $section] $section]
    }
    set sections [my TableParseHook $sections $options]
    set widths [my TableColumnWidths [dict values $sections] \
        [dict get $options columns] [dict get $options width] $options]
    set tails [my TableDecimalTails [dict values $sections] $widths $options]
    set result [dict create widths $widths height 0]
    foreach section {head body foot} {
      lassign [my TableMeasure [dict get $sections $section] $widths $options \
          $tails] cells heights
      dict set result $section $cells
      dict set result ${section}Heights $heights
      foreach height $heights {
        dict set result height [expr {[dict get $result height] + $height}]
      }
    }
    return $result
  }

  # Options, theme and the two defaults that need the page size. Shared by
  # drawing and by [layout] so the two cannot answer differently.
  method TableOptions {arguments} {
    set options [::tclpdf::option parse {
      head {} body {} foot {} at {} width {} columns {} theme striped
      style {} headStyle {} bodyStyle {} footStyle {} alternateFill {}
      repeatHead 1 repeatFoot 0 minRowHeight 0 bottom {} horizontalBreak 0
      repeatColumns 0 decimal . didParseCell {} willDrawCell {} didDrawCell {}
      didDrawPage {}
    } $arguments "table"]
    if {![llength [dict get $options body]] &&
        ![llength [dict get $options head]]} {
      return -code error "tclpdf: table needs -head or -body"
    }
    set options [my TableTheme $options]

    set left [expr {[dict get $options at] eq {} ? 0 :
        [lindex [dict get $options at] 0]}]
    if {[dict get $options width] eq {}} {
      lassign [my page size] pageWidth ->
      dict set options width [expr {$pageWidth - 2 * max($left, 10)}]
    }
    if {[dict get $options bottom] eq {}} {
      lassign [my page size] -> pageHeight
      # A margin below the table, not the paper edge - a table ending flush
      # with the sheet is a defect nobody reports either.
      #
      # Derived from the page height, NOT from the left margin. Taking it
      # from -at meant a table placed at x=140 got a bottom of 157 instead of
      # 287: it broke after two rows, started again on the new page still
      # below the limit, and produced eleven pages for six rows. The left
      # edge says nothing about the bottom one.
      dict set options bottom [expr {$pageHeight - $pageHeight * 0.05}]
    }
    return $options
  }

  method TableDrawAll {arguments} {
    set options [my TableOptions $arguments]
    if {[dict get $options at] eq {}} {
      return -code error "tclpdf: table needs -at {x y}"
    }
    lassign [dict get $options at] left top

    set sections {}
    foreach section {head body foot} {
      dict set sections $section [my TableNormalize \
          [dict get $options $section] $section]
    }
    set sections [my TableParseHook $sections $options]
    set widths [my TableColumnWidths [dict values $sections] \
        [dict get $options columns] [dict get $options width] $options]

    set groups [my TableGroups $widths $options]
    set y $top
    set first 1
    foreach group $groups {
      if {!$first} {
        my page add
        my TableHook didDrawPage $options [dict create page [my page current]]
        set y $top
      }
      # The group's own widths, in the group's own order - the slice renumbers
      # the columns, so passing the full list would measure column 0 of the
      # second group against the width of column 0 of the table.
      set y [my TableRun $sections [lmap index $group {lindex $widths $index}] \
          $group $left $top $options]
      set first 0
    }
    return $y
  }

  # Apply the theme, then the caller's own overrides on top of it.
  method TableTheme {options} {
    set name [dict get $options theme]
    if {![dict exists $::tclpdf::table::themes $name]} {
      return -code error "tclpdf: unknown table theme \"$name\" - known are:\
          [join [dict keys $::tclpdf::table::themes] {, }]"
    }
    set theme [dict get $::tclpdf::table::themes $name]
    set style $::tclpdf::table::defaults
    dict for {key value} [dict get $theme style] {
      dict set style $key $value
    }
    dict for {key value} [dict get $options style] {
      dict set style $key $value
    }
    dict set options style $style
    foreach section {head body foot} {
      set merged [dict get $theme ${section}Style]
      dict for {key value} [dict get $options ${section}Style] {
        dict set merged $key $value
      }
      dict set options ${section}Style $merged
    }
    if {[dict get $options alternateFill] eq {}} {
      dict set options alternateFill [dict get $theme alternateFill]
    }
    return $options
  }

  # Run didParseCell over every cell, in reading order, before anything is
  # measured.
  method TableParseHook {sections options} {
    if {[dict get $options didParseCell] eq {}} {
      return $sections
    }
    dict for {name grid} $sections {
      set rows {}
      foreach row $grid {
        set cells {}
        foreach cell $row {
          set changed [my TableHook didParseCell $options $cell]
          lappend cells [expr {$changed eq {} ? $cell : $changed}]
        }
        lappend rows $cells
      }
      dict set sections $name $rows
    }
    return $sections
  }

  # Split the columns into groups that fit the width. Without
  # -horizontalBreak there is exactly one group and the widths were already
  # scaled to fit, so this costs nothing in the common case.
  method TableGroups {widths options} {
    set count [llength $widths]
    set all {}
    for {set index 0} {$index < $count} {incr index} {
      lappend all $index
    }
    if {![dict get $options horizontalBreak]} {
      return [list $all]
    }
    set limit [dict get $options width]
    set repeat [lrange $all 0 [dict get $options repeatColumns]-1]
    set repeatWidth 0
    foreach index $repeat {
      set repeatWidth [expr {$repeatWidth + [lindex $widths $index]}]
    }
    set groups {}
    set current $repeat
    set used $repeatWidth
    foreach index [lrange $all [dict get $options repeatColumns] end] {
      set width [lindex $widths $index]
      if {[llength $current] > [llength $repeat] && $used + $width > $limit} {
        lappend groups $current
        set current $repeat
        set used $repeatWidth
      }
      lappend current $index
      set used [expr {$used + $width}]
    }
    if {[llength $current] > [llength $repeat]} {
      lappend groups $current
    }
    return [expr {[llength $groups] ? $groups : [list $all]}]
  }

  # Draw one column group across as many pages as it takes.
  method TableRun {sections widths group left top options} {
    set y $top
    set head [my TableSlice [dict get $sections head] $group]
    set body [my TableSlice [dict get $sections body] $group]
    set foot [my TableSlice [dict get $sections foot] $group]

    # One set of decimal tails for all three sections: the total in the foot
    # has to line up with the amounts in the body.
    set tails [my TableDecimalTails [list $head $body $foot] $widths $options]
    lassign [my TableMeasure $head $widths $options $tails] headCells headHeights
    lassign [my TableMeasure $body $widths $options $tails] bodyCells bodyHeights
    lassign [my TableMeasure $foot $widths $options $tails] footCells footHeights

    set footHeight 0
    foreach height $footHeights {
      set footHeight [expr {$footHeight + $height}]
    }
    set bottom [dict get $options bottom]

    set y [my TableSection $headCells $headHeights $widths $group $left $y $options]
    set headY $y
    # Rows tied together by a rowSpan must not be split across a page break.
    # The spanning cell is drawn over the full height of the rows it covers,
    # so a break inside the group draws it past the bottom margin - and
    # nothing reports that: no validator, no reader, and the page still opens.
    #
    # So the group, not the row, is the unit that has to fit. TableGroupSpan
    # returns for every row the last row of its group; a row with no span is
    # its own group and behaves exactly as before.
    set groupEnd [my TableGroupSpan $bodyCells]
    set groupBottom -1
    for {set index 0} {$index < [llength $bodyCells]} {incr index} {
      set row [lindex $bodyCells $index]
      set height [lindex $bodyHeights $index]
      set reserve [expr {[dict get $options repeatFoot] ? $footHeight : 0}]
      # Only ask at a group boundary. Inside a group there is nothing to
      # decide - it was decided when the group started.
      set needed 0
      if {$index > $groupBottom} {
        set groupBottom [lindex $groupEnd $index]
        for {set j $index} {$j <= $groupBottom} {incr j} {
          set needed [expr {$needed + [lindex $bodyHeights $j]}]
        }
      }
      if {$needed && $y + $needed + $reserve > $bottom} {
        if {[dict get $options repeatFoot]} {
          set y [my TableSection $footCells $footHeights $widths $group \
              $left $y $options]
        }
        my TableHook didDrawPage $options [dict create page [my page current] y $y]
        my page add
        set y $top
        if {[dict get $options repeatHead]} {
          set y [my TableSection $headCells $headHeights $widths $group \
              $left $y $options]
        }
      }
      set y [my TableSection [list $row] [list $height] $widths $group \
          $left $y $options]
    }
    set y [my TableSection $footCells $footHeights $widths $group $left $y $options]
    my TableHook didDrawPage $options [dict create page [my page current] y $y]
    return $y
  }

  # For every row, the index of the LAST row of the group it belongs to.
  #
  # A cell with rowSpan n in row i reaches to row i+n-1. Groups that overlap
  # merge, which is why the reach is extended in a second pass: a span
  # starting inside another group pushes the whole group's end further down,
  # and without that pass a break could still land between them.
  method TableGroupSpan {rows} {
    set ends {}
    for {set index 0} {$index < [llength $rows]} {incr index} {
      set end $index
      foreach cell [lindex $rows $index] {
        set reach [expr {$index + [dict get $cell rowSpan] - 1}]
        if {$reach > $end} {
          set end $reach
        }
      }
      if {$end >= [llength $rows]} {
        # A span reaching past the last row is malformed input, not a reason
        # to walk off the end of the list.
        set end [expr {[llength $rows] - 1}]
      }
      lappend ends $end
    }
    for {set index [expr {[llength $ends] - 1}]} {$index >= 0} {incr index -1} {
      set end [lindex $ends $index]
      for {set j [expr {$index + 1}]} {$j <= $end} {incr j} {
        if {[lindex $ends $j] > $end} {
          set end [lindex $ends $j]
        }
      }
      lset ends $index $end
    }
    return $ends
  }

  # Keep only the cells belonging to a column group, and shift them so that
  # the group starts at column zero.
  method TableSlice {grid group} {
    if {$group eq {}} {
      return $grid
    }
    set rows {}
    foreach row $grid {
      set cells {}
      foreach cell $row {
        if {[dict get $cell column] ni $group} {
          continue
        }
        dict set cell column [lsearch -exact $group [dict get $cell column]]
        lappend cells $cell
      }
      lappend rows $cells
    }
    return $rows
  }

  # Draw a run of rows that is known to fit.
  method TableSection {rows heights widths group left y options} {
    foreach row $rows height $heights {
      foreach cell $row {
        set x $left
        for {set index 0} {$index < [dict get $cell column]} {incr index} {
          set x [expr {$x + [lindex $widths $index]}]
        }
        set cellHeight $height
        if {[dict get $cell rowSpan] > 1} {
          set cellHeight [dict get $cell spanHeight]
        }
        dict set cell x $x
        dict set cell y $y
        set decision [my TableHook willDrawCell $options $cell]
        if {$decision eq "0"} {
          continue
        }
        my TableDrawCell $cell $x $y $cellHeight
        my TableHook didDrawCell $options $cell
      }
      set y [expr {$y + $height}]
    }
    return $y
  }

  # Call a hook, if one was given. The document is appended so that a hook can
  # draw without having captured it.
  method TableHook {name options payload} {
    set hook [dict get $options $name]
    if {$hook eq {}} {
      return {}
    }
    return [uplevel #0 [list {*}$hook $payload [self]]]
  }
}

package provide tclpdf::table 1.0
