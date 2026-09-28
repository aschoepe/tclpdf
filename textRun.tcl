#
# tclpdf - PDF generation for Tcl
#
# textRun - runs of one paragraph: a fat word, an italic name, a link, set
# in the middle of flowing text, with the line breaker running over all of it;
# and the paragraph states a run can carry - a heading, a list item
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A run is a stretch of a paragraph's text with a style of its own. THE SIZE
# STAYS: a run changes the face - bold, italic, both - and what is drawn over
# or under it, never the size, the colour or the spacing; those belong to the
# paragraph. That one restriction is what keeps the leading and the baseline
# one number per paragraph, and it is the reason this module is a hundred
# lines beside the breaker instead of a second breaker.
#
# HOW THE RUNS REACH THE BREAKER without the breaker knowing them. The
# caller hands [text -runs 1] a list of {text options} pairs. Here the texts
# are joined into ONE string - the string the breaker has always worked on -
# and beside it a MAP is kept: for every run, where in that string it begins
# and ends and which font arguments set it. The breaker measures chunks of
# the string and says where each chunk begins (its "base"); [TextRunsSplit]
# lays the chunk over the map from there and hands back the pieces, each with
# its run, and a chunk is then measured or drawn piece by piece. The
# breaker's own logic - words, glue, offers, the emergency break - is not
# touched, and a block without runs takes the road it always took, byte for
# byte.
#
# WHY A WALK AND NOT ARITHMETIC. A chunk is not the string verbatim: the
# breaker measures a run of separators as the one space it is to the page,
# a head that took a hyphenation offer has lost the soft hyphens inside it,
# the hyphen it sets at a break is nobody's character, and a line is closed
# without the breakable spaces at its end. Counting positions would be off
# by every one of those, so the chunk is walked against the string instead:
# each character finds its own in the string, skipping what the string has
# and the chunk has not, and takes the run of the place it found. A walk
# costs a few [string index] per character - the measurement it prepares
# costs a glyph lookup per character anyway.
#
# WHAT A RUN BOUNDARY COSTS, said once: the two pieces on either side of it
# are measured and drawn as two glyph runs, so a pair that straddles the
# boundary is not kerned, and the character spacing between them is added
# by hand. Bold and regular do not kern with each other in any face, so
# nothing is lost that a reader could see.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::option 1.0-
package require tclpdf::text 1.0-
package require tclpdf::textBlock 1.0-

namespace eval ::tclpdf::textRun {
  # What a run may say about itself. One entry so far and a list all the
  # same, because the later stages of MARKUP.md add to it - underline,
  # strike, url - and a refusal that names the known ones has to read the
  # same list the intake reads.
  # "strong" and "em" are what <strong> and <em> travel as: the run is set
  # bold or italic like any other, and the flag is carried for the tagged
  # document, where the two are the inline elements Strong and Em (ISO
  # 32000-2, 14.8.4.7) - not written yet, and carried so that the notation
  # need not change when they are.
  variable options {style heading item start continued underline strike url
      strong em}

  # The options that make a pair a PARAGRAPH of its own rather than a run
  # inside one - a heading, a list item. Runs that follow each other with
  # the same one of them share the paragraph; anything else closes it. One
  # mechanism for both, the paragraph state (see TextRunsIntake).
  variable paragraphOptions {heading item}

  # The kinds of list item, and what the tagged document names the list
  # after each (ListNumbering, ISO 32000-1 Table 347): the bullet drawn is
  # U+2022, a "solid circular bullet", which is Disc; the numbers are 1., 2.,
  # 3., which is Decimal. A list that says what its labels are is what PDF/UA
  # asks for (ua.tcl, UaCheckLists) - under part 2 even for bullets, where
  # None is no longer allowed beside a Lbl.
  variable items {bullet Disc number Decimal}

  # The geometry of a list item, as fractions of the block's size (a
  # decision of the author, 2026-09-28): every line of the item stands 1.6
  # sizes further in than the block's own lines, and the label ends half a
  # size before the text. The indent grows for a list whose widest label
  # needs more - see TextRunsItems.
  variable itemIndent 1.6
  variable itemGap 0.5
  variable bullet "\u2022"

  # Where a line is drawn when the face says nothing, as fractions of the
  # size: {position thickness}, position from the baseline, up positive.
  # A tenth below for the underline and a twentieth thick is what the AFM
  # files of the standard fourteen are known to state (-100 and 50 per
  # thousand); the strikeout at a quarter of the size sits in the middle of
  # the x-height of most faces. Not measured against the Adobe files - the
  # archive in this repository is sealed - which is why the generator
  # (tools/mkafm.tcl) now reads the two keys: once it is rerun, the
  # descriptor answers and this fallback stands only for the strikeout.
  variable fallback {underline {-0.1 0.05} strike {0.25 0.05}}

  # What a heading is set in, relative to the block's size (a decision of
  # the author, 2026-09-27): h1 1.6, h2 1.3, h3 1.15 - and bold, because a
  # heading that is only larger looks like an accident in most faces. Its
  # leading grows by the same factor, whether the block's leading is the
  # default or one the caller gave.
  variable headings {1 1.6 2 1.3 3 1.15}

  # The words -style takes inside a run, and what each becomes. "oblique"
  # is italic under another name, as it is at [font -style].
  variable styles {bold bold italic italic oblique italic}

  # The characters a chunk may lack where the string has them, besides the
  # separators and the breakable spaces of the breaker: the three that never
  # reach a face (text.tcl, neverDrawn) - a hyphenation head has lost its
  # soft hyphens, and the others are skipped by every encoder.
  variable skipped "­​﻿"
}

