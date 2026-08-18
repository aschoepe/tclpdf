#
# tclpdf - PDF generation for Tcl
#
# structureReport - what the structure tree looks like, as facts for a checker
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   $doc structureReport   -> {headings {1 2 2 3} rows {{3 3 3}} lists {...} types {...}}
#
# Answers questions about the tree as a whole - the heading levels in order,
# the column count of every table row, the shape of every list - and judges
# none of them; ua.tcl reads the answers and applies the PDF/UA rules to
# them. Nothing here writes to the tree or to the file.
#
# Split off from structure.tcl because it is a topic of its own: building
# the tree during drawing is one job, giving an account of the finished tree
# is another, with a different reader and a different moment.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::document 1.0-

oo::define ::tclpdf::document::document {

  # What the tree looks like, for a checker that has to judge it as a whole.
  #
  # Two questions cannot be answered while the tree is being built, because
  # both need what comes after: whether the headings descend without a gap,
  # and whether every row of a table has the same number of cells. Both are
  # PDF/UA rules, and both would be wrong to enforce here - a document that
  # is not claiming UA may have a lone H3 for good reasons.
  #
  # So this answers with facts and judges nothing:
  #
  #   headings   the H1..H10 types in document order
  #   rows       per table element, the number of columns each of its rows
  #              covers - spans counted, see [StructureRowWidths]
  #   lists      per L element: its ListNumbering (empty when unset), how
  #              many LI it holds and how many of those carry a Lbl
  #   types      every type used, once
  #
  # Returned rather than read out of the state by the caller: the shape of an
  # element is this module's business, and a checker that walked it would
  # break the next time a field is added.
  method structureReport {} {
    set elements [my state structure]
    set headings {}
    set types {}
    set rows {}
    set lists {}
    foreach element $elements {
      set type [dict get $element type]
      if {$type ni $types} {
        lappend types $type
      }
      if {[regexp {^H(10|[1-9])$} $type -> level]} {
        lappend headings $level
      }
    }
    set index 0
    foreach element $elements {
      switch -- [dict get $element type] {
        Table {
          lappend rows [lindex [my StructureRowWidths $elements $index] 0]
        }
        L {
          lappend lists [my StructureListShape $elements $index]
        }
      }
      incr index
    }
    return [dict create headings $headings rows $rows lists $lists types $types]
  }

  # One list as three facts: what it says it is numbered, how many items it
  # has, and how many of them carry a label. Attributes are stored owner ->
  # pairs with the value a name object ({List {ListNumbering /Decimal}}), so
  # the slash comes off here.
  method StructureListShape {elements index} {
    set element [lindex $elements $index]
    set numbering {}
    set attributes [dict get $element attributes]
    if {[dict exists $attributes List ListNumbering]} {
      set numbering [string range [dict get $attributes List ListNumbering] 1 end]
    }
    set items 0
    set labelled 0
    foreach kid [dict get $element kids] {
      if {[lindex $kid 0] ne "element"} {
        continue
      }
      set item [lindex $elements [lindex $kid 1]]
      if {[dict get $item type] ne "LI"} {
        continue
      }
      incr items
      foreach grandchild [dict get $item kids] {
        if {[lindex $grandchild 0] eq "element"
            && [dict get [lindex $elements [lindex $grandchild 1]] type] eq "Lbl"} {
          incr labelled
          break
        }
      }
    }
    return [dict create numbering $numbering items $items labelled $labelled]
  }

  # The width of every row below one table, section groups included: a
  # THead and a TBody hold rows of the same table and their widths have to be
  # compared with each other, not each within its own group.
  #
  # Width is the number of COLUMNS a row covers, not the number of cells it
  # holds - the two differ exactly where a cell spans. A cell with ColSpan 2
  # covers two columns; a cell with RowSpan 2 covers its column in the row
  # below as well, where no cell is drawn for it. That is the grid a reader
  # rebuilds (Matterhorn 15-003, UA-2 8.2.5.26: "taking into account
  # spans"), and a table whose rows differ THAT way is one no reader can lay
  # out. Counting cells refused every regular table with a span - measured:
  # veraPDF passes such a table and this module did not.
  #
  # The attributes are stored owner -> pairs with number objects as values
  # ({Table {ColSpan 2}}); [pdfObj num] writes an integer as itself.
  #
  # The carry runs through the whole table in row order, groups included: a
  # RowSpan is a claim on the rows that follow, wherever they sit. Answered
  # as {widths carry}, so that a group can hand the carry on; the caller
  # takes the widths.
  method StructureRowWidths {elements index {carry {}}} {
    set widths {}
    foreach kid [dict get [lindex $elements $index] kids] {
      if {[lindex $kid 0] ne "element"} {
        continue
      }
      set child [lindex $elements [lindex $kid 1]]
      switch -- [dict get $child type] {
        TR {
          # What the rows above claim in this row, then the row's own cells.
          set columns 0
          set next {}
          foreach claim $carry {
            lassign $claim rows span
            incr columns $span
            if {$rows > 1} {
              lappend next [list [expr {$rows - 1}] $span]
            }
          }
          foreach cell [dict get $child kids] {
            if {[lindex $cell 0] ne "element"} {
              continue
            }
            set element [lindex $elements [lindex $cell 1]]
            if {[dict get $element type] ni {TH TD}} {
              continue
            }
            set attributes [dict get $element attributes]
            set colSpan 1
            set rowSpan 1
            if {[dict exists $attributes Table ColSpan]} {
              set colSpan [dict get $attributes Table ColSpan]
            }
            if {[dict exists $attributes Table RowSpan]} {
              set rowSpan [dict get $attributes Table RowSpan]
            }
            incr columns $colSpan
            if {$rowSpan > 1} {
              lappend next [list [expr {$rowSpan - 1}] $colSpan]
            }
          }
          lappend widths $columns
          set carry $next
        }
        THead - TBody - TFoot {
          lassign [my StructureRowWidths $elements [lindex $kid 1] $carry] \
              below carry
          lappend widths {*}$below
        }
      }
    }
    return [list $widths $carry]
  }

}

package provide tclpdf::structureReport 1.1
