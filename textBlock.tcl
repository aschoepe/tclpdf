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
# A line breaks at ASCII white space, and after the spaces of Unicode that
# UAX #14 lets a line break at; the no-break spaces are characters of the
# word they stand in - the two classes and the reasons are with them below.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::afm 1.0-
package require tclpdf::option 1.0-
package require tclpdf::text 1.0-

namespace eval ::tclpdf::textBlock {
  # The options of a block, with their defaults - the same list [text] takes,
  # so that ONE option list serves measuring and drawing: a caller builds
  # {-width 170 -align justify -indent 5} once, asks [textHeight] whether the
  # block still fits and then hands the same list to [text]. Refusing -align
  # here would break exactly that. What only the drawing uses - -align,
  # -rotate, -tag, -expansion - is accepted and has no effect on a measurement,
  # and -height is left out of one on purpose: the height of a block is what it
  # would take WITHOUT a limit, that is what a limit is compared against.
  #
  # An option outside this list is an error, not silence. Until now the two
  # measuring methods handed everything but the width on to the font state,
  # which ignores what it does not know: [textHeight $text -width 60 -indent 10]
  # answered the height of an unindented block, and [textLines ... -foo 1]
  # answered at all.
  variable options {at {} rotate 0 align left width {} anchor baseline
      height {} indent 0 indentRight 0 firstIndent 0 paragraphSpacing 0
      avoid {} avoidMargin 0 tag P expansion {}}

  # Where a line may break. Two classes, told apart by what happens to the
  # character when the line breaks there:
  #
  # The SEPARATORS are the ASCII white space characters - controls without a
  # glyph in any face, and the space. A tab or a stray CR of a CRLF file is a
  # break and is drawn as the space that joins two words. \s is NOT this class:
  # Tcl's \s (8.6.18 and 9.0.4, measured) also matches U+00A0, U+2007, U+202F,
  # U+2009, U+3000, even U+200B and U+FEFF - so a breaker built on it broke
  # "12<nbsp>EUR" between the number and its unit, which is the one thing a
  # no-break space is there to prevent (UAX #14: class GL, glue), and put a
  # plain space into the stream where the text had U+00A0.
  #
  # The BREAKABLE spaces are the ones UAX #14 puts in class BA - the Ogham
  # space mark, en quad to hair space, the medium mathematical and the
  # ideographic space - and the zero width space, class ZW. A line MAY end
  # after one of them, and when it does the character goes the way a space
  # goes: it is not set. Inside a line it is a character of the text: it is
  # measured and set with its own glyph width, and refused by a face that has
  # no glyph for it - which for U+200B is most faces (DejaVu Sans, Noto Sans
  # and Roboto carry it, measured; the standard fourteen do not) - and it is
  # NEVER stretched: word spacing reaches only the single-byte code 32 (ISO
  # 32000-1 9.3.3), and the TJ road an embedded face takes adjusts the glyph
  # of U+0020 alone. So a justified line with a thin space in it grows at its
  # word spaces and keeps the thin space thin.
  #
  # Every other white space of Unicode is a character of the word it stands
  # in - the no-break spaces U+00A0, U+2007 and U+202F (class GL) by design,
  # and the line and paragraph separators U+2028, U+2029 and U+0085 because
  # nothing here has decided what they mean; a face without the glyph refuses
  # them, as it always did.
  #
  # A word carries its breakable spaces at either end: those after it are
  # where the line may end, and are stripped when it does; one in front of a
  # word - after a plain space, or opening a paragraph as an em space indent -
  # belongs to the word and is set. Whether two words are joined by a space
  # or by nothing is read off their positions in the paragraph, not off the
  # characters, because a word ending in a thin space may or may not have a
  # plain space after it as well.
  variable separators "\t\n\v\f\r "
  variable breakable "\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2008\u2009\u200A\u200B\u205F\u3000"
  variable word "\[$breakable\]*\[^$separators$breakable\]+\[$breakable\]*|\[$breakable\]+"
}