oo::define ::tclpdf::document::document {

  # The intake of [text -runs 1], [textLines -runs 1] and [textHeight
  # -runs 1]: the list of {text options} pairs becomes the one string the
  # block road works on, and the options gain the map under "runs".
  # Answers {string options}. Everything a run can be refused for is refused
  # here, before a mark is opened or a byte measured.
  #
  # The map is a list of entries {from to style arguments options}: from is
  # the index of the run's first character in the string, to the index
  # after its last, style the words the run asked for, arguments the -name
  # value list [textWidth] and [TextMerge] take for it - the block's own
  # arguments with the run's style laid over the block's -, and options
  # what the caller wrote, normalised, which is what a rest and a line of
  # [textLines] hand back.
  #
  # A HEADING IS A PARAGRAPH, never a run inside one: the size changes only
  # at a paragraph boundary, which is what keeps every line one height. A
  # LIST ITEM is a paragraph too - it is indented as a whole and carries a
  # label in front of its first line. Both are a PARAGRAPH STATE, and they
  # take one road: a pair with "heading n" or "item kind" is closed off with
  # a line feed on either side where the caller left one out - inside the
  # pair's own text, so that a rest handed back and set again arrives
  # already bounded -, and runs that follow each other with the same state
  # share the paragraph until a line feed or another state comes.
  #
  # The options gain, beside the map, "runsParagraphs" - paragraph index ->
  # a dictionary of what the paragraph is: {heading n leading l} for a
  # heading, {item kind ordinal n list k indent i gap g marker m
  # markerWidth w ?continued 1?} for a list item (TextRunsItems) - and
  # "runsFirst" (the arguments of paragraph 0 where it is a heading, for the
  # lift of the first baseline). A paragraph is only in the table where a
  # run with a state holds one of its characters; a blank line is never a
  # heading or an item.
  method TextRunsIntake {pairs options context} {
    if {[llength $pairs] % 2} {
      return -code error -errorcode [list TCLPDF TEXT RUNS LIST] \
          "tclpdf: -runs 1 takes a list of {text options} pairs, and\
          \"[string range $pairs 0 40]\" has an odd number of elements"
    }
    if {[dict get $options width] eq {}} {
      return -code error -errorcode [list TCLPDF TEXT RUNS WIDTH] \
          "tclpdf: -runs 1 sets a paragraph, and a paragraph needs -width"
    }
    if {[dict get $options direction] ne "ltr"} {
      return -code error -errorcode [list TCLPDF TEXT RUNS DIRECTION \
          [dict get $options direction]] \
          "tclpdf: -runs 1 sets a left-to-right paragraph - a run in a\
          right-to-left or vertical block is not built; set the block as\
          one run with -direction [dict get $options direction]"
    }
    if {[llength [dict get $options avoid]]} {
      return -code error -errorcode [list TCLPDF TEXT RUNS AVOID] \
          "tclpdf: -runs 1 cannot be combined with -avoid - the lines of a\
          block that flows round a shape are broken again for every column,\
          and the runs would not follow"
    }
    set base [my TextOverrides $options]
    set baseStyle [dict get $options style]
    set baseState [my TextMerge $base]
    set baseLeading [::tclpdf::geometry fromPoints \
        [dict get $baseState leading] [my cget -unit]]
    set paragraphs {}
    set first {}
    # The paragraph state in progress - {heading n}, {item kind} or {} for a
    # plain paragraph. Runs of one heading that follow each other ("Kapitel "
    # and "zwei" of <h2>Kapitel <i>zwei</i></h2>) share the paragraph, and so
    # do the runs of one list item; the line feed that closes it is written
    # only where something follows - never twice, so a caller's own line
    # feed in front of the next text is respected.
    set paragraphOpen {}
    # The line feeds in the string so far: the index of the paragraph the
    # next character lands in, counted as the breaker counts.
    set newlines 0
    # A run's style has to reach a face. For a standard family it does; for
    # an embedded alias -style has never done anything, and a bold run set
    # in the regular face would be the silent wrong this whole road exists
    # to avoid. [font family] is the way through, and the refusal names it.
    set family [dict get $options family]
    set plainAlias [expr {[my TextEmbedded $family]
        && ![dict exists [my state fontFamilies] $family]}]
    set string {}
    set map {}
    foreach {text runOptions} $pairs {
      if {[llength $runOptions] % 2} {
        return -code error -errorcode [list TCLPDF TEXT RUNS OPTIONS] \
            "tclpdf: the options of a run are a -name value list, and\
            \"$runOptions\" has an odd number of elements"
      }
      set style $baseStyle
      set heading {}
      set item {}
      set given {}
      foreach {name value} $runOptions {
        set name [string trimleft $name -]
        if {$name ni $::tclpdf::textRun::options} {
          return -code error -errorcode [list TCLPDF TEXT RUNS OPTION $name] \
              "tclpdf: a run knows no option \"$name\" - known are:\
              [join [lmap n $::tclpdf::textRun::options {string cat - $n}] {, }]"
        }
        switch -- $name {
          style {
            set style [my TextRunsStyle $style $value]
            dict set given style [my TextRunsStyle {} $value]
          }
          underline - strike - strong - em - continued {
            if {![string is boolean -strict $value]} {
              return -code error -errorcode [list TCLPDF TEXT RUNS $name $value] \
                  "tclpdf: a run's -$name takes a boolean, not \"$value\""
            }
            dict set given $name [expr {$value ? 1 : 0}]
          }
          url {
            if {$value eq {}} {
              return -code error -errorcode [list TCLPDF TEXT RUNS URL empty] \
                  "tclpdf: a run's -url needs an address"
            }
            if {[dict exists $options rotate] && [dict get $options rotate] != 0} {
              return -code error -errorcode [list TCLPDF TEXT RUNS URL rotate] \
                  "tclpdf: a link in a rotated block is not built - the\
                  rectangle of a link annotation lies square to the page\
                  (ISO 32000-2, 12.5.2), and a turned line has no such\
                  rectangle; set the block without -rotate"
            }
            dict set given url $value
          }
          heading {
            if {![dict exists $::tclpdf::textRun::headings $value]} {
              return -code error -errorcode [list TCLPDF TEXT RUNS HEADING $value] \
                  "tclpdf: a heading is 1, 2 or 3, not \"$value\""
            }
            set heading $value
            dict set given heading $value
          }
          item {
            if {![dict exists $::tclpdf::textRun::items $value]} {
              return -code error -errorcode [list TCLPDF TEXT RUNS ITEM $value] \
                  "tclpdf: a list item is \"bullet\" or \"number\", not\
                  \"$value\""
            }
            set item $value
            dict set given item $value
          }
          start {
            # Digits only, and no leading zero: "010" is ten to Tcl 9 and
            # eight to Tcl 8.6, and a list number is not the place to learn
            # that.
            if {![regexp {^[1-9][0-9]*$} $value]} {
              return -code error -errorcode [list TCLPDF TEXT RUNS START $value] \
                  "tclpdf: a run's -start is the number of its list item, a\
                  whole number from 1, not \"$value\""
            }
            dict set given start $value
          }
        }
      }
      if {$heading ne {} && $item ne {}} {
        return -code error -errorcode [list TCLPDF TEXT RUNS ITEM HEADING] \
            "tclpdf: a run is a heading or a list item, not both - a\
            heading is set larger and a list item indented, and one\
            paragraph cannot be both"
      }
      # What only a list item can say. "start" is the number the item
      # carries, and a bullet has none; "continued" is an item that began
      # before this call - the head of the rest [text -height] hands back
      # (TextRunsRest) - and draws no label.
      if {[dict exists $given start] && $item ne "number"} {
        return -code error -errorcode [list TCLPDF TEXT RUNS START \
            [expr {$item eq {} ? "item" : $item}]] \
            "tclpdf: -start numbers a list item, and only an item of\
            \"item number\" has a number"
      }
      if {[dict exists $given continued] && $item eq {}} {
        return -code error -errorcode [list TCLPDF TEXT RUNS CONTINUED item] \
            "tclpdf: -continued says a list item began before this block,\
            and the run is no list item - give it \"item bullet\" or\
            \"item number\""
      }
      set paragraphState [expr {$heading ne {} ? [list heading $heading]
          : ($item ne {} ? [list item $item] : {})}]
      if {$heading ne {}} {
        set style [my TextRunsStyle $style bold]
      }
      if {$paragraphState ne {}} {
        if {$paragraphOpen ne $paragraphState} {
          if {$string ne {} && [string index $string end] ne "\n"} {
            append string "\n"
            incr newlines
          }
          set paragraphOpen $paragraphState
        }
      } elseif {$paragraphOpen ne {}} {
        if {$string ne {} && [string index $string end] ne "\n"
            && [string index $text 0] ne "\n"} {
          append string "\n"
          incr newlines
        }
        set paragraphOpen {}
      }
      if {$plainAlias && $style ne {}} {
        return -code error -errorcode [list TCLPDF TEXT RUNS FAMILY $family] \
            "tclpdf: a run asks for style \"$style\", and \"$family\" is\
            the alias of one embedded face, which has no bold or italic of\
            its own - register the faces as a family with \[font family\]\
            and set the block in that family"
      }
      set from [string length $string]
      set paragraph $newlines
      append string $text
      incr newlines [regexp -all \n $text]
      if {$text eq {}} {
        # An empty run marks nothing; it is left out of the map rather than
        # kept as a zero-length entry the walk would have to step over.
        continue
      }
      set arguments $base
      # The block's own -style stands in the arguments already; the run's
      # merged style replaces it, so that two -style entries never reach
      # [TextMerge] with the later one winning in silence. A heading's
      # size replaces the block's the same way.
      set at [lsearch -exact $arguments -style]
      if {$at >= 0} {
        set arguments [lreplace $arguments $at $at+1]
      }
      lappend arguments -style $style
      if {$heading ne {}} {
        set factor [dict get $::tclpdf::textRun::headings $heading]
        set at [lsearch -exact $arguments -size]
        if {$at >= 0} {
          set arguments [lreplace $arguments $at $at+1]
        }
        lappend arguments -size [expr {[dict get $options size] * $factor}]
      }
      # Every paragraph the run holds a character of takes its state - a
      # line feed inside the text of a heading or an item begins a second
      # heading or item, which is what the breaker makes of it anyway.
      if {$paragraphState ne {}} {
        foreach piece [split $text \n] {
          if {[string trim $piece $::tclpdf::textBlock::separators] ne {}} {
            set entry [expr {[dict exists $paragraphs $paragraph]
                ? [dict get $paragraphs $paragraph] : {}}]
            if {$heading ne {}} {
              dict set entry heading $heading
              dict set entry leading [expr {$baseLeading * $factor}]
              if {$paragraph == 0} {
                set first $arguments
              }
            } else {
              dict set entry item $item
              foreach key {start continued} {
                if {[dict exists $given $key] && [dict get $given $key]} {
                  dict set entry $key [dict get $given $key]
                }
              }
            }
            dict set paragraphs $paragraph $entry
          }
          incr paragraph
        }
      }
      lappend map [list $from [string length $string] $style $arguments $given]
    }
    set paragraphs [my TextRunsItems $paragraphs $options $base $baseState]
    # A block that opens with the rest of an item begun in the call before
    # opens in the middle of a paragraph: its first line takes no
    # -firstIndent, as the continuation of a paginated block takes none
    # (TextBlockBand).
    if {[dict exists $paragraphs 0 continued]} {
      dict set options continued 1
    }
    dict set options runs $map
    dict set options runsParagraphs $paragraphs
    dict set options runsFirst $first
    set kinds {}
    foreach entry [dict values $paragraphs] {
      foreach kind $::tclpdf::textRun::paragraphOptions {
        if {[dict exists $entry $kind] && $kind ni $kinds} {
          lappend kinds $kind
        }
      }
    }
    # The marks of a tagged document are opened per PARAGRAPH where a block
    # carries a paragraph state - H1 to H3 beside P, an L of LI with a Lbl
    # and a LBody each - and the paginating roads open theirs per page, one
    # for the whole block (TextPaginate). The two do not meet: a list would
    # have to stay open over the page break, its LI and LBody go on as the
    # same elements on the next page, and the one mark per page that road
    # opens round the block would have to give way to the marks of the
    # paragraphs. [StructureMarkAgain] carries a LEAF over a page (a further
    # mark on the LBody would do), but the L and the LI are groups on the
    # structure stack, which the page break with its pageAdded handlers runs
    # through - a running head drawn there would become a child of the open
    # item. Refused by name rather than tagged wrong.
    if {[llength $kinds] && [my state tagged] eq "1"
        && ([dict get $options paginate] || [dict get $options columns] > 1)} {
      if {"heading" in $kinds} {
        return -code error -errorcode [list TCLPDF TEXT RUNS HEADING MARKS] \
            "tclpdf: a heading in a tagged block is a structure element of\
            its own, and a block set with -paginate or -columns marks its\
            content per page - the two are not combined; set the headings\
            as blocks of their own"
      }
      return -code error -errorcode [list TCLPDF TEXT RUNS ITEM PAGINATE] \
          "tclpdf: a list in a tagged block is an L with an LI per item,\
          and a block set with -paginate or -columns marks its content per\
          page - a list carried over a page break is not built; set the\
          list without -paginate and -columns, and place the rest with\
          -height, which hands it back"
    }
    if {[llength $kinds] && [dict exists $options expansion]
        && [dict get $options expansion] ne {}} {
      if {"heading" in $kinds} {
        return -code error -errorcode [list TCLPDF TEXT RUNS HEADING EXPANSION] \
            "tclpdf: -expansion wraps the whole block in one Span, and a\
            block with headings is several elements - give the expansion to\
            the paragraph it belongs to, as a block of its own"
      }
      return -code error -errorcode [list TCLPDF TEXT RUNS ITEM EXPANSION] \
          "tclpdf: -expansion wraps the whole block in one Span, and a\
          block with a list is several elements - give the expansion to the\
          paragraph it belongs to, as a block of its own"
    }
    return [list $string $options]
  }

  # The list items of the paragraph table, counted, labelled and measured.
  #
  # A LIST is the run of item paragraphs of one kind that follow each other:
  # a paragraph without an item - plain text, a heading, a blank line - or
  # an item of the other kind ends it, and the next item begins a new list
  # at 1. The number is counted here, per paragraph, once for the whole
  # block, so that a line on the next page of a paginated block knows it as
  # well as the first; "start" on an item sets its number and the items
  # after it count on from there, which is how a rest keeps counting.
  #
  # THE LABEL is set in the face, size and colour of the BLOCK - the item's
  # runs may be bold, its label is not - and it is measured here, before a
  # byte is written: a face without U+2022, or without the digits, is
  # refused by name, never set in another face in silence.
  #
  # THE INDENT is 1.6 sizes, and more where the list's widest label needs
  # it. The label stands RIGHT-ALIGNED, ending half a size before the text:
  # so the numbers of a list line up on their full stops, "9." over "10.",
  # and every label keeps the same distance to its text - aligned left at
  # the band, "1." and "10." would stand with gaps of two widths. The price
  # of that alignment is width: in Helvetica "10." is 1.39 sizes, in DejaVu
  # Sans 1.59, and with the half size in front of the text neither fits into
  # 1.6 - aligned at 1.1 sizes it would begin to the left of the block's own
  # edge, in the margin. So the indent of a list is its widest label plus
  # the gap where that is more than 1.6 sizes, for every item of the list
  # alike; a bullet (0.35 sizes in Helvetica, 0.59 in DejaVu) and the numbers
  # 1 to 9 stay at 1.6. The bullet sits in the middle of the indent that way,
  # where a word processor puts it.
  method TextRunsItems {paragraphs options base baseState} {
    set unit [my cget -unit]
    set size [dict get $baseState size]
    set gap [::tclpdf::geometry fromPoints \
        [expr {$::tclpdf::textRun::itemGap * $size}] $unit]
    set least [::tclpdf::geometry fromPoints \
        [expr {$::tclpdf::textRun::itemIndent * $size}] $unit]
    set widest {}
    set previous {}
    set list 0
    foreach paragraph [lsort -integer [dict keys $paragraphs]] {
      set entry [dict get $paragraphs $paragraph]
      if {![dict exists $entry item]} {
        continue
      }
      set kind [dict get $entry item]
      if {[llength $previous] && [lindex $previous 0] == $paragraph - 1
          && [lindex $previous 1] eq $kind} {
        set ordinal [expr {[lindex $previous 2] + 1}]
      } else {
        incr list
        set ordinal 1
      }
      if {[dict exists $entry start]} {
        set ordinal [dict get $entry start]
      }
      # NOT [expr {... ? ... : "$ordinal."}]: expr reads "1." as a number
      # and answers "1.0" - measured, the first list came out numbered so.
      if {$kind eq "bullet"} {
        set marker $::tclpdf::textRun::bullet
      } else {
        set marker "$ordinal."
      }
      try {
        set width [my textWidth $marker {*}$base]
      } trap {TCLPDF FONT GLYPH} {message} {
        set alias [dict get $baseState resolved]
        if {$kind eq "bullet"} {
          return -code error -errorcode [list TCLPDF TEXT RUNS BULLET $alias] \
              "tclpdf: a bulleted list sets its bullet (U+2022) in the face\
              of the block, and \"$alias\" has no glyph for it - set the\
              block in a face that has one, or number the list"
        }
        return -code error -errorcode [list TCLPDF TEXT RUNS NUMBER $alias] \
            "tclpdf: a numbered list sets its number \"$marker\" in the face\
            of the block, and \"$alias\" lacks a glyph of it - set the block\
            in a face that has the digits and the full stop"
      }
      dict set entry ordinal $ordinal
      dict set entry list $list
      dict set entry marker $marker
      dict set entry markerWidth $width
      dict set entry gap $gap
      dict set paragraphs $paragraph $entry
      if {![dict exists $widest $list] || $width > [dict get $widest $list]} {
        dict set widest $list $width
      }
      set previous [list $paragraph $kind $ordinal]
    }
    if {![dict size $widest]} {
      return $paragraphs
    }
    # The indent per list, and whether it leaves a band: the question
    # [TextBlockDistances] asks of the three indents, asked once more with
    # the list's own indent beside them - a list in a column narrower than
    # its indent would be set one character per line.
    set column [my TextBlockColumn $options]
    set indents {}
    dict for {list width} $widest {
      set indent [expr {max($least, $width + $gap)}]
      dict set indents $list $indent
      set extra [expr {max(0, [dict get $options firstIndent])}]
      if {$column - [dict get $options indent] - [dict get $options indentRight]
          - $extra - $indent <= 0} {
        return -code error -errorcode [list TCLPDF TEXT INDENT width] \
            "tclpdf: a list item is indented by [format %g $indent] beside\
            -indent [format %g [dict get $options indent]] and -indentRight\
            [format %g [dict get $options indentRight]], and that leaves no\
            width inside a column of [format %g $column] - a line with no\
            band left is set one character at a time"
      }
    }
    dict for {paragraph entry} $paragraphs {
      if {[dict exists $entry list]} {
        dict set entry indent [dict get $indents [dict get $entry list]]
        dict set paragraphs $paragraph $entry
      }
    }
    return $paragraphs
  }

  # The style of a run from the block's style and the words the run gave:
  # a set, so "bold" over "italic" is both and "bold" over "bold" is bold.
  method TextRunsStyle {inherited words} {
    set style $inherited
    foreach word $words {
      if {![dict exists $::tclpdf::textRun::styles $word]} {
        return -code error -errorcode [list TCLPDF TEXT RUNS STYLE $word] \
            "tclpdf: a run's style is bold, italic or both, not \"$word\""
      }
      set word [dict get $::tclpdf::textRun::styles $word]
      if {$word ni $style} {
        lappend style $word
      }
    }
    return [lsort $style]
  }

  # The arguments of the run that holds the character at a string index -
  # the block's own where no run does, which is what a character between
  # two runs, or a caller's string without runs, comes back with.
  method TextRunsArgumentsAt {map index arguments} {
    foreach entry $map {
      lassign $entry from to
      if {$index >= $from && $index < $to} {
        return [lindex $entry 3]
      }
    }
    return $arguments
  }

  # A chunk of the breaker laid over the map: answers a list of {index piece}
  # pairs, index the position of the run in the map (-1 for a character no
  # run covers), piece the characters of the chunk that fall into it, in
  # order. Two neighbouring pieces never share a run.
  #
  # base is where in the string the chunk begins. See the head of the file
  # for why this walks instead of counting.
  method TextRunsSplit {chunk map base} {
    set separators "$::tclpdf::textBlock::separators$::tclpdf::textBlock::breakable"
    set skipped $::tclpdf::textRun::skipped
    set string [my state textRunsString]
    set length [string length $string]
    set at $base
    set pieces {}
    set current -2
    set piece {}
    foreach char [split $chunk {}] {
      if {[string first $char $separators] >= 0} {
        # The one space the breaker puts for a run of separators: consume
        # the run, and let the space belong to the run of its first one.
        set here $at
        while {$at < $length
            && [string first [string index $string $at] $separators] >= 0} {
          incr at
        }
        if {$here == $at} {
          # A separator the string has not - the breaker's glue between
          # two words that touched through a breakable space it stripped.
          # It stands in the run of the character before it.
          set here [expr {max($base, $at - 1)}]
        }
        set index [my TextRunsIndexAt $map $here]
      } else {
        # A character the chunk has and the string has at this very place
        # is taken as it stands - which covers a soft hyphen the chunk still
        # carries. Only where the two differ may the string be skipped over:
        # a mark a hyphenation head has lost, a zero width space, a BOM.
        if {!($at < $length && [string index $string $at] eq $char)} {
          while {$at < $length
              && [string first [string index $string $at] $skipped] >= 0} {
            incr at
          }
        }
        if {$at < $length && [string index $string $at] eq $char} {
          set index [my TextRunsIndexAt $map $at]
          incr at
        } elseif {$char eq "-"} {
          # The hyphen the breaker sets at a break: nobody's character, so
          # it stays with the run the line ends in.
          set index [expr {$current == -2 ? [my TextRunsIndexAt $map $base] : $current}]
        } else {
          return -code error -errorcode [list TCLPDF TEXT RUNS INTERNAL walk] \
              "tclpdf: the runs of a block lost their place in its text at\
              character $at (\"[string index $string $at]\" against\
              \"$char\") - this is a defect of the package, not of the\
              call; please report the text that caused it"
        }
      }
      if {$index != $current && $piece ne {}} {
        lappend pieces [list $current $piece]
        set piece {}
      }
      set current $index
      append piece $char
    }
    if {$piece ne {}} {
      lappend pieces [list $current $piece]
    }
    return $pieces
  }

  # Which run of the map holds a string index; -1 for none.
  method TextRunsIndexAt {map index} {
    set position 0
    foreach entry $map {
      lassign $entry from to
      if {$index >= $from && $index < $to} {
        return $position
      }
      incr position
    }
    return -1
  }

  # The font arguments of a piece: the run's, or the block's for a piece no
  # run covers.
  method TextRunsPieceArguments {map index arguments} {
    if {$index < 0} {
      return $arguments
    }
    return [lindex [lindex $map $index] 3]
  }

  # The width of a chunk set as its pieces, in the document unit: each piece
  # in its own run's face, the character spacing of the block between two
  # pieces - a boundary is a place between two characters like any other,
  # and [textWidth] counts the spacing inside a piece only.
  method TextRunsMeasure {pieces map arguments} {
    set width 0
    set spacing {}
    foreach piece $pieces {
      lassign $piece index text
      set own [my TextRunsPieceArguments $map $index $arguments]
      if {$spacing ne {}} {
        set width [expr {$width + $spacing}]
      }
      set width [expr {$width + [my textWidth $text {*}$own]}]
      set spacing [::tclpdf::geometry fromPoints \
          [dict get [my TextMerge $own] spacing] [my cget -unit]]
    }
    return $width
  }

  # The runs of a block as the caller wrote them, from a string index on:
  # the shape a rest is handed back in, and the shape of one line of
  # [textLines]. Each pair carries the run's style as {style ...} and
  # nothing where the run had no options, exactly as it came in.
  method TextRunsSlice {map string from {to {}}} {
    if {$to eq {}} {
      set to [string length $string]
    }
    set pairs {}
    set at $from
    foreach entry $map {
      lassign $entry runFrom runTo style arguments given
      if {$runTo <= $at} {
        continue
      }
      if {$runFrom >= $to} {
        break
      }
      if {$runFrom > $at} {
        lappend pairs [string range $string $at $runFrom-1] {}
        set at $runFrom
      }
      set end [expr {min($runTo, $to)}]
      lappend pairs [string range $string $at $end-1] $given
      set at $end
    }
    if {$at < $to} {
      lappend pairs [string range $string $at $to-1] {}
    }
    return $pairs
  }

  # One line of [textLines -runs 1]: the pieces of the line's text as pairs,
  # the way the caller wrote the runs - with the hyphen of a break inside
  # the last piece, as the line's text has it.
  method TextRunsLine {text map from} {
    set pairs {}
    foreach piece [my TextRunsSplit $text $map $from] {
      lassign $piece index chunk
      lappend pairs $chunk [expr {$index < 0 ? {} : [lindex [lindex $map $index] 4]}]
    }
    return $pairs
  }

  # What a run draws beside its glyphs, and where it is drawn from.
  #
  # An underline, a strikeout and the rectangle of a link are not glyphs:
  # the line is a stroked path, the link an annotation, and neither belongs
  # inside the text object or inside the marked content of the paragraph -
  # in a tagged document a stroke inside a P would be content of the
  # paragraph, and ISO 14289 wants it as an artifact. So the pieces RECORD
  # what they need drawn, in page coordinates, and [TextRunsFlush] draws it
  # after the block's mark has closed: the strokes inside one artifact, the
  # links as annotations, which is what [link] makes of them. A paginated
  # block flushes per page, before the page is turned.
  #
  # Where the line goes is the face's business first ([FontDecoration] for
  # an embedded face, the AFM's UnderlinePosition for a standard one) and a
  # fraction of the size where the face says nothing. A link is underlined
  # unless its run says -underline 0, and drawn in the colour of the text -
  # which is what a link looks like in print.
  method TextRunsDecorationMetrics {state kind} {
    set font [dict get $state resolved]
    set size [dict get $state size]
    set stated {}
    if {[my TextEmbedded $font]} {
      set stated [my FontDecoration $font $size $kind]
    } elseif {$kind eq "underline"} {
      set descriptor [::tclpdf::afm descriptor $font]
      if {[dict exists $descriptor UnderlinePosition]
          && [dict get $descriptor UnderlineThickness] ne {}} {
        set stated [list \
            [expr {[dict get $descriptor UnderlinePosition] * $size / 1000.0}] \
            [expr {[dict get $descriptor UnderlineThickness] * $size / 1000.0}]]
      }
    }
    if {$stated ne {}} {
      return $stated
    }
    lassign [dict get $::tclpdf::textRun::fallback $kind] position thickness
    return [list [expr {$position * $size}] [expr {$thickness * $size}]]
  }

  # One piece's decorations, recorded for [TextRunsFlush]: the strokes as
  # {px py rotate from to y thickness colour} in PDF points relative to the
  # anchor of the line, the links as {x y w h url} in the document unit.
  method TextRunsRecord {given state anchor y rotate shift lift width} {
    set unit [my cget -unit]
    set size [dict get $state size]
    set url [expr {[dict exists $given url] ? [dict get $given url] : {}}]
    set underline [expr {[dict exists $given underline]
        ? [dict get $given underline] : ($url ne {})}]
    set strike [expr {[dict exists $given strike] ? [dict get $given strike] : 0}]
    if {$underline || $strike} {
      lassign [my coords $anchor $y] px py
      set from [expr {-[::tclpdf::geometry toPoints $shift $unit]}]
      set to [expr {$from + [::tclpdf::geometry toPoints $width $unit]}]
      set base [expr {-[::tclpdf::geometry toPoints $lift $unit]}]
      set colour [::tclpdf::color operator [::tclpdf::color parse \
          [my GraphicsColour [dict get $state color] text]] stroke]
      set strokes [my state textRunsStrokes]
      foreach {kind wanted} [list underline $underline strike $strike] {
        if {!$wanted} {
          continue
        }
        lassign [my TextRunsDecorationMetrics $state $kind] position thickness
        lappend strokes [list $px $py $rotate $from $to \
            [expr {$base + $position}] $thickness $colour]
      }
      my state textRunsStrokes $strokes
    }
    if {$url ne {}} {
      set ascent [my TextLift $state top]
      set descent [::tclpdf::geometry fromPoints \
          [my TextFitDescent [dict get $state resolved] $size] $unit]
      set links [my state textRunsLinks]
      lappend links [list [expr {$anchor - $shift}] \
          [expr {$y + $lift - $ascent}] $width [expr {$ascent + $descent}] $url]
      my state textRunsLinks $links
    }
    return
  }

  # Draw what the pieces recorded, and forget it. Called where the block's
  # marked content has just closed - [text], and [TextPaginate] once per
  # page - and with "discard" where the drawing failed, so that nothing of
  # a refused block reaches the page later.
  method TextRunsFlush {{discard 0}} {
    set strokes [my state textRunsStrokes]
    set links [my state textRunsLinks]
    my state textRunsStrokes {}
    my state textRunsLinks {}
    if {$discard} {
      return
    }
    if {[llength $strokes]} {
      set mark {}
      if {[my state tagged] eq "1"} {
        set mark [my StructureMark Artifact Layout]
        my content [my StructureBegin $mark]
      }
      foreach stroke $strokes {
        lassign $stroke px py rotate from to at thickness colour
        my content "q\n"
        # The colour operator comes without its line end, as [TextRun] gets
        # it - measured: poppler read "0 G0.5 w" as one unknown operator.
        my content "$colour\n"
        my content "[::tclpdf::pdfObj num $thickness] w\n"
        if {$rotate != 0} {
          set matrix [::tclpdf::geometry multiply \
              [::tclpdf::geometry rotate $rotate] \
              [::tclpdf::geometry translate $px $py]]
          my content "[join [lmap n $matrix {::tclpdf::pdfObj num $n}] { }] cm\n"
          set px 0
          set py 0
        }
        my content "[::tclpdf::pdfObj num [expr {$px + $from}]]\
            [::tclpdf::pdfObj num [expr {$py + $at}]] m\
            [::tclpdf::pdfObj num [expr {$px + $to}]]\
            [::tclpdf::pdfObj num [expr {$py + $at}]] l S\nQ\n"
      }
      if {[llength $mark]} {
        my content [my StructureEnd $mark]
      }
    }
    foreach entry $links {
      lassign $entry x y w h url
      my link -at [list $x $y] -size [list $w $h] -url $url
    }
    return
  }

  # A line drawn as its pieces, in place of the one [TextRun] a line without
  # runs is. Same arguments as [TextParagraphLine] plus the line's place in
  # the string; the alignment is worked out over the pieces' widths, and
  # every piece is drawn at the same anchor with a shift of its own along
  # the baseline - the road [TextRun] takes for -align right, so a rotated
  # paragraph turns its pieces with the line.
  method TextRunsDraw {line state from x y width align isLast rotate lift hyphen followed split} {
    set map [my state textRuns]
    set base [my TextStateArguments $state]
    set pieces [my TextRunsSplit $line $map $from]
    # The word space a tagged document appends for the extraction (see
    # TextParagraphLine): after the last glyph of the line, so it belongs to
    # the last piece and moves nothing.
    set appended [expr {(!$isLast || $followed) && !$split
        && [my state tagged] eq "1"}]
    # Justification: the gap over the spaces of the whole line, then the
    # same extra word spacing in every piece - a space is stretched by what
    # it is, not by whose run it stands in.
    set extra 0
    set justified 0
    if {$align eq "justify"} {
      set spaces [regexp -all { } $line]
      if {!$isLast && $spaces >= 1} {
        set gap [expr {$width - [my TextRunsMeasure $pieces $map $base]}]
        set extra [expr {[::tclpdf::geometry toPoints \
            [expr {$gap / double($spaces)}] [my cget -unit]]
            / ([dict get $state stretch] / 100.0)}]
        set justified 1
      }
    }
    # The states and the advances, piece by piece, measured with the word
    # spacing the piece is drawn with.
    set states {}
    set advances {}
    set total 0
    set count [llength $pieces]
    for {set index 0} {$index < $count} {incr index} {
      lassign [lindex $pieces $index] runIndex text
      set own [my TextRunsPieceArguments $map $runIndex $base]
      set pieceState [my TextMerge $own]
      if {$justified} {
        dict set pieceState wordSpacing \
            [expr {[dict get $pieceState wordSpacing] + $extra}]
      }
      lappend states $pieceState
      set advance [my textWidth $text {*}[my TextStateArguments $pieceState]]
      if {$index < $count - 1} {
        set advance [expr {$advance + [::tclpdf::geometry fromPoints \
            [dict get $pieceState spacing] [my cget -unit]]}]
      }
      lappend advances $advance
      set total [expr {$total + $advance}]
    }
    switch -- $align {
      left - justify {set start 0}
      right {set start $total}
      center - centre {set start [expr {$total / 2.0}]}
      default {
        my TextAlignUnknown $align
      }
    }
    set anchor [expr {$align eq "right" ? $x + $width
        : ($align in {center centre} ? $x + $width / 2.0 : $x)}]
    set shift $start
    for {set index 0} {$index < $count} {incr index} {
      lassign [lindex $pieces $index] runIndex text
      set last [expr {$index == $count - 1}]
      set drawnText $text
      if {$last && $appended} {
        append drawnText " "
      }
      my TextRun $drawnText [lindex $states $index] $anchor $y $rotate $shift \
          $lift [expr {$last && $hyphen}]
      if {$runIndex >= 0} {
        set given [lindex [lindex $map $runIndex] 4]
        if {[dict exists $given underline] || [dict exists $given strike]
            || [dict exists $given url]} {
          # The piece's own width, without the character spacing that
          # separates it from the next piece: a line ends with its glyphs.
          set own [my textWidth $text {*}[my TextStateArguments \
              [lindex $states $index]]]
          my TextRunsRecord $given [lindex $states $index] $anchor $y \
              $rotate $shift $lift $own
        }
      }
      set shift [expr {$shift - [lindex $advances $index]}]
    }
    return
  }


}

