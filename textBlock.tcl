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
    set lines {}
    foreach paragraph [split $string \n] {
      if {[string trim $paragraph] eq {}} {
        lappend lines {}
        continue
      }
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
        if {[my textWidth $candidate {*}$args] <= $width} {
          set current $candidate
          continue
        }
        if {$current ne {}} {
          lappend lines $current
          set current {}
        }
        # The word alone may still be too wide - a part number, a URL, a
        # column two millimetres across. Break it by character rather than
        # letting it run past the edge unnoticed.
        while {[my textWidth $word {*}$args] > $width && [string length $word] > 1} {
          set take [string length $word]
          while {$take > 1 && [my textWidth [string range $word 0 $take-1] {*}$args] > $width} {
            incr take -1
          }
          lappend lines [string range $word 0 $take-1]
          set word [string range $word $take end]
        }
        set current $word
      }
      if {$current ne {}} {
        lappend lines $current
      }
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
    set y [my TextBaseline $state $y [dict get $options anchor]]

    set lines [my textLines $string $width {*}[my TextOverrides $options]]
    set last [expr {[llength $lines] - 1}]
    set index 0
    foreach line $lines {
      if {$line ne {}} {
        my TextParagraphLine $line $state $x $y $width $align \
            [expr {$index == $last}] [dict get $options rotate]
      }
      set y [expr {$y + $leading}]
      incr index
    }
    return $y
  }

  # Alignment inside the column is a shift along the baseline and is passed
  # to TextRun rather than applied to x - with -rotate the baseline is
  # turned, and a pre-shifted x would rotate about the wrong point (same
  # reasoning as in [text], text.tcl).
  method TextParagraphLine {line state x y width align isLast rotate} {
    switch -- $align {
      left {
        my TextRun $line $state $x $y $rotate
      }
      right {
        my TextRun $line $state [expr {$x + $width}] $y $rotate \
            [my TextLineWidth $line $state]
      }
      center - centre {
        my TextRun $line $state [expr {$x + $width / 2.0}] $y $rotate \
            [expr {[my TextLineWidth $line $state] / 2.0}]
      }
      justify {
        # The last line of a paragraph stays flush left. Justifying it is the
        # classic mistake - one word on a line gets stretched across the whole
        # column and the result is unmistakably broken.
        set spaces [expr {[llength [regexp -all -inline {\S+} $line]] - 1}]
        if {$isLast || $spaces < 1} {
          my TextRun $line $state $x $y $rotate
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
        my TextRun $line $stretched $x $y $rotate
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

package provide tclpdf::textBlock 1.1
