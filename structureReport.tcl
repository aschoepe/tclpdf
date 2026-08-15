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
# the cell count of every table row, the shape of every list - and judges
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
  #   rows       per table element, the cell count of each of its rows
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
          lappend rows [my StructureRowWidths $elements $index]
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

  # The cell count of every row below one table, section groups included: a
  # THead and a TBody hold rows of the same table and their widths have to be
  # compared with each other, not each within its own group.
  method StructureRowWidths {elements index} {
    set widths {}
    foreach kid [dict get [lindex $elements $index] kids] {
      if {[lindex $kid 0] ne "element"} {
        continue
      }
      set child [lindex $elements [lindex $kid 1]]
      switch -- [dict get $child type] {
        TR {
          set cells 0
          foreach cell [dict get $child kids] {
            if {[lindex $cell 0] eq "element"
                && [dict get [lindex $elements [lindex $cell 1]] type] in {TH TD}} {
              incr cells
            }
          }
          lappend widths $cells
        }
        THead - TBody - TFoot {
          lappend widths {*}[my StructureRowWidths $elements [lindex $kid 1]]
        }
      }
    }
    return $widths
  }

}

package provide tclpdf::structureReport 1.0