oo::define ::tclpdf::document::document {
  # The rest of a height-limited block, in the shape the caller wrote the
  # runs in. A rest is always a tail of the string verbatim (TextParagraphDraw
  # hands back "string range ... from end"), so where it begins is the length
  # of the whole less the length of the rest - no position has to travel.
  #
  # A rest that begins in a list item keeps its place in the list: the
  # first pair says the number the item has where it is not 1 ("start"), and
  # "continued 1" where the cut fell inside the item, so that the rest set
  # again draws no second label and keeps the indent. Without the two a rest
  # would begin a new list at 1 with a label in the middle of a sentence.
  method TextRunsRest {map string rest {paragraphs {}}} {
    if {$rest eq {}} {
      return {}
    }
    set from [expr {[string length $string] - [string length $rest]}]
    set pairs [my TextRunsSlice $map $string $from]
    set paragraph [regexp -all \n [string range $string 0 $from-1]]
    if {[llength $pairs] < 2 || ![dict exists $paragraphs $paragraph item]} {
      return $pairs
    }
    set entry [dict get $paragraphs $paragraph]
    set given [lindex $pairs 1]
    if {[dict get $entry item] eq "number" && [dict get $entry ordinal] != 1} {
      dict set given start [dict get $entry ordinal]
    }
    set begins [expr {[string last \n $string $from-1] + 1}]
    if {$from > $begins || [dict exists $entry continued]} {
      dict set given continued 1
    }
    lset pairs 1 $given
    return $pairs
  }

  # WHAT A PARAGRAPH STATE WRITES WHERE ITS PARAGRAPH BEGINS, called by
  # [TextParagraphDraw] for the first drawn line of every paragraph of a
  # block that has one - headings and list items take this one road.
  #
  # In a tagged document the marks are per paragraph: H1 to H3 for a
  # heading, the block's -tag for plain text, and for a list item an LI in
  # an L - the L opened with the first item of a list and closed after its
  # last, the LI holding a Lbl with the label and a LBody with the text, in
  # that order (Annex L; the Lbl first, structure.tcl). The list is named
  # Disc or Decimal after its labels, which is what PDF/UA-1 7.6 and part 2,
  # 8.2.5.25 ask of a list whose items carry a Lbl. An Artifact block stays
  # one artifact per paragraph and draws its labels inside it.
  #
  # A CONTINUED item - the head of a rest, whose label was drawn by the call
  # before - draws no label, and in a tagged document it cannot be the LI it
  # continues: that one was closed with the call that opened it. It is set
  # as the block's -tag, a paragraph in front of the list, the shape a
  # paragraph split over two calls with -height has as well (two P).
  #
  # marking is what the previous paragraph left open, as {mark m li id l id
  # list k}; the answer is what this one leaves open, for the next call and
  # finally for [TextRunsParagraphClose].
  method TextRunsParagraph {marking paragraph line state tag x y lift top ascent rotate} {
    set paragraphs [my state textRunsParagraphs]
    set entry [expr {[dict exists $paragraphs $paragraph]
        ? [dict get $paragraphs $paragraph] : {}}]
    set continued [dict exists $entry continued]
    set item [expr {[dict exists $entry item] && !$continued}]
    set label [expr {$item && [dict get $line first]}]
    if {[my state tagged] ne "1"} {
      if {$label} {
        my TextRunsLabel $entry $line $state $x $y $lift $top $rotate
      }
      return $marking
    }
    set artifact [expr {[lindex $tag 0] eq "Artifact"}]
    # The list stays open while the items of one list follow each other.
    set marking [my TextRunsParagraphClose $marking [expr {$item && !$artifact
        && [dict exists $marking list]
        && [dict get $marking list] == [dict get $entry list]}]]
    set markTop [expr {$y + $lift + $top - $ascent}]
    if {$item && !$artifact} {
      if {![dict exists $marking l]} {
        dict set marking l [my StructureOpen L [dict create numbering \
            [dict get $::tclpdf::textRun::items [dict get $entry item]]]]
        dict set marking list [dict get $entry list]
      }
      dict set marking li [my StructureOpen LI]
      if {$label} {
        set mark [my StructureMark Lbl Layout $markTop]
        my content [my StructureBegin $mark]
        my TextRunsLabel $entry $line $state $x $y $lift $top $rotate
        my content [my StructureEnd $mark]
      }
      set mark [my StructureMark LBody Layout $markTop]
    } else {
      set own $tag
      if {[dict exists $entry heading] && !$artifact} {
        set own H[dict get $entry heading]
      }
      set mark [my StructureMark $own Layout $markTop]
    }
    my content [my StructureBegin $mark]
    dict set marking mark $mark
    if {$label && $artifact} {
      my TextRunsLabel $entry $line $state $x $y $lift $top $rotate
    }
    return $marking
  }

  # Close what a paragraph left open - its mark, its LI and, unless the
  # next paragraph is an item of the same list (keepList), its L - and
  # answer what stays open. Called between two paragraphs and after the
  # last, where nothing stays.
  method TextRunsParagraphClose {marking {keepList 0}} {
    if {[dict exists $marking mark]} {
      my content [my StructureEnd [dict get $marking mark]]
      dict unset marking mark
    }
    if {[dict exists $marking li]} {
      my StructureClose [dict get $marking li]
      dict unset marking li
    }
    if {[dict exists $marking l] && !$keepList} {
      my StructureClose [dict get $marking l]
      dict unset marking l
      dict unset marking list
    }
    return $marking
  }

  # The label of a list item, on the baseline of its first line: right-
  # aligned against the line's own start less the gap (see TextRunsItems for
  # why right), in the block's state - its face, size and colour. Drawn from
  # the same anchor as the line with a shift back along the baseline, the
  # road [TextRun] takes for -align right, so a rotated block turns the
  # label with its line. A tagged document gets the word space after it
  # that every line gets for the extraction (TextParagraphLine): "1." and
  # the text are two words to a reader, and the space sits after the last
  # glyph of the label, where it moves nothing.
  method TextRunsLabel {entry line state x y lift top rotate} {
    set text [dict get $entry marker]
    if {[my state tagged] eq "1"} {
      append text " "
    }
    my TextRun $text $state [expr {$x + [dict get $line offset]}] $y $rotate \
        [expr {[dict get $entry gap] + [dict get $entry markerWidth]}] \
        [expr {$lift + $top}] 0
    return
  }
}

package provide tclpdf::textRun 1.2
