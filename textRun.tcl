#
# tclpdf - PDF generation for Tcl
#
# textRun - runs of one paragraph: a fat word, an italic name, a link, set
# in the middle of flowing text, with the line breaker running over all of it
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
  variable options {style heading underline strike url strong em}

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
  # at a paragraph boundary, which is what keeps every line one height.
  # So a pair with "heading n" is closed off with a line feed on either
  # side where the caller left one out - inside the pair's own text, so
  # that a rest handed back and set again arrives already bounded. The
  # options gain, beside the map, "runsHeadings" (paragraph index -> level),
  # "runsLeadings" (paragraph index -> leading in the document unit) and
  # "runsFirst" (the arguments of paragraph 0 where it is a heading, for
  # the lift of the first baseline).
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
    set headings {}
    set leadings {}
    set first {}
    # The level of the heading paragraph in progress, {} between headings:
    # runs of one heading that follow each other ("Kapitel " and "zwei" of
    # <h2>Kapitel <i>zwei</i></h2>) share the paragraph, and the line feed
    # that closes it is written only where something follows - never twice,
    # so a caller's own line feed in front of the next text is respected.
    set headingOpen {}
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
          underline - strike - strong - em {
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
        }
      }
      if {$heading ne {}} {
        set style [my TextRunsStyle $style bold]
        if {$headingOpen ne $heading} {
          if {$string ne {} && [string index $string end] ne "\n"} {
            append string "\n"
          }
          set headingOpen $heading
        }
      } elseif {$headingOpen ne {}} {
        if {$string ne {} && [string index $string end] ne "\n"
            && [string index $text 0] ne "\n"} {
          append string "\n"
        }
        set headingOpen {}
      }
      if {$plainAlias && $style ne {}} {
        return -code error -errorcode [list TCLPDF TEXT RUNS FAMILY $family] \
            "tclpdf: a run asks for style \"$style\", and \"$family\" is\
            the alias of one embedded face, which has no bold or italic of\
            its own - register the faces as a family with \[font family\]\
            and set the block in that family"
      }
      set from [string length $string]
      append string $text
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
        # Which paragraph this is: the line feeds in front of it, each of
        # which the breaker takes as a paragraph boundary.
        set paragraph [regexp -all \n [string range $string 0 $from-1]]
        dict set headings $paragraph $heading
        dict set leadings $paragraph [expr {$baseLeading * $factor}]
        if {$paragraph == 0} {
          set first $arguments
        }
      }
      lappend map [list $from [string length $string] $style $arguments $given]
    }
    dict set options runs $map
    dict set options runsHeadings $headings
    dict set options runsLeadings $leadings
    dict set options runsFirst $first
    if {[dict size $headings]} {
      # The marks of a tagged document are opened per PARAGRAPH where a
      # block carries headings - H1 to H3 beside P - and the paginating
      # roads open theirs per page, one for the whole block. The two do not
      # meet yet; refused by name rather than tagged wrong.
      if {[my state tagged] eq "1" && ([dict get $options paginate]
          || [dict get $options columns] > 1)} {
        return -code error -errorcode [list TCLPDF TEXT RUNS HEADING marks] \
            "tclpdf: a heading in a tagged block is a structure element of\
            its own, and a block set with -paginate or -columns marks its\
            content per page - the two are not combined; set the headings\
            as blocks of their own"
      }
      if {[dict exists $options expansion] && [dict get $options expansion] ne {}} {
        return -code error -errorcode [list TCLPDF TEXT RUNS HEADING expansion] \
            "tclpdf: -expansion wraps the whole block in one Span, and a\
            block with headings is several elements - give the expansion to\
            the paragraph it belongs to, as a block of its own"
      }
    }
    return [list $string $options]
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
  method TextRunsRest {map string rest} {
    if {$rest eq {}} {
      return {}
    }
    return [my TextRunsSlice $map $string \
        [expr {[string length $string] - [string length $rest]}]]
  }
}

package provide tclpdf::textRun 1.0
