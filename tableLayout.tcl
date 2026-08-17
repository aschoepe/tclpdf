#
# tclpdf - PDF generation for Tcl
#
# tableLayout - what a table measures before anything is drawn
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Splitting the measuring from the drawing is what makes page breaks possible
# at all: a row can only be placed once its height is known, and its height
# depends on how its text wraps, which depends on the column widths, which
# depend on the content of every row. So everything is measured first and
# drawn afterwards - never interleaved.
#
# This is a private sub-module behind the [table] facade. It extends the
# document class the same way textBlock extends it behind [text], because the
# measuring needs [textLines] and [textWidth], which are methods.
#
# The cell model follows HTML rather than inventing one: a cell spanning two
# rows occupies a place in the row below, and that place is NOT written out
# again. An occupancy grid keeps track, which is the only way spans and
# automatic column widths can coexist.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::option 1.0-
package require tclpdf::textBlock 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::tableLayout {}

oo::define ::tclpdf::document::document {

  # Turn the caller's rows into a grid of cell dictionaries.
  #
  # A cell is written as plain text, or as a dictionary when it needs more:
  #   {text "Sum" colSpan 3 align right style {fontStyle bold}}
  #
  # Returns a list of rows; each row is a list of cells, each cell carrying
  # its column index, its span and its own style.
  method TableNormalize {rows section} {
    set grid {}
    set occupied {}
    set rowIndex 0
    foreach row $rows {
      set cells {}
      set column 0
      foreach source $row {
        # Skip the columns a rowSpan from further up is still covering.
        while {[dict exists $occupied $rowIndex,$column]} {
          incr column
        }
        set cell [my TableCell $source]
        dict set cell row $rowIndex
        dict set cell column $column
        dict set cell section $section
        for {set r 1} {$r < [dict get $cell rowSpan]} {incr r} {
          for {set c 0} {$c < [dict get $cell colSpan]} {incr c} {
            dict set occupied [expr {$rowIndex + $r}],[expr {$column + $c}] 1
          }
        }
        lappend cells $cell
        incr column [dict get $cell colSpan]
      }
      lappend grid $cells
      incr rowIndex
    }
    return $grid
  }

  # One cell, from either spelling.
  method TableCell {source} {
    set cell [dict create text {} colSpan 1 rowSpan 1 align {} valign {} \
        direction {} style {}]
    # String or dictionary - and in Tcl a string can BE a dictionary, so this
    # decides rather than detects. It used to ask "is text one of the keys",
    # which any plain sentence of even word count can satisfy: "Medium length
    # text here" is a four element list whose key text holds here, so the cell
    # drew "here" and dropped the rest. That was in a shipped example.
    #
    # The question is now whether the FIRST word is a cell key, which is how a
    # dictionary is written and how a sentence practically never begins. The
    # remaining ambiguity is named rather than papered over: a plain string
    # that starts with one of these words AND has an even word count is read
    # as a dictionary, and the key check below then says so instead of quietly
    # keeping a fragment.
    if {[llength $source] > 1 && [llength $source] % 2 == 0
        && [lindex $source 0] in [dict keys $cell]} {
      # Checked before the merge, and only here: from this point on the cell
      # carries the keys the layout adds to it - row, column, section, height -
      # which a caller never writes but the didParseCell hook may hand back.
      # The list is the defaults just built, so it cannot drift from what is
      # actually read. The cell's style is checked in TableStyle, where the
      # assembled style says which keys exist.
      ::tclpdf::option keys $source [dict keys $cell] "cell key" table
      set cell [dict merge $cell $source]
    } else {
      dict set cell text $source
    }
    foreach key {colSpan rowSpan} {
      if {![string is integer -strict [dict get $cell $key]] ||
          [dict get $cell $key] < 1} {
        return -code error "tclpdf: $key must be a positive integer, got\
            \"[dict get $cell $key]\""
      }
    }
    return $cell
  }

  # The font options of a cell style, in the form the text methods take them.
  #
  # One place, because four call sites want the same list - three that MEASURE
  # here and one that DRAWS in tableDraw.tcl - and a list that grew a key in
  # three of them would measure a column against a line it never sets. The
  # direction is what made that concrete: a Hebrew cell measured without it is
  # not measured differently, it is REFUSED, and the refusal would name the
  # table rather than the cell.
  method TableFont {style} {
    return [list -family [dict get $style family] \
        -style [dict get $style fontStyle] -size [dict get $style size] \
        -direction [dict get $style direction]]
  }

  # How many columns the table has: the widest row wins, spans counted.
  method TableColumnCount {sections} {
    set count 0
    foreach grid $sections {
      foreach row $grid {
        foreach cell $row {
          set reach [expr {[dict get $cell column] + [dict get $cell colSpan]}]
          if {$reach > $count} {
            set count $reach
          }
        }
      }
    }
    return $count
  }

  # Column widths, in the document unit.
  #
  # Three kinds, and they are resolved in this order because each constrains
  # the next: fixed widths take what they ask for, weighted columns share what
  # is left in proportion, and automatic columns share the rest in proportion
  # to how wide their content actually is.
  #
  # The last part is what separates a usable table from one where the article
  # column is two millimetres wide because it happened to come last.
  method TableColumnWidths {sections columns total options} {
    set count [my TableColumnCount $sections]
    set widths [lrepeat $count {}]
    set weights [lrepeat $count 0]
    set index 0
    foreach column $columns {
      if {$index >= $count} {
        break
      }
      # Numbers, and said so here: "50%" used to reach the addition below and
      # come back as a Tcl error about a non-numeric operand, which names
      # neither the column nor the key. There is no percent width - a share
      # of the table is what weight is for.
      foreach key {width weight} {
        if {[dict exists $column $key]
            && ![string is double -strict [dict get $column $key]]} {
          return -code error "tclpdf: a column $key is a number, not\
              \"[dict get $column $key]\" - width in the document unit,\
              weight as a share of what the fixed widths leave; there is no\
              percent width"
        }
      }
      if {[dict exists $column width]} {
        lset widths $index [dict get $column width]
      } elseif {[dict exists $column weight]} {
        lset weights $index [dict get $column weight]
      }
      incr index
    }

    set fixed 0
    set weighted 0
    foreach width $widths weight $weights {
      if {$width ne {}} {
        set fixed [expr {$fixed + $width}]
      } elseif {$weight > 0} {
        set weighted [expr {$weighted + $weight}]
      }
    }
    set remaining [expr {$total - $fixed}]
    if {$remaining < 0} {
      if {![dict get $options horizontalBreak]} {
        return -code error "tclpdf: the fixed column widths add up to $fixed,\
            which is more than the table width of $total - either widen the\
            table or pass -horizontalBreak 1"
      }
      # With a horizontal break that is not an error but the reason for it:
      # the columns keep their widths and are dealt out over several pages.
      set remaining 0
    }
    # Fixed widths that use the table up while a further column has none:
    # that column came out zero wide, and its text one character per line
    # down the page. Refused like a sum over the width - it IS one, once the
    # column that has to be there is counted. A horizontal break does not
    # help here: a column without a width has nothing to carry to the next
    # page.
    if {$remaining <= 0 && [llength [lsearch -all -exact $widths {}]]} {
      set index [lsearch -exact $widths {}]
      return -code error "tclpdf: the fixed column widths add up to $fixed\
          and leave no room for column [expr {$index + 1}], which has no\
          width of its own - give it one or widen the table"
    }

    # Natural widths - what each column would need for its longest single
    # cell, padding included. Spanning cells are left out: they say nothing
    # about any one column.
    set natural [my TableNaturalWidths $sections $count $options]
    set autoTotal 0
    foreach width $widths weight $weights need $natural {
      if {$width eq {} && $weight <= 0} {
        set autoTotal [expr {$autoTotal + $need}]
      }
    }
    set weightShare [expr {$weighted > 0 ? $remaining * 0.5 : 0}]
    if {$autoTotal <= 0} {
      set weightShare $remaining
    } elseif {$weighted > 0} {
      # Weighted and automatic columns side by side: give the weighted ones
      # what their share of the total weight suggests, capped so the automatic
      # ones keep at least their natural width where the space allows.
      set weightShare [expr {min($remaining - min($autoTotal, $remaining * 0.9),
          $remaining)}]
      if {$weightShare < 0} {
        set weightShare 0
      }
    }
    set autoShare [expr {$remaining - $weightShare}]

    set result {}
    foreach width $widths weight $weights need $natural {
      if {$width ne {}} {
        lappend result $width
      } elseif {$weight > 0} {
        lappend result [expr {$weighted > 0 ? $weightShare * $weight / double($weighted) : 0}]
      } elseif {$autoTotal > 0} {
        lappend result [expr {$autoShare * $need / double($autoTotal)}]
      } else {
        lappend result 0
      }
    }
    return $result
  }

  # What each column would need if nothing wrapped.
  method TableNaturalWidths {sections count options} {
    set natural [lrepeat $count 0]
    foreach grid $sections {
      foreach row $grid {
        foreach cell $row {
          if {[dict get $cell colSpan] != 1} {
            continue
          }
          set style [my TableStyle $cell $options]
          set width [expr {[my textWidth [dict get $cell text] \
              {*}[my TableFont $style]] + 2 * [dict get $style padding]}]
          set column [dict get $cell column]
          if {$width > [lindex $natural $column]} {
            lset natural $column $width
          }
        }
      }
    }
    # A column with no content at all still has to be visible.
    return [lmap width $natural {expr {$width > 0 ? $width : 1}}]
  }

  # Wrap every cell and work out how tall each row comes out.
  #
  # Returns the grid with "lines" and "height" filled in per cell, and a list
  # of row heights. A cell spanning rows does not stretch the row it starts
  # in - its height is shared out over the rows it covers, which is what keeps
  # a two-line spanning cell from doubling a one-line row.
  method TableMeasure {grid widths options {tails {}}} {
    set heights {}
    set rowIndex 0
    set measured {}
    foreach row $grid {
      set tallest [dict get $options minRowHeight]
      set cells {}
      foreach cell $row {
        set style [my TableStyle $cell $options]
        set span 0
        for {set c 0} {$c < [dict get $cell colSpan]} {incr c} {
          set span [expr {$span + [lindex $widths [expr {[dict get $cell column] + $c}]]}]
        }
        set inner [expr {$span - 2 * [dict get $style padding]}]
        if {$inner <= 0} {
          set inner 0.1
        }
        set lines [my textLines [dict get $cell text] $inner \
            {*}[my TableFont $style]]
        set leading [::tclpdf::geometry fromPoints \
            [expr {[dict get $style size] * [dict get $style leading]}] \
            [my cget -unit]]
        set height [expr {[llength $lines] * $leading +
            2 * [dict get $style padding]}]
        # For a decimal column: which separator, and how much room the
        # widest tail in the column needs. Both are decided once per column
        # in TableDecimalTails - a cell cannot know what the others look like.
        dict set cell decimal [dict get $options decimal]
        dict set cell tail [expr {[dict exists $tails [dict get $cell column]] ?
            [dict get $tails [dict get $cell column]] : 0}]
        dict set cell lines $lines
        dict set cell width $span
        dict set cell leading $leading
        dict set cell height $height
        dict set cell resolved $style
        if {[dict get $cell rowSpan] == 1 && $height > $tallest} {
          set tallest $height
        }
        lappend cells $cell
      }
      lappend measured $cells
      lappend heights $tallest
      incr rowIndex
    }
    # Now the spanning cells: if one is taller than the rows it covers, the
    # difference goes onto the last of them.
    set rowIndex 0
    foreach row $measured {
      foreach cell $row {
        set span [dict get $cell rowSpan]
        if {$span == 1} {
          continue
        }
        set covered 0
        for {set r 0} {$r < $span && $rowIndex + $r < [llength $heights]} {incr r} {
          set covered [expr {$covered + [lindex $heights [expr {$rowIndex + $r}]]}]
        }
        if {[dict get $cell height] > $covered} {
          set last [expr {min($rowIndex + $span - 1, [llength $heights] - 1)}]
          lset heights $last [expr {[lindex $heights $last] +
              [dict get $cell height] - $covered}]
        }
      }
      incr rowIndex
    }
    # And once the heights are final, record how tall a spanning cell has to
    # be drawn. Worked out here rather than at drawing time because the body
    # is drawn a row at a time - by then the heights of the rows BELOW are out
    # of reach, and a spanning cell would be drawn one row tall, leaving the
    # rows it covers without a left-hand rule.
    set rowIndex 0
    set final {}
    foreach row $measured {
      set cells {}
      foreach cell $row {
        set covered 0
        for {set r 0} {$r < [dict get $cell rowSpan] &&
            $rowIndex + $r < [llength $heights]} {incr r} {
          set covered [expr {$covered + [lindex $heights [expr {$rowIndex + $r}]]}]
        }
        dict set cell spanHeight $covered
        lappend cells $cell
      }
      lappend final $cells
      incr rowIndex
    }
    return [list $final $heights]
  }

  # How much room the part from the decimal separator onwards needs, per
  # column, over ALL sections at once.
  #
  # Measured across head, body and foot together on purpose: the total in the
  # foot has to line up with the amounts in the body, and measuring the two
  # separately is how it ends up a hair off - visible, and never reported.
  method TableDecimalTails {sections widths options} {
    set separator [dict get $options decimal]
    set tails {}
    foreach grid $sections {
      foreach row $grid {
        foreach cell $row {
          set style [my TableStyle $cell $options]
          if {[dict get $style align] ne "decimal"} {
            continue
          }
          set text [dict get $cell text]
          set at [string first $separator $text]
          if {$at < 0} {
            continue
          }
          set width [my textWidth [string range $text $at end] \
              {*}[my TableFont $style]]
          set column [dict get $cell column]
          if {![dict exists $tails $column] || $width > [dict get $tails $column]} {
            dict set tails $column $width
          }
        }
      }
    }
    return $tails
  }

  # The style for one cell: defaults, then the theme, then the section, then
  # the column, then alternating rows, then the cell's own - each overriding
  # the one before. Spelled out here so that adding a level later is a line
  # rather than a rewrite.
  method TableStyle {cell options} {
    set style [dict get $options style]
    set section [dict get $cell section]
    dict for {key value} [dict get $options ${section}Style] {
      dict set style $key $value
    }
    set columns [dict get $options columns]
    set column [dict get $cell column]
    if {$column < [llength $columns]} {
      dict for {key value} [lindex $columns $column] {
        if {$key ni {width weight}} {
          dict set style $key $value
        }
      }
    }
    if {$section eq "body" && [dict get $options alternateFill] ne {} &&
        [dict get $cell row] % 2} {
      dict set style fill [dict get $options alternateFill]
    }
    # The assembled style is the list of keys that exist - defaults, theme and
    # section have all been laid in by now, and each of those was checked where
    # it was taken in. So a cell style is measured against what is actually
    # read, without this module having to know the table's default list.
    ::tclpdf::option keys [dict get $cell style] [dict keys $style] \
        "style key" "a table cell"
    dict for {key value} [dict get $cell style] {
      dict set style $key $value
    }
    # A heading over a decimal column is set flush right: there is nothing in
    # it to align on, and "Amount" hanging in the middle of the column reads
    # as a mistake.
    if {$section ne "body" && [dict get $style align] eq "decimal" &&
        ![string match {*[0-9]*} [dict get $cell text]]} {
      dict set style align right
    }
    # The cell's own alignment wins over column, theme and section style - it
    # is the most specific thing said about it. Both keys, not just align:
    # valign was documented as a cell key from the start and read from nowhere,
    # so it vanished without a word. It only shows once a row has a cell that
    # wraps, which is why no example caught it.
    foreach key {align valign direction} {
      if {[dict get $cell $key] ne {}} {
        dict set style $key [dict get $cell $key]
      }
    }
    return $style
  }
}

package provide tclpdf::tableLayout 1.2
