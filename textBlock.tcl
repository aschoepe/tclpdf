#
# tclpdf - PDF generation for Tcl
#
# textBlock - line breaking, alignment and justification
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Split off text.tcl at the topic boundary: font state and one line there, the
# paragraph here. Reached through [$doc text ... -width W] rather than by a
# name of its own - a caller should not have to know which of the two files a
# method lives in.
#
# Justification stretches the SPACES (Tw), not the letters. Stretching letters
# is what a naive implementation does and it is visibly wrong: the last line of
# a paragraph is never justified either, which is why the loop below treats it
# separately instead of running the same code over every line.
#
# No hyphenation. A word longer than the column is broken by character rather
# than pushed over the edge, and that break is a fallback, not typography -
# proper hyphenation needs language data and is a feature of its own.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::afm 1.0-
package require tclpdf::option 1.0-
package require tclpdf::text 1.0-

namespace eval ::tclpdf::textBlock {}

oo::define ::tclpdf::document::document {

  # Break a string into lines that fit a width, in the document unit.
  # Explicit newlines are honoured and start a new paragraph.
  method textLines {string args} {
    my TextInit
    lassign [my TextBlockWidth $args] width args
    return [lmap line [my TextBlockBreak $string $args \
        [list apply {{width line paragraph running} {list $width 0}} $width]] {
      dict get $line text
    }]
  }

  # The line breaker itself. Everything wrapped in this package comes through
  # here, and it is the ONE place that decides where a line ends.
  #
  # band is a command prefix called with three numbers: the index of the line
  # inside its paragraph (0 for the first), the index of the paragraph, and the
  # running line number over the whole block. It answers {width offset}: how
  # wide this line may be, and how far in from the left edge it starts. The
  # running number is what lets a band know its vertical position - which is
  # everything, once the text has to flow around a shape. A constant band is what [textLines] asks for; an indent
  # narrows the first line of each paragraph; flowing around a shape varies
  # every line. Keeping that decision outside the loop is what lets all three
  # share one breaker instead of growing a second copy.
  #
  # Returns one dictionary per line: text, offset, width, paragraph, and
  # first - whether it opens its paragraph.
  method TextBlockBreak {string arguments band} {
    set lines {}
    set paragraphIndex 0
    set globalLine 0
    foreach paragraph [split $string \n] {
      if {[string trim $paragraph] eq {}} {
        lassign [{*}$band 0 $paragraphIndex $globalLine] width offset
        lappend lines [dict create text {} offset $offset width $width \
            paragraph $paragraphIndex first 1]
        incr paragraphIndex
        incr globalLine
        continue
      }
      set inParagraph 0
      lassign [{*}$band $inParagraph $paragraphIndex $globalLine] width offset
      set current {}
      foreach word [regexp -all -inline {\S+} $paragraph] {
        # NOT [expr {$current eq {} ? $word : "..."}]: expr normalises a word
        # that looks like a number, and "1234.50" comes back as "1234.5". The
        # trailing zero is gone from every amount in every wrapped paragraph,
        # and nothing reports it - the document is perfectly valid and the
        # figure is wrong.
        if {$current eq {}} {
          set candidate $word
        } else {
          set candidate "$current $word"
        }
        if {[my textWidth $candidate {*}$arguments] <= $width} {
          set current $candidate
          continue
        }
        if {$current ne {}} {
          lappend lines [dict create text $current offset $offset \
              width $width paragraph $paragraphIndex \
              first [expr {$inParagraph == 0}]]
          incr inParagraph
          incr globalLine
          lassign [{*}$band $inParagraph $paragraphIndex $globalLine] width offset
          set current {}
        }
        # The word alone may still be too wide - a part number, a URL, a
        # column two millimetres across. Break it by character rather than
        # letting it run past the edge unnoticed.
        while {[my textWidth $word {*}$arguments] > $width && [string length $word] > 1} {
          set take [string length $word]
          while {$take > 1 && [my textWidth [string range $word 0 $take-1] {*}$arguments] > $width} {
            incr take -1
          }
          lappend lines [dict create text [string range $word 0 $take-1] \
              offset $offset width $width paragraph $paragraphIndex \
              first [expr {$inParagraph == 0}]]
          incr inParagraph
          incr globalLine
          lassign [{*}$band $inParagraph $paragraphIndex $globalLine] width offset
          set word [string range $word $take end]
        }
        set current $word
      }
      if {$current ne {}} {
        lappend lines [dict create text $current offset $offset width $width \
            paragraph $paragraphIndex first [expr {$inParagraph == 0}]]
        incr globalLine
      }
      incr paragraphIndex
    }
    return $lines
  }

  # The height a block would occupy, without drawing it - for deciding whether
  # it still fits on the page.
  # The width may be given either way, and BOTH have to work.
  #
  #   $doc textHeight $text -width 170      what the manual says
  #   $doc textHeight $text 170             what the code has always taken
  #
  # The manual documented the option form for four releases while the methods
  # took the width positionally - so "textLines $text -width 170" bound the
  # STRING "-width" as the width, every word was too wide for it, and the
  # result came back one character per line. textHeight then multiplied that
  # count by the leading and answered 287 mm for a two-line paragraph. No
  # error anywhere; the numbers are simply wrong.
  #
  # Told apart by the leading dash, because a width never starts with one.
  method TextBlockWidth {arguments} {
    if {[llength $arguments] && [string index [lindex $arguments 0] 0] ne "-"} {
      return [list [lindex $arguments 0] [lrange $arguments 1 end]]
    }
    set options [::tclpdf::option partition {width {}} $arguments]
    set width [dict get [lindex $options 0] width]
    if {$width eq {}} {
      return -code error "tclpdf: a text block needs -width"
    }
    return [list $width [lindex $options 1]]
  }

  method textHeight {string args} {
    my TextInit
    lassign [my TextBlockWidth $args] width args
    set state [my TextMerge $args]
    set count [llength [my textLines $string $width {*}$args]]
    return [expr {$count * [::tclpdf::geometry fromPoints \
        [dict get $state leading] [my cget -unit]]}]
  }

  # Called by [text] when -width is given. Returns the y coordinate BELOW the
  # block, so the next element can be placed without counting lines.
  method TextParagraph {string options} {
    set state [my TextMerge [my TextOverrides $options]]
    set width [dict get $options width]
    set align [dict get $options align]
    lassign [dict get $options at] x y

    set leading [::tclpdf::geometry fromPoints [dict get $state leading] \
        [my cget -unit]]

    # The anchor stays put and every line says how far BELOW it its baseline
    # sits. Advancing y instead was correct only as long as nothing turned:
    # each line was rotated about its own advanced point, so a rotated
    # paragraph drew all of its lines on top of one another - measured, and
    # unreadable. As a lift the advance goes through the text matrix and turns
    # with the text, which is what makes the lines run across the page.
    set lift [my TextLift $state [dict get $options anchor]]

    # The band this paragraph is set in: the column narrowed by the indents,
    # and the first line of each paragraph narrowed once more. A negative
    # -firstIndent is a hanging indent and is the reason the offset is carried
    # per line rather than added to x once.
    set indent [dict get $options indent]
    set indentRight [dict get $options indentRight]
    set firstIndent [dict get $options firstIndent]
    set band [list apply {{width indent indentRight firstIndent line paragraph running} {
      set extra [expr {$line == 0 ? $firstIndent : 0}]
      return [list [expr {$width - $indent - $indentRight - $extra}] \
          [expr {$indent + $extra}]]
    }} $width $indent $indentRight $firstIndent]

    # Shapes to flow around narrow the band per line instead of per paragraph.
    # Loaded only when asked for: a caller who never avoids anything does not
    # pay for the module.
    if {[llength [dict get $options avoid]]} {
      package require tclpdf::textAvoid
      my TextAvoidCheck [dict get $options avoid]
      set inner [expr {$width - $indent - $indentRight}]
      # "my", not the object name: the band is expanded inside a method of
      # this object, and TextAvoidBand is private - reaching it from outside
      # would need an export that nothing else wants.
      set band [list my TextAvoidBand [dict get $options avoid] \
          [dict get $options avoidMargin] \
          [expr {$x + $indent}] $y $inner $leading \
          [dict get $options paragraphSpacing]]
    }

    set lines [my TextBlockBreak $string [my TextOverrides $options] $band]

    # Which lines close their paragraph - decided on the WHOLE text, before
    # anything is held back for a height limit. A line that ends a column is
    # not the end of its paragraph: its paragraph continues in the next
    # column, so it stays justified. Deciding this on the drawn part alone set
    # the last line of every column flush left, which reads as a paragraph
    # ending there and is exactly the kind of wrong that looks deliberate.
    set count [llength $lines]
    for {set index 0} {$index < $count} {incr index} {
      set closes [expr {$index == $count - 1
          || [dict get [lindex $lines $index+1] paragraph]
             != [dict get [lindex $lines $index] paragraph]}]
      lset lines $index [dict replace [lindex $lines $index] closes $closes]
    }

    # A height limit turns the block into the first of several: what fits is
    # drawn, what does not is handed back. The caller decides where the rest
    # goes - the next column, the next page - which is why this method does
    # not try to know.
    set limit [dict get $options height]
    set spacing [dict get $options paragraphSpacing]
    set drawn {}
    set rest {}
    set offsetY 0
    set previousParagraph {}
    foreach line $lines {
      set paragraph [dict get $line paragraph]
      if {$previousParagraph ne {} && $paragraph != $previousParagraph} {
        set offsetY [expr {$offsetY + $spacing}]
      }
      set previousParagraph $paragraph
      if {[llength $rest] || ($limit ne {} && $offsetY + $leading > $limit)} {
        # Once one line has been held back, everything after it goes with it -
        # otherwise a short line would jump ahead of a long one.
        lappend rest $line
        continue
      }
      lappend drawn [list $line $offsetY]
      set offsetY [expr {$offsetY + $leading}]
    }

    set last [expr {[llength $drawn] - 1}]
    set index 0
    foreach entry $drawn {
      lassign $entry line lineOffset
      if {[dict get $line text] ne {}} {
        my TextParagraphLine [dict get $line text] $state \
            [expr {$x + [dict get $line offset]}] $y [dict get $line width] \
            $align [dict get $line closes] [dict get $options rotate] \
            [expr {$lift + $lineOffset}]
      }
      incr index
    }
    if {$limit ne {}} {
      # Text, not lines: the rest may have to be broken again for a column of
      # a different width, and handing back lines would silently fix the old
      # break points. Paragraphs keep their boundaries.
      set text {}
      set current {}
      set paragraph {}
      foreach line $rest {
        if {$paragraph ne {} && [dict get $line paragraph] != $paragraph} {
          lappend text [join $current { }]
          set current {}
        }
        set paragraph [dict get $line paragraph]
        if {[dict get $line text] ne {}} {
          lappend current [dict get $line text]
        }
      }
      if {[llength $current]} {
        lappend text [join $current { }]
      }
      return [dict create y [expr {$y + $lift + $offsetY}] \
          rest [join $text \n]]
    }
    # Where the next element goes: the baseline one line below the block. The
    # lift belongs IN it - with -anchor top the caller gave the top edge, and
    # the answer is a baseline, so the ascender is part of the distance.
    # Dropping it moved every element after a paragraph up by one ascender,
    # which the rendered examples caught and no test did.
    #
    # For a rotated block the block does not run down the page at all; a caller
    # placing the next element has the angle and can say better than this
    # method where "below" is.
    return [expr {$y + $lift + $offsetY}]
  }

  # Alignment inside the column is a shift along the baseline and is passed
  # to TextRun rather than applied to x - with -rotate the baseline is
  # turned, and a pre-shifted x would rotate about the wrong point (same
  # reasoning as in [text], text.tcl).
  method TextParagraphLine {line state x y width align isLast rotate {lift 0}} {
    # The space the line breaker consumed has to reappear in the content
    # stream: a line ends where a word ended, and without it the next line
    # follows immediately - "der Antrieb ist" plus "getauscht" comes back out
    # as "istgetauscht" to anything that reads the text rather than the page.
    # ISO 32000-1 14.8.2.6 says so for tagged documents, and it is measured:
    # pdfinfo -struct-text showed exactly that, while neither veraPDF profile
    # noticed.
    #
    # It goes into the DRAWN string only, never into the measured one - the
    # widths below decide the alignment, and a trailing space must not move
    # a right aligned or centred line. Visually it changes nothing either
    # way: it sits after the last glyph of the line.
    #
    # Only for tagged documents, so nothing that exists today comes out with
    # different bytes.
    set drawn $line
    if {!$isLast && [my state tagged] eq "1"} {
      append drawn " "
    }
    switch -- $align {
      left {
        my TextRun $drawn $state $x $y $rotate 0 $lift
      }
      right {
        my TextRun $drawn $state [expr {$x + $width}] $y $rotate \
            [my TextLineWidth $line $state] $lift
      }
      center - centre {
        my TextRun $drawn $state [expr {$x + $width / 2.0}] $y $rotate \
            [expr {[my TextLineWidth $line $state] / 2.0}] $lift
      }
      justify {
        # The last line of a paragraph stays flush left. Justifying it is the
        # classic mistake - one word on a line gets stretched across the whole
        # column and the result is unmistakably broken.
        set spaces [expr {[llength [regexp -all -inline {\S+} $line]] - 1}]
        if {$isLast || $spaces < 1} {
          my TextRun $drawn $state $x $y $rotate 0 $lift
          return
        }
        set gap [expr {$width - [my TextLineWidth $line $state]}]
        set extra [::tclpdf::geometry toPoints [expr {$gap / double($spaces)}] \
            [my cget -unit]]
        # Tw adds to every space character, which is exactly the unit the gap
        # has to be distributed over.
        set stretched $state
        dict set stretched wordSpacing \
            [expr {[dict get $state wordSpacing] + $extra}]
        # The trailing space is drawn here too, and it picks up the stretched
        # Tw like every other one - so the line reaches past the right margin
        # by that much. Invisibly: it is a space after the last glyph, and the
        # last glyph still sits on the edge. Leaving it out would keep the
        # words of a justified paragraph running together for a reader, which
        # is the defect this is here to fix.
        my TextRun $drawn $stretched $x $y $rotate 0 $lift
      }
      default {
        return -code error "tclpdf: -align must be left, right, center or\
            justify, not \"$align\""
      }
    }
    return
  }

  method TextLineWidth {line state} {
    set arguments {}
    foreach name $::tclpdf::text::stateOptions {
      lappend arguments -$name [dict get $state $name]
    }
    return [my textWidth $line {*}$arguments]
  }

  # The font options out of a parsed option dictionary, as a -name value list
  # that textWidth and textLines can be handed straight through.
  method TextOverrides {options} {
    set arguments {}
    foreach name $::tclpdf::text::stateOptions {
      if {[dict exists $options $name]} {
        lappend arguments -$name [dict get $options $name]
      }
    }
    return $arguments
  }
}

package provide tclpdf::textBlock 1.4
