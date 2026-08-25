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
      style {border horizontal lineColor 0.76}
      headStyle {fill {0.22 0.28 0.40} color 1 fontStyle bold border none}
      bodyStyle {}
      footStyle {fontStyle bold fill 0.91}
      alternateFill 0.965
    }
    grid {
      style {border all lineColor 0.47 lineWidth 0.15}
      headStyle {fill 0.86 fontStyle bold}
      bodyStyle {}
      footStyle {fontStyle bold fill 0.86}
      alternateFill {}
    }
  }
  # The greys are single numbers - DeviceGray - on purpose: a theme colours a
  # table the caller did not colour, and DeviceGray is the one space every
  # PDF/A output intent allows (ISO 19005-2, 6.2.4.3), where DeviceRGB needs
  # an RGB intent and DeviceCMYK a CMYK one. Until 2026-08-17 the greys were
  # RGB triples, and a table with -theme grid was the one failed check in a
  # document with a CMYK intent. The striped head keeps its blue - an RGB
  # value, right under the default sRGB intent and in every plain PDF; a
  # document with a CMYK or grey intent overrides it with -headStyle, which
  # the manual says. Blue has no space that every intent allows.

  # The style every cell starts from. Sizes are in the document unit except
  # the font size, which is in points like everywhere else.
  # direction is here rather than beside -at because it is a property of the
  # CELL, not of the table: an invoice has a right-to-left description column
  # and a left-to-right amount column on the same row. Being a style key it
  # can be said at every level the others can - theme, section, column, cell.
  #
  # hyphenate is here for the same reason and one more. The reason: a table
  # can hold columns in different languages - a German description beside an
  # English note - and a language said once for the whole table cannot say
  # that. The one more: a style key needs no plumbing at all. Adding the name
  # to this list is what makes it sayable in -style, in -headStyle,
  # -bodyStyle and -footStyle, in a -columns entry and in a cell's own style,
  # because all four places check their keys against THIS list; and the
  # cascade in TableStyle already gives the specific value precedence over
  # the general one. A -hyphenate option beside -theme would have been a
  # second road to the same place, with the table wide case cheap and the per
  # column case impossible.
  #
  # The value is textBlock's, unchanged and unchecked here: 0 is off, 1 is
  # the language the document declares, anything else is a language tag. Only
  # the two literals are the switch - "no" is a Tcl false and the tag for
  # Norwegian - and an unloaded language is refused by name where the cell is
  # wrapped, see TableMeasure.
  variable defaults {
    family helvetica fontStyle {} size 9 leading 1.15 padding 1.5
    fill {} color black align left valign top direction ltr hyphenate 0
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
          return -code error -errorcode [list TCLPDF TABLE SUBCOMMAND unknown] \
              "tclpdf: unknown table subcommand\
              \"[lindex $args 0]\" - known are: layout, themes; to draw a\
              table pass options starting with a dash"
        }
      }
    }
    # Everything that can be refused is refused here, before an element is
    # opened or a cell drawn: options, values, widths, and whether every row
    # fits the band. A table refused for a mistyped key leaves the page, the
    # structure tree and the state as they were.
    set prepared [my TablePrepare $args]
    # A tagged document gets the table as a Table element holding TR and
    # TH/TD - the one structure a writer can derive with certainty, because
    # the sections and the grid are already known here.
    #
    # The call is built as a list and run either way, so the body is not
    # written twice; the guard reads the state directly rather than asking
    # [tagged], which would load the structure module for every table in
    # every document.
    set draw [list my TableDrawAll $prepared]
    if {[my state tagged] eq "1"} {
      return [my structure Table -script $draw]
    }
    return [{*}$draw]
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
      repeatHead 1 repeatFoot 0 minRowHeight 0 bottom {} top {} horizontalBreak 0
      repeatColumns 0 decimal . didParseCell {} willDrawCell {} didDrawCell {}
      didDrawPage {}
    } $arguments "table"]
    if {![llength [dict get $options body]] &&
        ![llength [dict get $options head]]} {
      return -code error -errorcode [list TCLPDF TABLE ARGUMENT rows] \
          "tclpdf: table needs -head or -body"
    }
    set options [my TableTheme $options]

    # A column takes the two width keys and anything a style takes - which is
    # what TableStyle lays over the style for that column.
    foreach column [dict get $options columns] {
      ::tclpdf::option keys $column \
          [list width weight {*}[dict keys $::tclpdf::table::defaults]] \
          "column key" table
    }

    # The distances, checked as numbers before anything reads them. Measured
    # before 2026-08-18: "-bottom abc" compared as a string and quietly
    # switched the breaking off, "-minRowHeight -5" was taken, and "-top abc"
    # surfaced from inside the run as a Tcl error about a non-numeric operand,
    # which names neither the option nor the mistake.
    foreach option {top bottom} {
      set value [dict get $options $option]
      if {$value ne {} && (![string is double -strict $value] || $value < 0)} {
        return -code error -errorcode [list TCLPDF TABLE ARGUMENT $option] \
            "tclpdf: -$option takes a distance from the top of\
            the page in the document unit, not \"$value\""
      }
    }
    set minimum [dict get $options minRowHeight]
    if {![string is double -strict $minimum] || $minimum < 0} {
      return -code error -errorcode [list TCLPDF TABLE ARGUMENT minRowHeight] \
          "tclpdf: -minRowHeight takes a height of 0 or more in\
          the document unit, not \"$minimum\""
    }
    set repeat [dict get $options repeatColumns]
    if {![string is integer -strict $repeat] || $repeat < 0} {
      return -code error -errorcode [list TCLPDF TABLE ARGUMENT repeatColumns] \
          "tclpdf: -repeatColumns takes a number of leading\
          columns, 0 or more, not \"$repeat\""
    }

    set left [expr {[dict get $options at] eq {} ? 0 :
        [lindex [dict get $options at] 0]}]
    if {[dict get $options width] eq {}} {
      lassign [my page size] pageWidth ->
      dict set options width [expr {$pageWidth - 2 * max($left, 10)}]
    }
    # Which of -top and -bottom the caller left to the page is remembered,
    # because the answer is asked on every page the table is drawn on - see
    # TableArea. Not asked here: [layout] measures cells and needs neither.
    dict set options topDefault [expr {[dict get $options top] eq {}}]
    dict set options bottomDefault [expr {[dict get $options bottom] eq {}}]
    return $options
  }

  # -top and -bottom for the CURRENT page: the caller's own values where they
  # were given, the type area of the page for the rest - -typeArea when the
  # document has one, five percent of the page height otherwise; see
  # [page typeArea].
  #
  # Derived from the page, NOT from -at. Taking the bottom from the left
  # margin meant a table placed at x=140 got a bottom of 157 instead of
  # 287: it broke after two rows, started again on the new page still
  # below the limit, and produced eleven pages for six rows. And taking
  # the top from -at made a table starting at y=240 continue at 240 on
  # every page after the first, so the further down it began the more
  # pages it burned - the same 60 rows took 2 pages from the top and 60
  # from y=270, one row per page. -at says where THIS table starts,
  # which is an answer to a different question than where the page ends
  # and where the next one begins.
  #
  # And asked again after every page the table adds, not once at the call:
  # the defaults were taken from the page current at the call and carried
  # onto continuation pages of another size - measured on a landscape
  # document whose first page was portrait, the rows of page two ran to
  # 278 mm on a page 210 mm high. [text -paginate] reads the area per page;
  # so does this now. The two checks live here for the same reason: an
  # explicit -top against the default bottom of a smaller continuation page
  # can leave no band at all, and a band nothing fits into is refused rather
  # than filled one row per page.
  method TableArea {options} {
    if {[dict get $options topDefault] || [dict get $options bottomDefault]} {
      lassign [my page typeArea] -> areaTop -> areaBottom
      if {[dict get $options topDefault]} {
        dict set options top $areaTop
      }
      if {[dict get $options bottomDefault]} {
        dict set options bottom $areaBottom
      }
    }
    set top [dict get $options top]
    set bottom [dict get $options bottom]
    lassign [my page size] -> pageHeight
    if {$bottom > $pageHeight} {
      return -code error -errorcode [list TCLPDF TABLE ROOM bottom] \
          "tclpdf: -bottom [format %g $bottom] lies below the\
          foot of page [my page current], which is [format %g $pageHeight]\
          high - -bottom is where a breaking table stops, and has to be on the\
          page"
    }
    if {$bottom <= $top} {
      return -code error -errorcode [list TCLPDF TABLE ROOM bottom] \
          "tclpdf: -bottom [format %g $bottom] is not below\
          -top [format %g $top] on page [my page current] - the table would\
          have no room between where it resumes and where it stops"
    }
    return $options
  }

  # The first half of drawing a table: everything up to, but not including,
  # the first operator. Answers what TableDrawAll takes - the options, where
  # the table starts, and every column group measured.
  method TablePrepare {arguments} {
    set options [my TableOptions $arguments]
    if {[dict get $options at] eq {}} {
      return -code error -errorcode [list TCLPDF TABLE ARGUMENT at] \
          "tclpdf: table needs -at {x y}"
    }
    set options [my TableArea $options]
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
    # Every column group is measured, and measured against the area, before
    # the first one is drawn: a group that cannot be broken to fit is refused
    # with nothing on the page, not after the group before it went out.
    set runs {}
    set first 1
    foreach group $groups {
      # The group's own widths, in the group's own order - the slice renumbers
      # the columns, so passing the full list would measure column 0 of the
      # second group against the width of column 0 of the table.
      set run [my TableMeasureRun $sections \
          [lmap index $group {lindex $widths $index}] $group $options]
      # The first group starts where -at puts it, so its first page may
      # offer more room than the area does (an -at above -top) - or less, in
      # which case it starts on the next page, where the area is the room.
      # Every later group starts at -top on a page of its own.
      set room [expr {[dict get $options bottom] - [dict get $options top]}]
      if {$first} {
        set room [expr {max($room, [dict get $options bottom] - $top)}]
      }
      my TableCheckFit $run $room $options
      lappend runs $run
      set first 0
    }
    return [dict create options $options left $left top $top runs $runs]
  }

  # The second half: the measured column groups onto the pages.
  method TableDrawAll {prepared} {
    dict with prepared {}
    set y $top
    set first 1
    foreach run $runs {
      # The first column group starts where -at puts it. Every group after it
      # sits on a page of its own and starts at the continuation position, for
      # the same reason a continued table does.
      set groupTop $top
      if {!$first} {
        my page add
        set options [my TableArea $options]
        my TableHook didDrawPage $options [dict create page [my page current]]
        set groupTop [dict get $options top]
      }
      set y [my TableRun $run $left $groupTop $options]
      set first 0
    }
    return $y
  }

  # Apply the theme, then the caller's own overrides on top of it.
  method TableTheme {options} {
    set name [dict get $options theme]
    if {![dict exists $::tclpdf::table::themes $name]} {
      return -code error -errorcode [list TCLPDF TABLE THEME $name] \
          "tclpdf: unknown table theme \"$name\" - known are:\
          [join [dict keys $::tclpdf::table::themes] {, }]"
    }
    set theme [dict get $::tclpdf::table::themes $name]
    set style $::tclpdf::table::defaults
    set known [dict keys $style]
    # The four style dictionaries a caller writes, checked here because this is
    # where they are taken in. A mistyped key in a dictionary is silence, not an
    # error - it merges in, nothing reads it, and the caller sees the default.
    foreach option {style headStyle bodyStyle footStyle} {
      ::tclpdf::option keys [dict get $options $option] $known \
          "style key" "table -$option"
    }
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

  # Measure one column group: the three sections sliced to it, every cell
  # wrapped, the row heights, and the sums the run keeps asking for. Nothing
  # is drawn here, which is what lets TableDrawAll measure every group before
  # it draws the first.
  method TableMeasureRun {sections widths group options} {
    set head [my TableSlice [dict get $sections head] $group]
    set body [my TableSlice [dict get $sections body] $group]
    set foot [my TableSlice [dict get $sections foot] $group]

    # One set of decimal tails for all three sections: the total in the foot
    # has to line up with the amounts in the body.
    set tails [my TableDecimalTails [list $head $body $foot] $widths $options]
    set run [dict create widths $widths group $group]
    foreach section {head body foot} grid [list $head $body $foot] {
      lassign [my TableMeasure $grid $widths $options $tails] cells heights
      dict set run ${section}Cells $cells
      dict set run ${section}Heights $heights
      set total 0
      foreach height $heights {
        set total [expr {$total + $height}]
      }
      dict set run ${section}Height $total
    }
    # Rows tied together by a rowSpan must not be split across a page break.
    # The spanning cell is drawn over the full height of the rows it covers,
    # so a break inside the group draws it past the bottom margin - and
    # nothing reports that: no validator, no reader, and the page still opens.
    #
    # So the group, not the row, is the unit that has to fit. TableGroupSpan
    # returns for every row the last row of its group; a row with no span is
    # its own group and behaves exactly as before.
    dict set run groupEnd [my TableGroupSpan [dict get $run bodyCells]]
    return $run
  }

  # What has to follow a body row on the page it starts on: the group of
  # rows it opens (one row, or the rows a rowSpan ties together), and the
  # foot when it comes right after them - under -repeatFoot on every page,
  # and after the last row in any case. Answers the height, or nothing when
  # the index does not open a group; -1 asks for a table without body rows,
  # where the foot follows the head. The head is NOT in it: whether a head
  # stands above the group is the caller's question - it does on the first
  # page and, under -repeatHead, on the page a break leads to, but never on
  # the page the break leaves.
  method TableNeed {run index options} {
    set groupEnd [dict get $run groupEnd]
    set count [llength $groupEnd]
    if {$index < 0} {
      return [dict get $run footHeight]
    }
    if {$index > 0 && [lindex $groupEnd $index-1] >= $index} {
      return {}
    }
    set last [lindex $groupEnd $index]
    set needed 0
    for {set j $index} {$j <= $last} {incr j} {
      set needed [expr {$needed + [lindex [dict get $run bodyHeights] $j]}]
    }
    if {$last == $count - 1 || [dict get $options repeatFoot]} {
      set needed [expr {$needed + [dict get $run footHeight]}]
    }
    return $needed
  }

  # A table is broken between rows, and only there. A head taller than the
  # band between -top and -bottom, a row or a rowSpan group that with the
  # head and foot drawn around it does not fit the band, used to be drawn
  # past -bottom - or, once broken, one row per page - and nothing said so.
  # Refused here, before the first cell is drawn, naming what is too tall
  # and the band it has to fit.
  method TableCheckFit {run room options} {
    set count [llength [dict get $run bodyHeights]]
    set slack 0.001
    set groupEnd [dict get $run groupEnd]
    for {set index [expr {$count ? 0 : -1}]} {$index < $count} {incr index} {
      set needed [my TableNeed $run $index $options]
      if {$needed eq {}} {
        continue
      }
      # The head stands above the first group, and above every group a break
      # leads to when it is repeated.
      if {$index <= 0 || [dict get $options repeatHead]} {
        set needed [expr {$needed + [dict get $run headHeight]}]
      }
      if {$needed <= $room + $slack} {
        continue
      }
      # Which parts stand together, each with its height, so that the caller
      # sees which of them is the tall one.
      set parts {}
      set last [expr {$index < 0 ? -1 : [lindex $groupEnd $index]}]
      if {($index <= 0 || [dict get $options repeatHead])
          && [dict get $run headHeight] > 0} {
        lappend parts "the head ([format %.2f [dict get $run headHeight]])"
      }
      if {$index >= 0} {
        set rows 0
        for {set j $index} {$j <= $last} {incr j} {
          set rows [expr {$rows + [lindex [dict get $run bodyHeights] $j]}]
        }
        if {$last > $index} {
          lappend parts "rows [expr {$index + 1}] to [expr {$last + 1}], tied\
              by a rowSpan ([format %.2f $rows])"
        } else {
          lappend parts "row [expr {$index + 1}] ([format %.2f $rows])"
        }
      }
      if {($index < 0 || $last == $count - 1 || [dict get $options repeatFoot])
          && [dict get $run footHeight] > 0} {
        lappend parts "the foot ([format %.2f [dict get $run footHeight]])"
      }
      if {[llength $parts] > 1} {
        set parts [list "[join [lrange $parts 0 end-1] {, }] and\
            [lindex $parts end]"]
      }
      return -code error -errorcode [list TCLPDF TABLE ROOM together] \
          "tclpdf: what has to stand together on a page -\
          [lindex $parts 0] - is [format %.2f $needed] high, more than the\
          [format %.2f $room] between -top [format %g [dict get $options top]]\
          and -bottom [format %g [dict get $options bottom]] - a table is\
          broken between rows, and every row has to fit that band with what\
          is drawn around it"
    }
    return
  }

  # Draw one measured column group across as many pages as it takes.
  method TableRun {run left top options} {
    set widths [dict get $run widths]
    set group [dict get $run group]
    set headCells [dict get $run headCells]
    set headHeights [dict get $run headHeights]
    set bodyCells [dict get $run bodyCells]
    set bodyHeights [dict get $run bodyHeights]
    set footCells [dict get $run footCells]
    set footHeights [dict get $run footHeights]
    set bottom [dict get $options bottom]

    set y $top
    # Where this table sits on the CURRENT page: the -at position on the first
    # page, the continuation position on every page after it. Both the rows and
    # the frame of "-border outer" hang off it - drawing the frame from $top on
    # a later page would start it where the table began on the first, which for
    # a table starting at y=240 is 225 mm above its own rows.
    set pageTop $top
    # The head goes with the first row group, or with the foot when there
    # are no rows: when that does not fit below where the table starts, the
    # table starts on the next page instead. Measured before 2026-08-18: the
    # head was set below -bottom, or alone at the foot of the page, and the
    # rows followed on the next - an orphan head nothing reported. Nothing
    # is drawn on the page left behind, so didDrawPage is not told of it.
    set needed [expr {[dict get $run headHeight] +
        [my TableNeed $run [expr {[llength $bodyCells] ? 0 : -1}] $options]}]
    if {$y + $needed > $bottom} {
      my page add
      set options [my TableArea $options]
      set bottom [dict get $options bottom]
      set pageTop [dict get $options top]
      set y $pageTop
    }
    set y [my TableSection $headCells $headHeights $widths $group $left $y $options]
    for {set index 0} {$index < [llength $bodyCells]} {incr index} {
      set row [lindex $bodyCells $index]
      set height [lindex $bodyHeights $index]
      # Only ask at a group boundary. Inside a group there is nothing to
      # decide - it was decided when the group started; and the first group
      # was decided above, together with the head.
      set needed [my TableNeed $run $index $options]
      if {$index > 0 && $needed ne {} && $y + $needed > $bottom} {
        if {[dict get $options repeatFoot]} {
          set y [my TableSection $footCells $footHeights $widths $group \
              $left $y $options]
        }
        # The frame of "-border outer" belongs to the page, not to the table:
        # every page gets its own, from where the block started down to here.
        # It is drawn before the hook so a running footer can sit below it.
        my TableDrawFrame [dict get $options style] $widths $left $pageTop $y
        my TableHook didDrawPage $options [dict create page [my page current] y $y]
        my page add
        # The area of the page just added, not the one the table began on.
        set options [my TableArea $options]
        set bottom [dict get $options bottom]
        set pageTop [dict get $options top]
        set y $pageTop
        if {[dict get $options repeatHead]} {
          set y [my TableSection $headCells $headHeights $widths $group \
              $left $y $options]
        }
      }
      set y [my TableSection [list $row] [list $height] $widths $group \
          $left $y $options]
    }
    set y [my TableSection $footCells $footHeights $widths $group $left $y $options]
    my TableDrawFrame [dict get $options style] $widths $left $pageTop $y
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
      set draw [list my TableRowCells $row $height $widths $left $y $options]
      if {[my state tagged] eq "1"} {
        my structure TR -script $draw
      } else {
        {*}$draw
      }
      set y [expr {$y + $height}]
    }
    return $y
  }

  # One row's cells. Split out of TableSection so that the row can be wrapped
  # in a TR without the loop body existing twice.
  method TableRowCells {row height widths left y options} {
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
      # A head cell is a TH, everything else a TD - the section is on the
      # cell already, put there when the grid was normalised.
      #
      # A TH gets Scope Column, and only that value: tclpdf's head is a row of
      # cells above the body, so every one of them heads a COLUMN. A row
      # header would be Scope Row, and there is no way to say "this column is
      # the header" here - inventing one from the first cell would be a guess.
      #
      # The spans are written out because a reader rebuilding the grid cannot
      # measure the page to find them.
      set draw [list my TableDrawCell $cell $x $y $cellHeight]
      if {[my state tagged] eq "1"} {
        set head [expr {[dict get $cell section] eq "head"}]
        set attributes {}
        if {$head} {
          lappend attributes -scope Column
        }
        foreach {option key} {colSpan colSpan rowSpan rowSpan} {
          if {[dict get $cell $key] > 1} {
            lappend attributes -$option [dict get $cell $key]
          }
        }
        my structure [expr {$head ? "TH" : "TD"}] {*}$attributes -script $draw
      } else {
        {*}$draw
      }
      my TableHook didDrawCell $options $cell
    }
    return
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

package provide tclpdf::table 1.8
