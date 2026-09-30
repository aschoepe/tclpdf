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
# For [pdfObj fits] - the one place the magnitude a PDF real holds stands
# (Annex C.2), asked by TableMeasurable below.
package require tclpdf::pdfObj 1.0-
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
        # A span past the last row of the section is malformed input. It used
        # to be clamped where the row heights are added up, and the table
        # came out as if the caller had written the span that fits - the
        # answer to a question nobody asked.
        if {$rowIndex + [dict get $cell rowSpan] > [llength $rows]} {
          return -code error -errorcode [list TCLPDF TABLE SPAN row] \
              "tclpdf: a rowSpan of [dict get $cell rowSpan] in\
              row [expr {$rowIndex + 1}] of the $section reaches past its last\
              row - the $section has [llength $rows] row(s)"
        }
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
  #
  # runs and markup, since 1.6. A cell holds its content as text, or as the
  # list of {text options} pairs [text -runs 1] takes, under runs - a bold
  # amount, a link, a struck old price, set with the faces the pairs name
  # and broken with them. markup is NOT a second content key: it names the
  # notation the TEXT is written in, tags or markdown, the way [text
  # -markup] does, and it is a style key like hyphenate and direction - said
  # once for a column of descriptions, or for the whole table, and read off
  # the cell only where the cell says it. So the string stays under text,
  # and the pair form {markup {markdown ...}} is refused by name below: it
  # would make markup mean two things.
  #
  # Both are cell keys so that a cell written as {runs {...}} READS as a
  # dictionary: until 1.6 the first word "runs" was no key, the cell was
  # text, and "runs {{...} {}}" stood on the page as typed - for two days,
  # in a shipped report, until somebody read the paper.
  method TableCell {source} {
    set cell [dict create text {} runs {} markup {} colSpan 1 rowSpan 1 \
        align {} valign {} direction {} style {}]
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
      # AND IT HAS TO SAY WHAT THE CELL HOLDS. The manual explains this
      # ambiguity by promising that such a string "then names the offending
      # key" - and where every key IS a cell key there is no offending one to
      # name: "align right" is a well formed cell dictionary with no text in
      # it, so the cell came out empty and right aligned, in silence. That is
      # the one case the sentence does not cover, and it is the likely one -
      # a caller who writes two words meant them as text.
      # The content keys, checked before the cell is asked for its text,
      # so that {markup {markdown ...}} hears what is wrong with the pair
      # rather than that it names no text.
      my TableCellContent [dict merge $cell $source]
      if {![dict exists $source text] && ![dict exists $source runs]} {
        return -code error -errorcode [list TCLPDF TABLE CELL text] \
            "tclpdf: the cell \"$source\" reads as a dictionary - it begins\
            with the cell key \"[lindex $source 0]\" and has an even word\
            count - but names no text and no runs, so the cell would come\
            out empty; give it a text key, or write the string as\
            \{[list $source]\} to set it as it stands"
      }
      set cell [dict merge $cell $source]
    } else {
      dict set cell text $source
    }
    foreach key {colSpan rowSpan} {
      if {![string is integer -strict [dict get $cell $key]] ||
          [dict get $cell $key] < 1} {
        return -code error -errorcode [list TCLPDF TABLE SPAN $key] \
            "tclpdf: $key must be a positive integer, got\
            \"[dict get $cell $key]\""
      }
    }
    return $cell
  }

  # What a cell may say about its content, checked once, where the cell is
  # read. Every refusal here is one the drawing could not make: a cell with
  # text AND runs would set one of the two in silence, a list of an odd
  # length would pair the wrong words, and markup written as a pair would
  # be read as a notation named "markdown some text".
  method TableCellContent {cell} {
    # Asked twice: of the cell as written, and of what a didParseCell hook
    # hands back - a hook that puts runs beside text, or the pair form of
    # markup, was measured to pass through in silence until 2026-09-30.
    # A hook may hand back a cell without the keys, so each is defaulted.
    foreach key {text runs markup style} {
      if {![dict exists $cell $key]} {
        dict set cell $key {}
      }
    }
    set markup [dict get $cell markup]
    # The pair form. Its first word is a notation and it has two words,
    # which is how nobody misspells a notation.
    if {[llength $markup] == 2 && [lindex $markup 0] in {tags markdown}} {
      return -code error -errorcode [list TCLPDF TABLE CELL markup] \
          "tclpdf: markup names the notation the cell's text is written\
          in - tags or markdown - and the string itself stands under text:\
          write {text [list [lindex $markup 1]] markup [lindex $markup 0]}"
    }
    set runs [dict get $cell runs]
    if {[catch {llength $runs} count] || $count % 2} {
      return -code error -errorcode [list TCLPDF TABLE CELL runs] \
          "tclpdf: runs takes a list of {text options} pairs, as \[text\
          -runs 1\] does, and \"[string range $runs 0 40]\" is not one"
    }
    if {$count && [dict get $cell text] ne {}} {
      return -code error -errorcode [list TCLPDF TABLE CELL runs] \
          "tclpdf: a cell holds its content as text or as runs, not both -\
          the runs are the text with its faces, so drop the text key"
    }
    # On the cell itself or inside its style - the two places a cell can
    # say it; a column's markup beside a cell of runs is not the cell's
    # word and stands for the text cells of that column.
    if {$count && ($markup ne {} || [dict exists [dict get $cell style] markup])} {
      return -code error -errorcode [list TCLPDF TABLE CELL markup] \
          "tclpdf: runs are already the pairs a notation translates into -\
          markup names how the TEXT of a cell is read, and this cell has\
          none; drop the markup key, or write the string under text"
    }
    return
  }

  # What a cell is set from: answers {pairs text} - the pairs where the
  # cell IS runs, an empty list and the text for a cell that is plain.
  #
  # The runs the cell gave, or the text translated by the notation the
  # assembled style names - the same two translators [text -markup] loads,
  # each only when its notation is asked for. A TRANSLATION THAT FOUND
  # NOTHING TO MARK is plain text, and the cell takes the plain road with
  # the translated text (its escapes resolved): a table that says "markup
  # markdown" once has columns of figures in it, and "1.50" in a decimal
  # column is not a cell of runs because the column beside it is Markdown -
  # measured 2026-09-30, it was refused as one. What the pairs may not
  # carry in a cell is refused here, once, before anything is drawn: a
  # paragraph state - heading, item, start, continued - because a cell's
  # lines are one height and one indent, which is how a row knows how tall
  # it is, and a heading in a cell would need a leading of its own the row
  # cannot see; and decimal alignment, which hangs a line on ONE separator
  # of ONE string and has no meaning for a line drawn as pieces. Neither is
  # flattened to plain text in silence. A right-to-left cell is refused by
  # [textLines] itself, in the words [text] uses for the same block.
  method TableRuns {cell style} {
    set text [dict get $cell text]
    set pairs [expr {[dict exists $cell runs] ? [dict get $cell runs] : {}}]
    if {![llength $pairs]} {
      switch -- [dict get $style markup] {
        tags {
          package require tclpdf::markup
          set pairs [::tclpdf::markup::parse $text]
        }
        markdown {
          package require tclpdf::markdown
          set pairs [::tclpdf::markdown::parse $text]
        }
      }
      set marked 0
      foreach {piece options} $pairs {
        if {[dict size $options]} {
          set marked 1
          break
        }
      }
      if {[llength $pairs] && !$marked} {
        set text [join [lmap {piece options} $pairs {set piece}] {}]
        set pairs {}
      }
    }
    if {![llength $pairs]} {
      return [list {} $text]
    }
    if {[dict get $style align] eq "decimal"} {
      return -code error -errorcode [list TCLPDF TABLE CELL decimal] \
          "tclpdf: a cell set as runs cannot be aligned on a decimal\
          separator - the column hangs one string on one separator, and a\
          line of pieces has none; give the cell align left, right or\
          center, or set the figure as text"
    }
    foreach {text options} $pairs {
      foreach key {heading item start continued} {
        if {[dict exists $options $key]} {
          return -code error -errorcode [list TCLPDF TABLE CELL paragraph $key] \
              "tclpdf: a run in a table cell cannot carry \"$key\" - a\
              heading or a list item is a paragraph of its own size and\
              indent, and the lines of a cell are one height, which is how\
              the row knows how tall it is; set the words as a plain run,\
              or put the list in a \[text\] block beside the table"
        }
      }
    }
    return [list $pairs $text]
  }

  # The width inside a cell, what its lines are broken to and drawn with -
  # one place, because the two have to agree to the last digit.
  method TableInner {width padding} {
    set inner [expr {$width - 2 * $padding}]
    return [expr {$inner <= 0 ? 0.1 : $inner}]
  }

  # The font options of a cell style, in the form the text methods take them.
  #
  # One place, because four call sites want the same list - three that MEASURE
  # here and one that DRAWS in tableDraw.tcl - and a list that grew a key in
  # three of them would measure a column against a line it never sets. The
  # direction is what made that concrete: a Hebrew cell measured without it is
  # not measured differently, it is REFUSED, and the refusal would name the
  # table rather than the cell.
  #
  # hyphenate is NOT in this list, and that is the same argument read the
  # other way round. These four options say how wide a string is; hyphenate
  # says where the LINES fall, which is a question only the one call site that
  # wraps can ask. Two of the four sites here measure with [textWidth], and
  # [textWidth] refuses a layout option by name - "-hyphenate" among them - so
  # putting it here would not measure a column wrong, it would refuse every
  # table that named a language. It is passed at TableMeasure and nowhere
  # else.
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

  # A colSpan covers columns of the table; it does not add any. A span
  # reaching over a column in which no row has a cell - "colSpan 5" in a
  # table whose rows have three cells - used to be taken as it stood: the
  # table grew the columns, each of them one unit wide, the cells after the
  # span were pushed right by them, and nothing said so. Refused, unless
  # -columns describes the column - then it is there on purpose, and its
  # description says how wide.
  method TableColumnsCovered {sections count columns} {
    set starts [lrepeat $count 0]
    foreach grid $sections {
      foreach row $grid {
        foreach cell $row {
          lset starts [dict get $cell column] 1
        }
      }
    }
    for {set index 0} {$index < $count} {incr index} {
      if {[lindex $starts $index] || $index < [llength $columns]} {
        continue
      }
      return -code error -errorcode [list TCLPDF TABLE SPAN column] \
          "tclpdf: a colSpan reaches over column\
          [expr {$index + 1}], which no row has a cell in - a span covers the\
          columns of the table and adds none; describe the column in -columns\
          if it is meant to be there"
    }
    return
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
    my TableColumnsCovered $sections $count $columns
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
            && (![::tclpdf::option finite [dict get $column $key]]
                || [dict get $column $key] <= 0)} {
          # ABOVE ZERO, both of them, and that is the same sentence the
          # implicit zero width already had: "that column would come out zero
          # wide". A width of 0 drew every cell of the column on top of its
          # neighbour, a negative one started the next column to the LEFT of
          # -at - measured, 20 mm outside the table - and a weight of 0 or
          # below went into a proportion that means nothing. NaN and Inf are
          # doubles to Tcl and passed every comparison written as "< 0".
          return -code error -errorcode [list TCLPDF TABLE COLUMN $key] \
              "tclpdf: a column $key is a number above zero, not\
              \"[dict get $column $key]\" - width in the document unit,\
              weight as a share of what the fixed widths leave; there is no\
              percent width, and a column of no width has nowhere to put its\
              text"
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
        return -code error -errorcode [list TCLPDF TABLE WIDTH fixed] \
            "tclpdf: the fixed column widths add up to $fixed,\
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
      return -code error -errorcode [list TCLPDF TABLE WIDTH fixed] \
          "tclpdf: the fixed column widths add up to $fixed\
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
          # A cell of runs is measured piece by piece in the face of each
          # piece, as its lines will be broken; the bold word IS wider.
          lassign [my TableRuns $cell $style] pairs text
          if {[llength $pairs]} {
            set width [my TextLinesWidest $pairs -runs 1 {*}[my TableFont $style]]
          } else {
            set width [my textWidth $text {*}[my TableFont $style]]
          }
          set width [expr {$width + 2 * [dict get $style padding]}]
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
  # Returns the grid with "lines", "hyphens" and "height" filled in per cell,
  # and a list of row heights. A cell spanning rows does not stretch the row it starts
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
        set inner [my TableInner $span [dict get $style padding]]
        # THE ONE PLACE IN THE PACKAGE THAT WRAPS TEXT THE CALLER NEVER OPENED
        # A BLOCK FOR, and therefore the one place -hyphenate has to be handed
        # on rather than taken from the caller's own [text] call. The lines
        # this returns are what tableDraw.tcl puts on the page, one [text] per
        # line, so what is measured here IS what is set - there is no second
        # breaker downstream to keep in step with.
        #
        # An unloaded language is refused from inside [textLines] with
        # TCLPDF HYPHENATE LANGUAGE. Nothing on this road catches it: the
        # whole table is measured before its first cell is drawn, so the
        # refusal leaves the page, the structure tree and the state as they
        # were - the same promise the option and value checks make in
        # table.tcl.
        #
        # [TextLinesBroken] rather than [textLines], and that is the whole of
        # the hyphen bracket in a table: the public method answers strings,
        # and a string cannot say whether the "-" it ends on is a break or a
        # character. The cell keeps both halves - the strings it draws and
        # the flags it hands back to [text] - so the bracket the paragraph
        # road writes is written here as well (14.8.2.6). Extraction of a
        # tagged table gave "Betriebskostenab-rechnung" until it did.
        #
        # A CELL OF RUNS takes the public road, [textLines -runs 1 -hyphens
        # 1]: every line comes back as the pairs it is made of, which is the
        # shape the drawing needs to set it with its faces and the shape a
        # hook reads under "lines" - and the hyphen flag beside it, as the
        # pair road has it. The runs are kept on the cell, so that the
        # drawing knows which road to take without asking the style again.
        lassign [my TableRuns $cell $style] pairs text
        if {[llength $pairs]} {
          set broken [lmap line [my textLines $pairs -runs 1 -hyphens 1 \
              -width $inner {*}[my TableFont $style] \
              -hyphenate [dict get $style hyphenate]] {
            list [dict get $line text] [dict get $line hyphen]
          }]
        } else {
          set broken [my TextLinesBroken $text $inner \
              {*}[my TableFont $style] -hyphenate [dict get $style hyphenate]]
        }
        dict set cell runs $pairs
        set lines [lmap line $broken {lindex $line 0}]
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
        # One flag per line, in step with them because both are read off the
        # SAME answer of the breaker one statement apart - not two lists that
        # have to be kept in step.
        dict set cell hyphens [lmap line $broken {lindex $line 1}]
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
          # The text as it is set: a notation resolves its escapes before the
          # separator is looked for, or the tail of "12.50 \*" would be
          # measured a backslash too wide (measured 2026-09-30).
          set text [lindex [my TableRuns $cell $style] 1]
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
    #
    # markup for the same reason: a column of Markdown with one cell that
    # says "markup plain" sets that cell as it stands.
    foreach key {align valign direction markup} {
      if {[dict exists $cell $key] && [dict get $cell $key] ne {}} {
        dict set style $key [dict get $cell $key]
      }
    }
    return [my TableStyleCheck $style]
  }

  # The values of the assembled style, once every level has had its say. The
  # keys were checked where they came in; the VALUES were not, and a wrong
  # one fell through the switch that reads it - "align foo" set the text
  # left, "valign foo" set it at the top, a negative padding pulled the text
  # out of its cell, a leading of 0 stacked the lines on one line - and
  # nothing said so. border was refused, but by the code that draws the
  # rules - after the cell's fill had gone out; direction is refused by
  # [text] at measuring. All of it is refused here, before a cell is
  # measured, so that a table with a mistyped value draws nothing at all.
  # size and family go through [text], which has its own word on both.
  method TableStyleCheck {style} {
    # A VERTICAL TABLE IS REFUSED HERE AND IN THE TABLE'S OWN WORDS, since
    # 2026-08-25. It used to be caught by [text] on the way through, which
    # was right as long as that road refused every vertical block; now that
    # the BREAKER takes the direction and only the PLACING does not, the
    # refusal a table ran into came from [TextLift]'s anchor branch and
    # talked about an -anchor the caller never gave. A cell that says
    # "direction ttb" has to hear about tables.
    if {[dict get $style direction] eq "ttb"} {
      return -code error -errorcode [list TCLPDF TABLE DIRECTION ttb] \
          "tclpdf: a table sets its cells as horizontal blocks - it breaks\
          them by the column width and steps the lines down the row, which is\
          the direction a vertical line already writes in. There is no\
          vertical table: a page of columns is \[textLines -direction ttb\]\
          for the breaking and one \[text\] call per column for the placing.\
          Drop \"direction ttb\" from the style"
    }
    foreach {key known} {
      align {left right center decimal}
      valign {top middle bottom}
      border {none all horizontal vertical outer}
      markup {plain tags markdown}
    } {
      if {[dict get $style $key] ni $known} {
        return -code error -errorcode [list TCLPDF TABLE STYLE $key] \
            "tclpdf: unknown table $key\
            \"[dict get $style $key]\" - known are: [join $known {, }]"
      }
    }
    foreach {key what} {
      padding {a distance of 0 or more in the document unit}
      lineWidth {a width of 0 or more in the document unit}
    } {
      set value [dict get $style $key]
      if {![my TableMeasurable $value 0]} {
        return -code error -errorcode [list TCLPDF TABLE STYLE $key] \
            "tclpdf: a table $key is $what, not \"$value\""
      }
    }
    set leading [dict get $style leading]
    if {![my TableMeasurable $leading 0 1]} {
      return -code error -errorcode [list TCLPDF TABLE STYLE leading] \
          "tclpdf: a table leading is a factor of the font\
          size above 0, not \"$leading\""
    }
    return $style
  }

  # Whether a number is one a table can be measured in.
  #
  # Three questions in one place, because every distance of a table asks the
  # same three and each site keeps its own wording and its own error code:
  #
  #   finite            NaN and Inf are doubles to Tcl and compare false
  #                     against every range check, so "-bottom NaN" switched
  #                     the page break off in silence and a NaN padding
  #                     travelled into the arithmetic that places the text
  #                     inside its cell
  #   a PDF real holds it  the manual (:77) says a length beyond about
  #                     +/-3.403e38 is "refused at the call"; the table's own
  #                     distances were not, and 1e39 in -top, -bottom,
  #                     -minRowHeight or a padding was taken by the call and
  #                     thrown out much later by TableCheckFit, with a forty
  #                     digit number in the message (measured 2026-08-27)
  #   the bound the option carries  0 or more for a distance, above 0 for a
  #                     factor
  #
  # Answers a boolean rather than refusing: the message and the code belong
  # to the option, and there are seven of them with seven different sentences.
  method TableMeasurable {value minimum {exclusive 0}} {
    if {![::tclpdf::option finite $value] || ![::tclpdf::pdfObj fits $value]} {
      return 0
    }
    return [expr {$exclusive ? $value > $minimum : $value >= $minimum}]
  }
}

package provide tclpdf::tableLayout 1.8