oo::define ::tclpdf::document::document {

  # Break a string into lines that fit a width, in the document unit.
  # Explicit newlines are honoured and start a new paragraph.
  method textLines {string args} {
    my TextInit
    set options [my TextBlockOptions $args textLines]
    lassign [my TextBlockLines $string $options] lines
    return [lmap line $lines {dict get $line text}]
  }

  # The height a block would occupy, without drawing it - for deciding whether
  # it still fits on the page.
  #
  # Exactly what [text] advances by: the difference between the y it returns
  # and the y it was given, with the same options. Counting lines and
  # multiplying by the leading was that only for the plainest block - it left
  # out the paragraph spacing, the ascender of -anchor top and the lines a
  # shape pushes down, so a caller who placed the next element by it landed
  # on the block.
  method textHeight {string args} {
    my TextInit
    set options [my TextBlockOptions $args textHeight]
    lassign [my TextBlockLines $string $options] lines state leading lift
    lassign [my TextBlockPlace $lines $leading \
        [dict get $options paragraphSpacing] {}] drawn rest below
    return [expr {$lift + $below}]
  }

  # The options of a measuring call, read the way [text] reads its own.
  #
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
  method TextBlockOptions {arguments context} {
    if {[llength $arguments] && [string index [lindex $arguments 0] 0] ne "-"} {
      set arguments [list -width {*}$arguments]
    }
    set defaults $::tclpdf::textBlock::options
    foreach name $::tclpdf::text::stateOptions {
      dict set defaults $name [my TextGet $name]
    }
    set defaults [dict merge $defaults $::tclpdf::text::runOptions]
    set options [::tclpdf::option parse $defaults $arguments $context]
    if {[dict get $options width] eq {}} {
      return -code error "tclpdf: a text block needs -width"
    }
    # A measurement has no limit: see the note on the option list above.
    dict set options height {}
    return $options
  }

  # The line breaker itself. Everything wrapped in this package comes through
  # here, and it is the ONE place that decides where a line ends.
  #
  # band is a command prefix called with three numbers: the index of the line
  # inside its paragraph (0 for the first), the index of the paragraph, and the
  # running line number over the whole block. It answers {width offset
  # ?skipped?}: how wide this line may be, how far in from the left edge it
  # starts, and how many lines above it the band left EMPTY - a line that a
  # shape covers completely is not set at all, and the text goes on below the
  # shape; without the third element nothing is skipped. The running number is
  # what lets a band know its vertical position - which is everything, once
  # the text has to flow around a shape. A constant band is what [textLines]
  # asks for; an indent narrows the first line of each paragraph; flowing
  # around a shape varies every line. Keeping that decision outside the loop
  # is what lets all three share one breaker instead of growing a second copy.
  #
  # Returns one dictionary per line: text, offset, width, paragraph, first -
  # whether it opens its paragraph -, running - which line of the block it is,
  # skipped ones counted -, and from: where in the STRING the text of this line
  # begins. That last one is what makes the rest of a height-limited block a
  # plain tail of the original: the line before the cut says where it stops,
  # and nothing has to be put back together from lines - which turned a soft
  # hyphen into a hard one and a word broken by character into several words.
  method TextBlockBreak {string arguments band} {
    set lines {}
    set paragraphIndex 0
    set globalLine 0
    set paragraphFrom 0
    foreach paragraph [split $string \n] {
      if {[string trim $paragraph $::tclpdf::textBlock::separators] eq {}} {
        # Not skipped by a shape: there is nothing to keep out of it, and
        # moving it down would add its own blank line below the shape.
        lassign [{*}$band 0 $paragraphIndex $globalLine] width offset
        lappend lines [dict create text {} offset $offset width $width hyphen 0 \
            paragraph $paragraphIndex first 1 running $globalLine \
            from $paragraphFrom]
        incr paragraphIndex
        incr globalLine
        incr paragraphFrom [expr {[string length $paragraph] + 1}]
        continue
      }
      set inParagraph 0
      lassign [my TextBlockAsk $band $inParagraph $paragraphIndex $globalLine] \
          width offset running
      set current {}
      set currentFrom 0
      set previousTo -2
      foreach span [regexp -all -inline -indices $::tclpdf::textBlock::word $paragraph] {
        lassign $span wordFrom wordTo
        set word [string range $paragraph $wordFrom $wordTo]
        # What stands between this word and the one before it: nothing, when
        # the two touch - the one before ends in a breakable space -, or the
        # plain space that every separator is to the page (see the classes at
        # the top). A no-break space never gets here as a separator: it stays
        # inside its word and reaches the stream as U+00A0.
        set glue [expr {$wordFrom == $previousTo + 1 ? {} : { }}]
        set previousTo $wordTo
        incr wordFrom $paragraphFrom
        # NOT [expr {$current eq {} ? $word : "..."}]: expr normalises a word
        # that looks like a number, and "1234.50" comes back as "1234.5". The
        # trailing zero is gone from every amount in every wrapped paragraph,
        # and nothing reports it - the document is perfectly valid and the
        # figure is wrong.
        if {$current eq {}} {
          set candidate $word
          set candidateFrom $wordFrom
        } else {
          set candidate "$current$glue$word"
          set candidateFrom $currentFrom
        }
        if {[my TextBlockFits $candidate $width $arguments]} {
          set current $candidate
          set currentFrom $candidateFrom
          continue
        }
        # The word does not fit. Two things can end the line now: an offer
        # inside the word - a soft hyphen the line still has room for, hyphen
        # included - or the line simply closing on what it already holds.
        #
        # Both live in one loop, because they alternate: an offer that is too
        # far in next to a half-full line often fits once that line is closed,
        # and a remainder can carry further offers. Closing the line and trying
        # again is therefore not a special case, it is the next round.
        while {1} {
          set taken [my TextBlockHyphen $current $glue $word $width $arguments]
          if {[llength $taken]} {
            set from [expr {$current ne {} ? $currentFrom : $wordFrom}]
            lassign $taken emit remainder
            # The head consumed this much of the word - measured on the word
            # itself rather than on the head, which carries the prefix and the
            # hyphen and has lost the marks it broke at.
            incr wordFrom [expr {[string length $word] - [string length $remainder]}]
            set word $remainder
          } elseif {$current ne {}} {
            set emit $current
            set from $currentFrom
          } else {
            break
          }
          # hyphen 1 says the trailing "-" of this line is a BREAK, not a
          # character of the text. It travels to the drawing so that the
          # hyphen can be bracketed as such - extracted text has to come back
          # without it (14.8.2.6).
          lappend lines [dict create text [my TextBlockClose $emit] offset $offset \
              width $width paragraph $paragraphIndex \
              hyphen [expr {[llength $taken] ? 1 : 0}] \
              first [expr {$inParagraph == 0}] running $running from $from]
          incr inParagraph
          set globalLine [expr {$running + 1}]
          lassign [my TextBlockAsk $band $inParagraph $paragraphIndex $globalLine] \
              width offset running
          set current {}
          if {[llength $taken] && [my TextBlockFits $word $width $arguments]} {
            break
          }
        }
        # No offer was small enough for this width. The remaining marks come
        # out before the character fallback below: they are invisible when
        # drawn, and leaving them in would make it count characters that never
        # reach the page. The word with its marks is kept beside the stripped
        # one, because the position in the string has to advance over the
        # marks as well.
        set marked $word
        if {[string first "\u00AD" $word] >= 0
            && ![my TextBlockFits $word $width $arguments]} {
          set word [string map [list "\u00AD" {}] $word]
        }
        # The word alone may still be too wide - a part number, a URL, a
        # column two millimetres across. Break it by character rather than
        # letting it run past the edge unnoticed.
        while {![my TextBlockFits $word $width $arguments] && [string length $word] > 1} {
          set take [string length $word]
          while {$take > 1 && [my textWidth [string range $word 0 $take-1] {*}$arguments] > $width} {
            incr take -1
          }
          lappend lines [dict create text [string range $word 0 $take-1] \
              offset $offset width $width paragraph $paragraphIndex hyphen 0 \
              first [expr {$inParagraph == 0}] running $running from $wordFrom]
          incr inParagraph
          set globalLine [expr {$running + 1}]
          lassign [my TextBlockAsk $band $inParagraph $paragraphIndex $globalLine] \
              width offset running
          set consumed [my TextBlockConsumed $marked $take]
          incr wordFrom $consumed
          set marked [string range $marked $consumed end]
          set word [string range $word $take end]
        }
        set current $word
        set currentFrom $wordFrom
      }
      if {$current ne {}} {
        lappend lines [dict create text [my TextBlockClose $current] offset $offset width $width hyphen 0 \
            paragraph $paragraphIndex first [expr {$inParagraph == 0}] \
            running $running from $currentFrom]
        set globalLine [expr {$running + 1}]
      }
      incr paragraphIndex
      incr paragraphFrom [expr {[string length $paragraph] + 1}]
    }
    return $lines
  }

  # A line as it is closed: without the breakable spaces a word carries at
  # its end - the line ends there the way it ends at a plain space, and the
  # character is not set - and without a plain space left in front of them,
  # "aaa <thin>" closes as "aaa". What is stripped is only what stands at the
  # END: the same character inside the line stays, glyph width and all.
  method TextBlockClose {text} {
    return [string trimright $text \
        $::tclpdf::textBlock::breakable$::tclpdf::textBlock::separators]
  }

  # Whether a line fits a width, measured as the line would be closed - a
  # thin space the line ends on takes no room, as a plain space there takes
  # none. Measured with it, "aaa<thin>" fell to the character fallback in a
  # column that holds "aaa", and the thin space opened the next line.
  method TextBlockFits {text width arguments} {
    return [expr {[my textWidth [my TextBlockClose $text] {*}$arguments] <= $width}]
  }

  # Ask the band about a line. Answers {width offset running}: running is the
  # line the band found room on - the one asked about, or a later one when the
  # band skipped some.
  method TextBlockAsk {band line paragraph running} {
    lassign [{*}$band $line $paragraph $running] width offset skipped
    if {$skipped eq {}} {
      set skipped 0
    }
    return [list $width $offset [expr {$running + $skipped}]]
  }

  # How many characters of a word WITH its soft hyphens the first n
  # characters of the same word without them stand for.
  method TextBlockConsumed {marked count} {
    set consumed 0
    set seen 0
    while {$seen < $count && $consumed < [string length $marked]} {
      if {[string index $marked $consumed] ne "\u00AD"} {
        incr seen
      }
      incr consumed
    }
    return $consumed
  }

  # The longest beginning of a word that still fits WITH a hyphen after it, and
  # what is left over. Empty when no offer in the word is small enough.
  #
  # U+00AD is an offer, not a character: "you may break here". tclpdf does not
  # hyphenate by itself - that needs language data and is a feature of its own -
  # but text arriving from elsewhere often carries the marks already, and until
  # now they were either set as a visible hyphen or refused outright.
  #
  # The hyphen that appears at the break is a real one (U+002D), so the line
  # ends the way a reader expects. What that costs is named in the manual:
  # extracting such a line yields the hyphen too.
  method TextBlockHyphen {prefix glue word width arguments} {
    set parts [split $word "\u00AD"]
    if {[llength $parts] < 2} {
      return {}
    }
    # From the last offer backwards - the line is to be filled, not emptied.
    for {set take [expr {[llength $parts] - 1}]} {$take >= 1} {incr take -1} {
      set head [join [lrange $parts 0 [expr {$take - 1}]] {}]-
      if {$prefix ne {}} {
        # NOT [expr]: it normalises a word that looks like a number, and
        # "1234.50" would come back as "1234.5" - see the breaker above. The
        # glue is the breaker's: a plain space, or nothing after a word that
        # ends in a breakable space.
        set head "$prefix$glue$head"
      }
      if {[my textWidth $head {*}$arguments] <= $width} {
        return [list $head [join [lrange $parts $take end] "\u00AD"]]
      }
    }
    return {}
  }

  # The lines of a block, from a parsed option dictionary: the band built from
  # the indents and the shapes, the string broken against it. Shared by the
  # drawing and the two measuring methods, so that all three break the same
  # text the same way - a height measured over different lines than the ones
  # drawn is worth nothing.
  #
  # Returns {lines state leading lift}: the font state the block is set in,
  # its leading in the document unit, and how far below -at its first
  # baseline sits.
  method TextBlockLines {string options} {
    set width [dict get $options width]
    if {![string is double -strict $width] || $width <= 0} {
      return -code error "tclpdf: -width must be a positive number, not\
          \"$width\""
    }
    set state [my TextMerge [my TextOverrides $options]]
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
      # The shapes are page positions, so the block needs one too - [text]
      # always has it, a measuring call may have forgotten it.
      set at [::tclpdf::option point [dict get $options at] -at "a block with -avoid"]
      lassign $at x y
      # "my", not the object name: the band is expanded inside a method of
      # this object, and TextAvoidBand is private - reaching it from outside
      # would need an export that nothing else wants.
      #
      # It wraps the indent band rather than replacing it: the shapes narrow
      # whatever the indents leave, and the offset it answers is measured
      # from x like the indent band's, so a paragraph with -indent 10 starts
      # its lines at 30 with a shape on the page as it does without one.
      # Replacing the band lost that - every line of an indented paragraph
      # started at x as soon as -avoid was given, whether or not any shape
      # came near it. And the top it works from is the first BASELINE, y plus
      # the lift, the same reference the drawing uses: handed the anchor, it
      # took a block set with -anchor top to sit one ascender higher than it
      # did, and the first line ran through the shape at full width.
      set band [list my TextAvoidBand [dict get $options avoid] \
          [dict get $options avoidMargin] $x [expr {$y + $lift}] $leading \
          [dict get $options paragraphSpacing] \
          [my TextBlockWidest $string [my TextOverrides $options]] $band]
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
    return [list $lines $state $leading $lift]
  }

  # The widest single character of a string - the least a line has to offer
  # for the character fallback of the breaker to set anything WITHIN it. A
  # band narrower than that beside a shape would take one character anyway
  # and let it run into the shape; the avoiding band leaves such a line
  # empty instead. Measured once per block, over the distinct characters.
  method TextBlockWidest {string arguments} {
    set widest 0
    foreach char [lsort -unique [split \
        [regsub -all "\[$::tclpdf::textBlock::separators\]" $string {}] {}]] {
      set width [my textWidth $char {*}$arguments]
      if {$width > $widest} {
        set widest $width
      }
    }
    return $widest
  }

  # Where each line sits and which lines a height limit holds back.
  #
  # Returns {drawn rest below}: drawn is a list of {line top} pairs - top the
  # distance of the line's baseline below the first one -, rest the lines
  # held back, below the distance of the baseline one line under the last
  # drawn one.
  #
  # The paragraph spacing is added between two DRAWN paragraphs and nowhere
  # else. It used to be counted whenever the paragraph changed, drawn or not,
  # so with a limit the y handed back moved down by one spacing per held-back
  # paragraph: a caller continuing under the block left a gap for text that
  # was set in the next column instead.
  method TextBlockPlace {lines leading spacing limit} {
    set drawn {}
    set rest {}
    set spacings 0
    set below 0
    set previous {}
    foreach line $lines {
      set paragraph [dict get $line paragraph]
      set advance [expr {$previous ne {} && $paragraph != $previous ? $spacing : 0}]
      set top [expr {[dict get $line running] * $leading + $spacings + $advance}]
      # Once one line has been held back, everything after it goes with it -
      # otherwise a short line would jump ahead of a long one.
      if {[llength $rest] || ($limit ne {} && $top + $leading > $limit)} {
        lappend rest $line
        continue
      }
      set spacings [expr {$spacings + $advance}]
      lappend drawn [list $line $top]
      set below [expr {$top + $leading}]
      set previous $paragraph
    }
    return [list $drawn $rest $below]
  }

  # Called by [text] when -width is given. Returns the y coordinate BELOW the
  # block, so the next element can be placed without counting lines.
  method TextParagraph {string options} {
    lassign [my TextBlockLines $string $options] lines state leading lift
    # Mirrored once, here, for every line of the block - see TextAlign in
    # text.tcl for what "left" means in a right-to-left line.
    set align [my TextAlign [dict get $options align] $state]
    lassign [dict get $options at] x y

    # A height limit turns the block into the first of several: what fits is
    # drawn, what does not is handed back. The caller decides where the rest
    # goes - the next column, the next page - which is why this method does
    # not try to know.
    set limit [dict get $options height]
    lassign [my TextBlockPlace $lines $leading \
        [dict get $options paragraphSpacing] $limit] drawn rest below

    foreach entry $drawn {
      lassign $entry line top
      if {[dict get $line text] ne {}} {
        my TextParagraphLine [dict get $line text] $state \
            [expr {$x + [dict get $line offset]}] $y [dict get $line width] \
            $align [dict get $line closes] [dict get $options rotate] \
            [expr {$lift + $top}] [dict get $line hyphen]
      }
    }
    if {$limit ne {}} {
      # Text, not lines: the rest may have to be broken again for a column of
      # a different width, and handing back lines would silently fix the old
      # break points. And the TAIL OF THE STRING, not lines joined back
      # together: the first line held back knows where in the string it
      # begins, and everything from there on is the rest - soft hyphens still
      # soft, a word the fallback broke by character still one word, the
      # paragraph breaks where they were.
      set text {}
      if {[llength $rest]} {
        set text [string range $string [dict get [lindex $rest 0] from] end]
      }
      return [dict create y [expr {$y + $lift + $below}] rest $text]
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
    return [expr {$y + $lift + $below}]
  }

  # Alignment inside the column is a shift along the baseline and is passed
  # to TextRun rather than applied to x - with -rotate the baseline is
  # turned, and a pre-shifted x would rotate about the wrong point (same
  # reasoning as in [text], text.tcl).
  method TextParagraphLine {line state x y width align isLast rotate {lift 0} {hyphen 0}} {
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
        my TextRun $drawn $state $x $y $rotate 0 $lift $hyphen
      }
      right {
        my TextRun $drawn $state [expr {$x + $width}] $y $rotate \
            [my TextLineWidth $line $state] $lift $hyphen
      }
      center - centre {
        my TextRun $drawn $state [expr {$x + $width / 2.0}] $y $rotate \
            [expr {[my TextLineWidth $line $state] / 2.0}] $lift $hyphen
      }
      justify {
        # The last line of a paragraph stays flush left. Justifying it is the
        # classic mistake - one word on a line gets stretched across the whole
        # column and the result is unmistakably broken.
        #
        # Counted as the SPACES of the line, U+0020 and nothing else, because
        # that is what Tw stretches (9.3.3) and what the TJ road adjusts: a
        # no-break space stands inside a word and gets none of the gap. Counting
        # words instead handed the gap out over the no-break spaces as well,
        # and the line stopped short of the margin by exactly their share.
        set spaces [regexp -all { } $line]
        if {$isLast || $spaces < 1} {
          my TextRun $drawn $state $x $y $rotate 0 $lift $hyphen
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
        my TextRun $drawn $stretched $x $y $rotate 0 $lift $hyphen
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
    foreach name $::tclpdf::text::lineOptions {
      lappend arguments -$name [dict get $state $name]
    }
    return [my textWidth $line {*}$arguments]
  }

  # The font options out of a parsed option dictionary, as a -name value list
  # that textWidth and textLines can be handed straight through. The direction
  # travels with them: the line breaker measures through [textWidth], and a
  # right-to-left script it was not told about is refused there rather than
  # broken.
  method TextOverrides {options} {
    set arguments {}
    foreach name $::tclpdf::text::lineOptions {
      if {[dict exists $options $name]} {
        lappend arguments -$name [dict get $options $name]
      }
    }
    return $arguments
  }
}

package provide tclpdf::textBlock 1.5
