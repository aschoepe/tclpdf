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
# Hyphenation is OFF unless asked for, and it is asked for per block with
# -hyphenate. Two things can offer a break inside a word: the soft hyphens the
# text already carries, and the patterns of tclpdf::hyphenate - and where a
# word carries marks of its own, those win outright (TextBlockHyphen). Without
# either, a word longer than the column is broken by character rather than
# pushed over the edge, and that break is a fallback, not typography.
#
# The hyphen such a break puts at the end of a line is not a character of the
# text, and a caller who draws the lines himself has to say so. Which lines
# carry one is asked for with [textLines -hyphens 1] here, and said with
# [text -breakHyphen] in text.tcl - two halves of one thing.
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
  # -hyphens is the one entry that runs the other way: it belongs to the
  # MEASURING calls and [text] does not take it, because it says what the
  # answer of [textLines] looks like and a drawing has no answer of that
  # shape. It costs the shared list nothing - a caller who asks for the
  # hyphens draws his lines one at a time with [text -breakHyphen], which is
  # a line call and never sees a block option list.
  #
  # An option outside this list is an error, not silence. Until now the two
  # measuring methods handed everything but the width on to the font state,
  # which ignores what it does not know: [textHeight $text -width 60 -indent 10]
  # answered the height of an unindented block, and [textLines ... -foo 1]
  # answered at all.
  variable options {at {} rotate 0 align left width {} anchor baseline
      height {} paginate 0 columns 1 gutter {} balance 0
      indent 0 indentRight 0 firstIndent 0 paragraphSpacing 0
      avoid {} avoidMargin 0 tag P expansion {} hyphenate 0 breakHyphen 0
      hyphens 0 emergencyHyphen 0}

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
  #
  # Answers a list of STRINGS, which is the shape four releases of callers
  # read and which stays whatever else is added here: counting lines,
  # measuring a column, filling a listbox all want nothing else.
  #
  # With -hyphens 1 every element is a DICTIONARY instead - {text ... hyphen
  # ...}: the line, and whether the "-" it ends on is a break this breaker put
  # there or a character of the text. A string cannot carry that difference,
  # and neither can the caller work it out afterwards - "E-Mail" ends a line
  # in a "-" that is a character, and only the breaker knows which of the two
  # it made. Whoever draws these lines himself needs it, because a break
  # hyphen is not a character of the text (ISO 32000-1, 14.8.2.6) and has to
  # be bracketed as such, and [text -breakHyphen] is the other half of exactly
  # this. The whole circle is four lines:
  #
  #   foreach line [$doc textLines $body -width 60 -hyphens 1] {
  #     $doc text [dict get $line text] -at [list $x $y] \
  #         -breakHyphen [dict get $line hyphen]
  #     set y [expr {$y + 5}]
  #   }
  #
  # A DICTIONARY rather than the pair {text hyphen} the package passes around
  # internally, for two reasons. It says what it holds where it is read -
  # [dict get $line hyphen] against [lindex $line 1] - and it is the shape
  # that can gain a key without a caller noticing, while a longer pair silently
  # changes what [lassign] and [foreach {a b}] see. The pair stays internal
  # (TextLinesBroken) precisely because it is not promised anything.
  method textLines {string args} {
    my TextInit
    set options [my TextBlockOptions $args textLines]
    set lines [my TextBlockBroken $string $options]
    if {![dict get $options hyphens]} {
      return [lmap line $lines {lindex $line 0}]
    }
    return [lmap line $lines {
      dict create text [lindex $line 0] hyphen [lindex $line 1]
    }]
  }

  # The lines of [textLines] as pairs {text hyphen} - the shape the package
  # uses among itself, from the arguments [textLines] takes.
  #
  # The table is the caller: it breaks here and draws in tableDraw.tcl, one
  # [text] per line, and without the flag the hyphen went out as an ordinary
  # character, so a tagged table extracted as "Betriebskostenab-rechnung".
  #
  # Internal because the pair shape is not a public promise. What a caller
  # outside the package asks for is [textLines -hyphens 1], and that one
  # answers dictionaries.
  method TextLinesBroken {string args} {
    my TextInit
    return [my TextBlockBroken $string [my TextBlockOptions $args textLines]]
  }

  # The ONE road from a parsed option list to broken lines with their flag -
  # both methods above sit on it, so the public shape and the internal one
  # cannot come to disagree about where a line ends.
  method TextBlockBroken {string options} {
    # No lift where nothing needs it: breaking a text into lines does not
    # place them, so the one question a vertical block cannot answer is not
    # asked - which is what lets [textLines -direction ttb] break a vertical
    # text into columns.
    #
    # -avoid is the exception, and it is not academic: the band a shape leaves
    # free is measured from the FIRST BASELINE, so the lift is part of the
    # breaking there rather than only of the placing. Measured when this was
    # first written without the exception: "-avoid ... -anchor top" quietly
    # broke as if the anchor were the baseline, and textFlow-8.3 caught it.
    set needsLift [expr {[dict get $options avoid] ne {}}]
    lassign [my TextBlockLines $string $options $needsLift] lines
    return [lmap line $lines {
      list [dict get $line text] [dict get $line hyphen]
    }]
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
    my TextBlockWidth [dict get $options width]
    my TextBlockDistances $options
    # Checked in BOTH measuring calls although only [textLines] reads it: a
    # caller builds one option list, asks [textHeight] whether the block still
    # fits and then asks [textLines] for the lines - and a mistyped value has
    # to be refused at the first of the two, not at the second. What the
    # option does there is nothing, which is a different thing from being
    # allowed to be nonsense.
    if {![string is boolean -strict [dict get $options hyphens]]} {
      return -code error -errorcode [list TCLPDF TEXT HYPHENS \
          [dict get $options hyphens] $context] \
          "tclpdf: -hyphens takes a boolean, not\
          \"[dict get $options hyphens]\""
    }
    # A measurement has no limit: see the note on the option list above.
    dict set options height {}
    return $options
  }

  # Everything a drawn paragraph refuses, checked in ONE place and BEFORE
  # anything is written: [text] calls this in front of the structure mark,
  # so that a refused option leaves the stream, the tree and the state as
  # they were - the checks used to sit at the head of TextParagraph, one
  # step behind the BDC. Answers the options with the gutter default filled
  # in, which is what TextParagraph and TextPaginate work from; neither of
  # them checks again.
  #
  # The measuring calls do not come through here on purpose: they take the
  # options [text] takes and ignore what only the drawing uses, so a caller
  # can hand the same list to [textHeight] and to [text] - refusing "-columns
  # without -height max" of a measurement would break exactly that. What
  # they share with the drawing - the width, the distances - is checked by
  # the two methods below, from both roads.
  method TextBlockCheck {options} {
    my TextBlockWidth [dict get $options width]
    # The words TextParagraphLine switches on; refused there as well, in the
    # same words, for a caller that reaches it directly - but a paragraph of
    # [text] has to be refused before its mark.
    if {[dict get $options align] ni {left right center centre justify}} {
      return -code error "tclpdf: -align must be left, right, center or\
          justify, not \"[dict get $options align]\""
    }
    set height [dict get $options height]
    if {$height ne {} && $height ne "max"
        && (![string is double -strict $height] || $height < 0)} {
      return -code error "tclpdf: -height takes a distance of 0 or more, or\
          \"max\" for the rest of the type area, not \"$height\""
    }
    set paginate [dict get $options paginate]
    if {![string is boolean -strict $paginate]} {
      return -code error "tclpdf: -paginate takes a boolean, not \"$paginate\""
    }
    if {$paginate && $height ne {} && $height ne "max"} {
      # It used to be replaced by max in silence, so "-paginate 1 -height 20"
      # filled the page and the caller was not told that the 20 meant
      # nothing.
      return -code error "tclpdf: -paginate fills each page to the bottom of\
          the type area, which is -height max - a height of $height has no\
          place beside it; leave -height out or say -height max"
    }
    if {[dict get $options rotate] != 0 && ($height eq "max" || $paginate)} {
      # The type area is a band down the page; a turned block does not run
      # down the page, so there is nothing to measure it against.
      return -code error "tclpdf: -height max and -paginate set an upright\
          block against the type area - they cannot be combined with -rotate"
    }
    # Columns: a count, a gutter between them, and whether the last page
    # is balanced. Only meaningful where the bottom of the column is the
    # type area - -height max or -paginate -, because that is what fills a
    # column before the next one begins.
    set columns [dict get $options columns]
    if {![string is integer -strict $columns] || $columns < 1} {
      return -code error "tclpdf: -columns takes a whole number of 1 or more,\
          not \"$columns\""
    }
    set gutter [dict get $options gutter]
    if {$gutter eq {}} {
      # Five millimetres in whatever the document counts in.
      set gutter [::tclpdf::geometry fromPoints \
          [::tclpdf::geometry toPoints 5 mm] [my cget -unit]]
      dict set options gutter $gutter
    } elseif {![string is double -strict $gutter] || $gutter < 0} {
      return -code error "tclpdf: -gutter takes a distance of 0 or more, not\
          \"$gutter\""
    }
    set balance [dict get $options balance]
    if {![string is boolean -strict $balance]} {
      return -code error "tclpdf: -balance takes a boolean, not \"$balance\""
    }
    if {$columns > 1 && $height ne "max" && !$paginate} {
      return -code error "tclpdf: -columns fills one column to the bottom of\
          the type area before it begins the next - it needs -height max or\
          -paginate"
    }
    if {$balance && $columns == 1} {
      return -code error "tclpdf: -balance evens out the columns of the last\
          page - it needs -columns of 2 or more"
    }
    if {$balance && [llength [dict get $options avoid]]} {
      # The balance is found by measuring the columns without drawing them,
      # and the shapes are positions on the page that would make each
      # column break differently - the measurement would lie.
      return -code error "tclpdf: -balance measures the columns without the\
          page - it cannot be combined with -avoid"
    }
    set width [dict get $options width]
    if {($width - $gutter * ($columns - 1)) / double($columns) <= 0} {
      return -code error "tclpdf: $columns columns with a gutter of\
          [format %g $gutter] leave no width inside -width [format %g $width]"
    }
    my TextBlockDistances $options
    if {[llength [dict get $options avoid]]} {
      # Loaded only when asked for: a caller who never avoids anything does
      # not pay for the module.
      package require tclpdf::textAvoid
      my TextAvoidCheck [dict get $options avoid] [dict get $options avoidMargin]
    }
    # Asked here as well as in TextBlockLines, and for the reason the whole
    # method exists: a language nobody loaded has to be refused BEFORE the
    # mark of a tagged paragraph is written, not from inside the breaker.
    my TextBlockHyphenate $options
    return $options
  }

  # Which language this block is hyphenated in - empty for a block that is
  # not, which is every block that does not say otherwise.
  #
  #   -hyphenate 0     off; the default, and what every existing document was
  #                    set with, so nothing about its bytes changes
  #   -hyphenate 1     on, in the language the document declares ([language])
  #   -hyphenate de-AT on, in that language whatever the document declares
  #
  # ONLY the two literal values 0 and 1 are the switch; anything else is a
  # language tag. Reading the value with [string is boolean] would have been
  # the house habit and is wrong exactly once: "no" is a Tcl false AND the
  # RFC 3066 tag for Norwegian, so -hyphenate no would have silently turned
  # hyphenation off for the one language whose name says otherwise.
  #
  # The refusal is the point of the whole option. A caller who says
  # -hyphenate de-DE on a machine where no German patterns were loaded gets
  # TCLPDF HYPHENATE LANGUAGE and can decide - fall back, load, or let it
  # through - because the alternative is a document that is quietly set
  # unhyphenated and looks like the one that was asked for.
  method TextBlockHyphenate {options} {
    if {![dict exists $options hyphenate]} {
      # A DRAWN paragraph arrives with the option list [text] built, and that
      # is text.tcl's own copy of the list above rather than the list itself.
      # A key this dictionary does not carry cannot have been given a value
      # either - [option parse] would have refused the option - so the answer
      # is the one -hyphenate 0 gives.
      return {}
    }
    set value [dict get $options hyphenate]
    if {$value eq {} || $value eq "0"} {
      return {}
    }
    if {$value eq "1"} {
      set value [my language]
      if {$value eq {}} {
        return -code error -errorcode {TCLPDF HYPHENATE UNSET} \
            "tclpdf: -hyphenate 1 breaks words in the language the document\
            declares, and this one declares none - say \[\$doc language\
            de-DE\] first, or name the language on the block itself\
            (-hyphenate de-DE)"
      }
    }
    # Loaded only when asked for, the way -avoid loads textAvoid: a caller
    # who never hyphenates does not pay for the module, and the two are
    # topics of their own - neither requires the other.
    package require tclpdf::hyphenate
    # Answers what is loaded for the tag, or throws TCLPDF HYPHENATE LANGUAGE.
    ::tclpdf::hyphenate languages $value
    return $value
  }

  # The width of a block: a positive number, or the refusal in the words
  # both roads use.
  method TextBlockWidth {width} {
    if {![string is double -strict $width] || $width <= 0} {
      return -code error "tclpdf: -width must be a positive number, not\
          \"$width\""
    }
    return $width
  }

  # The distances that shape the band - the three indents and the paragraph
  # spacing. Numbers, any sign: a negative -firstIndent is a hanging indent
  # by design. Refused here rather than left to the band, which met a value
  # like "bogus" in an [expr] and reported it in Tcl's words from inside the
  # line breaker - after the mark of a tagged paragraph had been written.
  method TextBlockDistances {options} {
    foreach name {indent indentRight firstIndent paragraphSpacing} {
      set value [dict get $options $name]
      if {![string is double -strict $value]} {
        return -code error "tclpdf: -$name takes a distance in the document\
            unit, not \"$value\""
      }
    }
    return
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
  method TextBlockBreak {string arguments band {language {}} {emergency 0}} {
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
        if {[my TextBlockFits $candidate $width $arguments \
            $string $candidateFrom]} {
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
          # Where what is measured next begins in the string: the line so far
          # when there is one, the word otherwise. The offer road measures a
          # head built from both, so it needs the same place.
          set chunkFrom [expr {$current ne {} ? $currentFrom : $wordFrom}]
          set taken [my TextBlockHyphen $current $glue $word $width $arguments \
              $string $chunkFrom $language]
          # AN OFFER THAT CONSUMES NOTHING IS NOT AN OFFER, and this loop is
          # where that has to be said: it closes a line on the head it took
          # and comes back with what is left of the word, so a head that
          # leaves the word as it was turns "while 1" into a machine that
          # writes a page of hyphens and never returns. It is not a
          # hypothetical - a pattern file stating LEFTHYPHENMIN 0 offered a
          # break in front of the first letter, and [hyphenate word] answered
          # {{} ababab}. That file is refused at the load now (hyphenate.tcl),
          # and this is the second brake: the offer may come from the
          # caller's own -exceptions just as well ("-Ur-in-stinkt"), and no
          # reading of a pattern file can be trusted to make a line breaker
          # terminate.
          if {[llength $taken]
              && [string length [lindex $taken 1]] >= [string length $word]} {
            set taken {}
          }
          if {[llength $taken]} {
            set from $chunkFrom
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
          # The line is closed. Whatever is left of the word goes back to the
          # breaker as soon as it fits ON THE FRESH LINE - and the check is
          # made whether or not this round took an offer.
          #
          # It used to be made only after a break was taken, and the case it
          # missed is the common one: a line that is nearly full, then a long
          # word that fits nowhere in the rest of it. The line was closed on
          # what it held - right - and the loop then went round again and
          # hyphenated the word although the fresh line had room for all of
          # it. Measured on "Die Silbentrennung ist eine Verbesserung fuer
          # jede schmale Spalte" at 45 mm: the second line came out as
          # "Verbesse-" and nothing else, 16 mm in a 45 mm column, with the
          # rest of the sentence below it. That is not a break, it is an
          # orphan, and it was there before automatic hyphenation existed -
          # it just took a paragraph with soft hyphens in it to see.
          if {[my TextBlockFits $word $width $arguments $string $wordFrom]} {
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
            && ![my TextBlockFits $word $width $arguments \
                $string $wordFrom]} {
          set word [string map [list "\u00AD" {}] $word]
        }
        # The word alone may still be too wide - a part number, a URL, a
        # column two millimetres across. Break it by character rather than
        # letting it run past the edge unnoticed.
        #
        # -emergencyHyphen puts a hyphen on such a break. OFF by default, and
        # that is a decision rather than caution: the words that reach this
        # fallback are as often a part number, a file path or a URL as they
        # are a long word, and a hyphen inside one of those is not a
        # typographic aid but a character the reader will copy and a wrong
        # value. A caller who knows the column holds words says so.
        #
        # The hyphen needs ROOM, so it is measured with the piece rather than
        # added after: taking as many characters as fit and then hanging a
        # hyphen on them is how the line comes out one hyphen too wide.
        while {![my TextBlockFits $word $width $arguments \
            $string $wordFrom] && [string length $word] > 1} {
          set take [string length $word]
          set mark [expr {$emergency ? "-" : ""}]
          while {$take > 1 && [my TextBlockMeasure \
              "[string range $word 0 $take-1]$mark" \
              $arguments $string $wordFrom] > $width} {
            incr take -1
          }
          # A piece of one character with a hyphen after it is two glyphs
          # where the column holds one - the hyphen goes rather than the
          # letter, since a line with nothing of the word on it says less
          # than a line without the mark.
          if {$take == 1 && $mark ne ""
              && [my TextBlockMeasure "[string range $word 0 0]$mark" \
                  $arguments $string $wordFrom] > $width} {
            set mark ""
          }
          lappend lines [dict create \
              text "[string range $word 0 $take-1]$mark" \
              offset $offset width $width paragraph $paragraphIndex \
              hyphen [expr {$mark ne ""}] \
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
  method TextBlockFits {text width arguments string base} {
    return [expr {[my TextBlockMeasure [my TextBlockClose $text] $arguments \
        $string $base] <= $width}]
  }

  # A measurement the breaker makes on a CHUNK of the block: the string as
  # the caller handed it in travels with it, and base says where in that
  # string the chunk begins. A glyph refusal thrown from inside carries a
  # position counted in the chunk; the contract (manual, "Error codes") is
  # the 0-based index in the caller's string, so it is rebased before it
  # goes on. Everything else passes through untouched.
  method TextBlockMeasure {text arguments string base} {
    try {
      return [my textWidth $text {*}$arguments]
    } trap {TCLPDF FONT GLYPH} {message options} {
      set position [my TextBlockLocate $arguments $string $base]
      if {$position < 0} {
        # The refused character is not one of the caller's: the only one the
        # breaker adds is the hyphen it sets at an offer. Nothing in the
        # string to point at, so the refusal travels as it was thrown.
        return -options $options $message
      }
      my TextBlockRebase $message $options $position
    }
  }

  # Where the refused character stands in the string: the first one from
  # base on that the face refuses ON ITS OWN. Counting instead - chunk
  # position plus base - is off wherever the chunk is not the string
  # verbatim, and it is not in two places by design: a run of separators
  # between two words is measured as the single space they are to the page,
  # and the character fallback measures a word with its soft hyphens taken
  # out. Asking the face again costs a measurement per character, on the
  # road to a refusal only.
  #
  # The separators are skipped, because the breaker never hands one to a
  # face - a tab HAS no glyph in the standard fourteen and would be found
  # here instead of the character that was really refused. Everything the
  # chunk did contain in front of the refusal was measured and accepted, so
  # the first refusal from base on is the one that was thrown.
  method TextBlockLocate {arguments string base} {
    set length [string length $string]
    for {set index $base} {$index < $length} {incr index} {
      set char [string index $string $index]
      if {[string first $char $::tclpdf::textBlock::separators] >= 0} {
        continue
      }
      try {
        my textWidth $char {*}$arguments
      } trap {TCLPDF FONT GLYPH} {} {
        return $index
      }
    }
    return -1
  }

  # Throw a glyph refusal on with another position: the errorcode element,
  # the number in the message and the one in -errorinfo, so that a caller
  # who traps the code and one who reads the message are told the same
  # place. The wording of the message is not a contract and is left as the
  # font wrote it; the position in it is.
  method TextBlockRebase {message options position} {
    set code [dict get $options -errorcode]
    dict set options -errorcode [lreplace $code 4 4 $position]
    regsub {\(position \d+\)} $message "(position $position)" message
    if {[dict exists $options -errorinfo]} {
      regsub {\(position \d+\)} [dict get $options -errorinfo] \
          "(position $position)" info
      dict set options -errorinfo $info
    }
    return -options $options $message
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
  # TWO SOURCES OF AN OFFER, and this method is where they meet:
  #
  # U+00AD is an offer, not a character: "you may break here". Text arriving
  # from a database, an XML file or an editor often carries the marks already,
  # and until this existed they were either set as a visible hyphen or refused
  # outright.
  #
  # The patterns of tclpdf::hyphenate compute the same offers for a word that
  # carries none, in the language -hyphenate named. Which source an offer came
  # from is of no interest below: what the loop needs is a list of pieces to
  # try from the back, and both sources hand it one.
  #
  # A WORD THAT CARRIES MARKS IS NEVER COMPUTED. Whoever put them there knew
  # this word - it may be a name, a compound the patterns get wrong, or a
  # place a translator chose - and mixing the two sources would produce breaks
  # neither of them asked for. The mark road is therefore taken as soon as
  # there is one mark in the word, and the pattern road only when there is
  # none.
  #
  # The two differ in ONE character, and it is the reason "mark" is a variable
  # rather than a constant: what is left over has to be the tail of the word
  # verbatim, because the caller counts its length to advance through the
  # string. The marks the split took out are put back for that; a computed
  # break took nothing out and puts nothing back.
  #
  # The hyphen that appears at the break is a real one (U+002D), so the line
  # ends the way a reader expects, and it is bracketed as a break rather than
  # as text - see "hyphen 1" in the breaker above and TextRun in text.tcl.
  method TextBlockHyphen {prefix glue word width arguments string base {language {}}} {
    set mark "\u00AD"
    if {[string first $mark $word] >= 0} {
      set parts [split $word $mark]
    } elseif {$language ne {}} {
      set parts [::tclpdf::hyphenate word $language $word]
      set mark {}
    } else {
      return {}
    }
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
      if {[my TextBlockMeasure $head $arguments $string $base] <= $width} {
        return [list $head [join [lrange $parts $take end] $mark]]
      }
    }
    return {}
  }

  # Measure the WHOLE string once, before the breaker sees it. The breaker
  # measures candidate chunks of a paragraph, so a glyph refusal thrown from
  # inside it carried a position counted in the chunk under measurement - and
  # which chunk that is depends on the glyph widths, so the same missing
  # glyph was reported at one position with one face and at another with the
  # next. The errorcode contract (manual, "Error codes") promises the 0-based
  # index in the string as handed in; measured whole and first, the refusal
  # comes from the same road [textWidth] takes, with the same font options
  # the breaker measures with, and the position is counted in the caller's
  # string. The table does the same before it wraps a cell (tableLayout.tcl),
  # which is why its refusals were right all along.
  #
  # Run by run between the characters the breaker never hands to a face
  # whole: the separators - a line feed or a tab has no glyph anywhere, and
  # the breaker sets the space of the page for them - and the breakable
  # spaces, which are set or stripped by where the lines happen to END, so
  # no measurement in advance can say whether a face will be asked for one -
  # and measuring one here would refuse a document that is written today:
  # U+200B ends a line in Helvetica without ever reaching a face. A
  # breakable space the break leaves INSIDE a line is therefore refused by
  # the breaker itself, and the breaker names the place in the caller's
  # string as well (TextBlockMeasure). Everything else sits inside a
  # run, the position moved out by what stands in front of it; the
  # characters the measuring loops skip without setting - the soft hyphen,
  # the zero width space, the byte order mark - are counted by those loops
  # already, so nothing shifts.
  #
  # The cost is ONE extra measuring pass over the block's text per call, on
  # top of the many the breaker makes anyway - linear, not quadratic: the
  # breaker's chunk measurements stay what they were, and every chunk it
  # measures is text this pass has already accepted.
  method TextBlockPremeasure {string arguments} {
    set skip "$::tclpdf::textBlock::separators$::tclpdf::textBlock::breakable"
    foreach span [regexp -all -inline -indices "\[^$skip\]+" $string] {
      lassign $span from to
      try {
        my textWidth [string range $string $from $to] {*}$arguments
      } trap {TCLPDF FONT GLYPH} {message options} {
        # A run IS the string verbatim from $from on, so counting is exact
        # here - TextBlockRebase does the throwing on, the same one the
        # breaker's own measurements use.
        my TextBlockRebase $message $options \
            [expr {[lindex [dict get $options -errorcode] 4] + $from}]
      }
    }
    return
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
  # A VERTICAL TEXT IS BROKEN HERE AND PLACED BY THE CALLER, since 2026-08-25.
  #
  # The breaker never needed the direction: what it asks of every candidate is
  # "how far does this reach", and [textWidth] answers that along whichever
  # axis the text writes - [FontRunHeight] for a vertical run, [FontRunWidth]
  # for a horizontal one. So -width is the COLUMN HEIGHT for such a text, and
  # the columns come back in reading order.
  #
  # What is NOT here, and is the reason [text -width -direction ttb] is still
  # refused: PLACING them. A horizontal block steps its lines down by the
  # leading, and a vertical one has to step its columns LEFT by it - the whole
  # of [TextBlockPlace], the height limit, the column balance, the shapes to
  # avoid and the table are written along the one axis, and turning them is
  # the second half of this subject rather than a flag. The caller sets each
  # column with its own [text] call, which is one loop and exactly what the
  # refusal in [TextLift] now says.
  #
  # "lift" says whether the first baseline's offset below -at is wanted. It is
  # for every road that DRAWS or measures a height; [textLines] wants neither,
  # and asking for it there is what used to refuse a vertical block outright -
  # see [TextLift], where the refusal is, and why breaking is a different
  # question from placing.
  method TextBlockLines {string options {lift 1}} {
    set width [dict get $options width]
    set arguments [my TextOverrides $options]
    # The whole string, measured once and first - a glyph refusal has to
    # name the position in the caller's string, not in a chunk of the
    # breaker's; see TextBlockPremeasure.
    my TextBlockPremeasure $string $arguments
    set state [my TextMerge $arguments]
    set leading [::tclpdf::geometry fromPoints [dict get $state leading] \
        [my cget -unit]]

    # The anchor stays put and every line says how far BELOW it its baseline
    # sits. Advancing y instead was correct only as long as nothing turned:
    # each line was rotated about its own advanced point, so a rotated
    # paragraph drew all of its lines on top of one another - measured, and
    # unreadable. As a lift the advance goes through the text matrix and turns
    # with the text, which is what makes the lines run across the page.
    set lift [expr {$lift ? [my TextLift $state [dict get $options anchor]] : 0}]

    # The band this paragraph is set in - built by TextBlockBand, which the
    # no-room answer of TextBlockNoRoom asks as well.
    set band [my TextBlockBand $options]

    # Shapes to flow around narrow the band per line instead of per paragraph.
    # Loaded only when asked for: a caller who never avoids anything does not
    # pay for the module.
    if {[llength [dict get $options avoid]]} {
      package require tclpdf::textAvoid
      my TextAvoidCheck [dict get $options avoid] [dict get $options avoidMargin]
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
          [my TextBlockWidest $string $arguments] $band]
    }

    set lines [my TextBlockBreak $string $arguments $band \
        [my TextBlockHyphenate $options] [dict get $options emergencyHyphen]]

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

  # The band the indents make: the column narrowed by -indent and
  # -indentRight, and the first line of each paragraph narrowed once more by
  # -firstIndent. A negative -firstIndent is a hanging indent and is the
  # reason the offset is carried per line rather than added to x once.
  #
  # A block that CONTINUES a paragraph - the rest of a height-limited block
  # set on the next page by [text -paginate] - opens with a line that is
  # not the first of its paragraph, however much it is the first of this
  # block; the first indent belongs to the paragraph, not to the page, so
  # that line does without. Every paragraph after it is a whole one and
  # indents as usual. Internal: set by the pagination, not an option.
  #
  # One builder, because the same band now serves two askers: the breaker
  # (TextBlockLines) and the no-room answer of TextBlockNoRoom.
  method TextBlockBand {options} {
    set continued [expr {[dict exists $options continued]
        && [dict get $options continued]}]
    return [list apply {{width indent indentRight firstIndent continued line paragraph running} {
      set extra [expr {$line == 0 && !($continued && $paragraph == 0) ?
          $firstIndent : 0}]
      return [list [expr {$width - $indent - $indentRight - $extra}] \
          [expr {$indent + $extra}]]
    }} [dict get $options width] [dict get $options indent] \
        [dict get $options indentRight] [dict get $options firstIndent] \
        $continued]
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
      # Measured one character at a time and in sorted order, so a refusal
      # thrown here always says "position 0". The characters this reaches
      # that the pre-measurement does not are the breakable spaces; the
      # place they hold in the caller's string is looked up like the
      # breaker's (TextBlockMeasure).
      set width [my TextBlockMeasure $char $arguments $string 0]
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

  # Called by [text] when -width is given, with the options TextBlockCheck
  # has passed - the checks are there, in front of the mark, and not here.
  # Returns the y coordinate BELOW the block, so the next element can be
  # placed without counting lines - or, with -height, the dictionary {y
  # rest}; with -paginate or -columns {y rest page column}.
  method TextParagraph {string options} {
    set paginate [dict get $options paginate]
    if {$paginate || [dict get $options columns] > 1} {
      return [my TextPaginate $string $options $paginate]
    }
    lassign [my TextParagraphOnce $string $options] y rest continued
    if {[dict get $options height] ne {}} {
      return [dict create y $y rest $rest]
    }
    return $y
  }

  # The block from a page break to the next: [text -paginate 1]. What fits
  # under -at goes on this page, the rest on a fresh page from the top of
  # the type area, and so on until nothing is left. Each column is one
  # [TextParagraphOnce] with -height max; between two pages the page is
  # added here - which fires pageAdded like any [page add], so a running
  # head hung on that event lands on every continuation page - and the
  # column starts again at {x top}, with -avoid dropped: the shapes are
  # positions on the first page and mean nothing on the next.
  #
  # -columns n sets n columns side by side inside -width, -gutter apart,
  # each filled to the bottom before the next begins; the page is added
  # only after the last column. With paginate 0 (a -height max block with
  # columns) the loop stops after the columns of THIS page and hands the
  # rest back like -height does.
  #
  # -balance: on the page the text ends on, the columns are cut to the
  # same height instead of the first ones full and the last one short. The
  # height is found by measuring, not drawing - TextBalanceLimit below -
  # and only when the whole rest fits into the page's columns; a page that
  # is filled anyway has nothing to balance.
  #
  # Tagged, the whole run is ONE element with a mark per page (see
  # StructureMarkAgain), the shape a broken table has too; the marks are
  # opened and closed here because a mark cannot straddle a page break -
  # each content stream brackets its own, all the columns of a page in one.
  #
  # Answers {y rest page column}: y under the last line drawn, rest empty
  # under -paginate (there so that a caller reading -height's answer can
  # read this one the same way) or the text that did not fit into this
  # page's columns without it, page the index of the page the text ended
  # on, column the column it ended in, counted from 0.
  method TextPaginate {string options paginate} {
    lassign [dict get $options at] x y
    dict set options height max
    set tag [dict get $options tag]
    set columns [dict get $options columns]
    set gutter [dict get $options gutter]
    set balance [dict get $options balance]
    set width [dict get $options width]
    # Positive: TextBlockCheck refused the combination that would not be.
    set columnWidth [expr {($width - $gutter * ($columns - 1)) / double($columns)}]
    dict set options width $columnWidth
    set element {}
    set continued 0
    set column 0
    # Whether the page the loop is on is one IT added, as against the
    # caller's page the block was placed on. Two things hang on it. A page
    # not one line fits into is refused - but only a fresh one: there the
    # text starts at the top of the area, and what does not fit there never
    # will, so going on would add pages for ever. The caller's page is
    # different: -at may sit three millimetres above the bottom of the area
    # on purpose, the way a heading lands there, and the answer to that is
    # the next page, not an error. The guard used to be "the rest is still
    # whole and a continuation flag is set", and the flag was set after the
    # first column of ANY page - so the caller's own page was refused with a
    # message about a page it had not asked for.
    #
    # And on the caller's page nothing is marked or drawn when nothing fits:
    # a mark opened around no content would put a leaf with an empty MCID
    # into the tree. Decided in advance from the leading and the room -
    # TextBlockPlace holds every line back when the first one, at the top
    # of the block, does not fit, and that first line needs one leading
    # under the first baseline (see TextParagraphOnce for the lift) - and,
    # with shapes to avoid, from the page measured as the drawing would
    # draw it (TextPaginateEmpty): a shape over the whole band leaves no
    # line on the page where the leading alone saw room.
    set fresh 0
    while {1} {
      set rest $string
      # A -height max block with columns is not paginating: its page is the
      # caller's, and an empty answer with the whole rest is what -height
      # gives for a block below the area - answered here, before the mark,
      # for the reason above; it used to mark and then draw nothing.
      if {!$paginate && [my TextPaginateEmpty $string $options $x $y \
          $columnWidth $gutter $columns]} {
        return [dict create y $y rest $string page [my page current] \
            column [expr {$columns - 1}]]
      }
      set room [expr {$fresh || ![my TextPaginateEmpty $string $options $x $y \
          $columnWidth $gutter $columns]}]
      if {$room} {
        # The mark, per page. Its top is where the text begins - -at for
        # -anchor top, one ascent above the baseline otherwise - as in [text].
        set mark {}
        if {[my state tagged] eq "1"} {
          set top $y
          if {[dict get $options anchor] ne "top"} {
            set state [my TextMerge [my TextOverrides $options]]
            set top [expr {$top - [my TextLift $state top]}]
          }
          # The first page decides: a structure element gets its further
          # marks through StructureMarkAgain, an artifact is simply declared
          # again on every page - artifacts are not in the tree and have no
          # element to come back to.
          if {$element eq {} || $element eq "artifact"} {
            set mark [my StructureMark $tag Layout $top]
            if {[lindex $mark 0] eq "artifact"} {
              set element artifact
            } elseif {[llength $mark]} {
              set element [lindex $mark 2]
            }
          } else {
            set mark [my StructureMarkAgain $element $top]
          }
          my content [my StructureBegin $mark]
        }
        set before $string
        # What can fail from here on is what only the drawing meets - a
        # glyph the face lacks, met when the page's share is measured or
        # set. Caught, so that the bracket above is closed before the error
        # travels on, and then rethrown exactly as it was, errorcode and
        # all - the same guard [text] holds around its own mark (text.tcl),
        # which covers every road but this one: without it the BDC of this
        # page stayed open, the EMC count fell one short, and whatever
        # content came next became a child of the dead paragraph - nested
        # MCIDs, which 14.7.4.2 does not allow.
        set failed [catch {
          # Balanced columns are cut to one height when the rest fits the
          # page; otherwise every column runs to the bottom of the area.
          if {$balance && $columns > 1} {
            set limit [my TextBalanceLimit $string $options $y $columns]
            if {$limit ne {}} {
              dict set options height $limit
            }
          }
          for {set column 0} {$column < $columns} {incr column} {
            dict set options at [list [expr {$x + $column * ($columnWidth + $gutter)}] $y]
            lassign [my TextParagraphOnce $string $options] yEnd rest continued
            if {$rest eq {}} {
              break
            }
            set string $rest
            dict set options continued $continued
          }
        } result info]
        if {[llength $mark]} {
          my content [my StructureEnd $mark]
        }
        if {$failed} {
          return -options $info $result
        }
        if {$rest eq {}} {
          set column [expr {min($column, $columns - 1)}]
          set y $yEnd
          break
        }
        if {!$paginate} {
          # -height max with columns: this page's columns are full, the rest
          # is the caller's, like the rest of any height-limited block.
          return [dict create y $yEnd rest $rest page [my page current] \
              column [expr {$columns - 1}]]
        }
        if {$fresh && $rest eq $before} {
          # A fresh page, the whole rest still there: not one line fits into
          # the type area. Going on would add pages for ever.
          lassign [my page typeArea] -> areaTop -> areaBottom
          return -code error "tclpdf: text -paginate: not one line fits into\
              the type area of page [expr {[my page current] + 1}] - the area is\
              [format %g [expr {$areaBottom - $areaTop}]] high\
              ([format %g $areaTop] to [format %g $areaBottom]) and the leading\
              is [format %g [my TextBlockLeading $options]]"
        }
      }
      my page add
      set fresh 1
      lassign [my page typeArea] -> y
      set string $rest
      dict set options continued $continued
      dict set options avoid {}
      dict set options height max
      # The continuation begins AT the top of the area: its first line hangs
      # from that edge, whatever the caller's anchor was for the first block
      # - -anchor baseline there would put the ascenders above the area.
      dict set options anchor top
    }
    return [dict create y $y rest {} page [my page current] column $column]
  }

  # Whether a block starting at y on the current page has room for not one
  # line: the first baseline sits the lift under y, and the line needs a
  # leading under that - the same arithmetic TextParagraphOnce and
  # TextBlockPlace do for the limit of -height max, so that the two agree.
  # (A shape to avoid can only take room away, never add it, so a page this
  # says no to draws nothing whatever the shapes.)
  method TextPaginateNoRoom {options y} {
    set state [my TextMerge [my TextOverrides $options]]
    set leading [::tclpdf::geometry fromPoints [dict get $state leading] \
        [my cget -unit]]
    set lift [my TextLift $state [dict get $options anchor]]
    set limit [expr {max(0, [lindex [my page typeArea] 3] - $y - $lift)}]
    return [expr {$leading > $limit}]
  }

  # Whether not one line of the string lands on the current page: the
  # leading against the room under y (TextPaginateNoRoom), and, with shapes
  # to avoid, the page measured column by column the way the drawing
  # measures it - the same lines, the same limit. A shape over the whole
  # band makes the avoiding band skip line after line until it is past the
  # shape, which can be past the bottom of the area; the leading alone
  # cannot see that, and the structure mark opened over such a page
  # bracketed nothing - an empty "/P <</MCID n>> BDC EMC" with its MCR, a
  # leaf of nothing in the tree, exactly the ghost the note above promises
  # to keep out. So the mark waits for this answer. A drawn line counts even
  # when it is a blank one, because the drawing would consume it and move
  # on - this check must never say "empty" where the drawing would advance.
  # Costs one measuring pass over the page's text, and only where -avoid is
  # given; a column that lands nothing hands the next column the same text,
  # which is why the loop below need not carry a rest.
  method TextPaginateEmpty {string options x y columnWidth gutter columns} {
    if {[my TextPaginateNoRoom $options $y]} {
      return 1
    }
    if {![llength [dict get $options avoid]]} {
      return 0
    }
    dict set options height max
    for {set column 0} {$column < $columns} {incr column} {
      dict set options at [list [expr {$x + $column * ($columnWidth + $gutter)}] $y]
      lassign [my TextBlockLines $string $options] lines state leading lift
      set limit [expr {max(0, [lindex [my page typeArea] 3] - $y - $lift)}]
      lassign [my TextBlockPlace $lines $leading \
          [dict get $options paragraphSpacing] $limit] drawn
      if {[llength $drawn]} {
        return 0
      }
    }
    return 1
  }

  # The same question for the block [text] brackets itself - one with a
  # -height and neither -paginate nor -columns: whether its limit admits not
  # one line. "max" is the room under -at (TextPaginateNoRoom); a number is
  # the limit as TextBlockPlace applies it, and the first line, at the top of
  # the block, needs one leading inside it. Asked BEFORE the mark, for the
  # same reason TextPaginate asks: measured, a -height max block placed under
  # the type area wrote "/P <</MCID 0>> BDC EMC" around nothing and left a P
  # with a mark of nothing in the tree, and answered y with the whole rest -
  # which is the right answer, without the mark. A block without -height
  # always draws (its lines are not held back), so it is not asked.
  method TextBlockNoRoom {options} {
    set height [dict get $options height]
    if {$height eq {}} {
      return 0
    }
    set state [my TextMerge [my TextOverrides $options]]
    set leading [::tclpdf::geometry fromPoints [dict get $state leading] \
        [my cget -unit]]
    set lift [my TextLift $state [dict get $options anchor]]
    set y [lindex [dict get $options at] 1]
    if {$height eq "max"} {
      if {[my TextPaginateNoRoom $options $y]} {
        return 1
      }
      set limit [expr {max(0, [lindex [my page typeArea] 3] - $y - $lift)}]
    } else {
      if {$leading > $height} {
        return 1
      }
      set limit $height
    }
    if {![llength [dict get $options avoid]]} {
      return 0
    }
    # The leading found room, but a shape can leave none: a shape over the
    # whole band makes the avoiding band skip line after line until it is
    # past the shape, and the first line can land below the limit - the mark
    # [text] opens around the block would then bracket nothing (the ghost
    # named above). This road has no string - [text] asks before it hands
    # the text on - so the band itself is asked where the FIRST line lands,
    # with a minimum width of 0: the widest free sliver is accepted, so the
    # answer errs on the side of drawing and says "no room" only where the
    # drawing, whose lines need real width, would land nothing either. (A
    # blank first paragraph does not pass through the band; its line would
    # be consumed without content, and "no room" draws the same nothing and
    # keeps the blank at the head of the rest.)
    package require tclpdf::textAvoid
    lassign [::tclpdf::option point [dict get $options at] -at \
        "a block with -avoid"] x y
    set band [list my TextAvoidBand [dict get $options avoid] \
        [dict get $options avoidMargin] $x [expr {$y + $lift}] $leading \
        [dict get $options paragraphSpacing] 0 [my TextBlockBand $options]]
    lassign [my TextBlockAsk $band 0 0 0] width offset running
    return [expr {($running + 1) * $leading > $limit}]
  }

  # The height that spreads a text evenly over n columns starting at y on
  # the current page - the balance of the last page -, or {} when the text
  # does not fit into the columns at their full height, in which case the
  # page is filled and there is nothing to balance.
  #
  # Measured, not drawn: the block is broken once at the column width -
  # every column has the same width, so the lines of column two are the
  # lines column one held back, re-based to start at zero - and
  # TextBlockPlace is asked, for a candidate height, how much of what is
  # left each column takes. The first candidate is the total height over
  # n; it grows by one leading until the last column takes the last line.
  # A whole-line height, so that the columns end on a baseline together.
  method TextBalanceLimit {string options y columns} {
    lassign [my TextBlockLines $string $options] lines state leading lift
    set spacing [dict get $options paragraphSpacing]
    set maximum [expr {[lindex [my page typeArea] 3] - $y - $lift}]
    lassign [my TextBlockPlace $lines $leading $spacing {}] -> -> total
    if {$total > $maximum * $columns} {
      return {}
    }
    set limit [expr {ceil($total / double($columns) / $leading) * $leading}]
    while {$limit <= $maximum} {
      set rest $lines
      for {set column 0} {$column < $columns && [llength $rest]} {incr column} {
        lassign [my TextBlockPlace [my TextLinesRebase $rest] $leading \
            $spacing $limit] drawn rest -
      }
      if {![llength $rest]} {
        return $limit
      }
      set limit [expr {$limit + $leading}]
    }
    return {}
  }

  # The lines a column held back, counted from the top of the next one:
  # TextBlockPlace measures a line by its running number, and the running
  # numbers of a tail begin where the head ended.
  method TextLinesRebase {lines} {
    if {![llength $lines]} {
      return $lines
    }
    set first [dict get [lindex $lines 0] running]
    return [lmap line $lines {
      dict set line running [expr {[dict get $line running] - $first}]
    }]
  }

  # The leading of a block in the document unit - for a message.
  method TextBlockLeading {options} {
    set state [my TextMerge [my TextOverrides $options]]
    return [::tclpdf::geometry fromPoints [dict get $state leading] [my cget -unit]]
  }

  # One block, drawn: what fits, and what is held back. Answers {y rest
  # continued} - y under the last drawn line, rest the tail of the string
  # from the first character not drawn (empty when everything was), and
  # continued whether that tail begins in the middle of a paragraph. The
  # last is what a continuation needs to know about its first indent.
  method TextParagraphOnce {string options} {
    lassign [my TextBlockLines $string $options] lines state leading lift
    # Mirrored once, here, for every line of the block - see TextAlign in
    # text.tcl for what "left" means in a right-to-left line.
    set align [my TextAlign [dict get $options align] $state]
    lassign [dict get $options at] x y

    # A height limit turns the block into the first of several: what fits is
    # drawn, what does not is handed back. The caller decides where the rest
    # goes - the next column, the next page - which is why this method does
    # not try to know. "max" is the distance from here to the bottom of the
    # type area, less the lift: with -anchor top the first baseline sits an
    # ascent below y, and the block has to end inside the area, not an
    # ascent under it.
    set limit [dict get $options height]
    if {$limit eq "max"} {
      set limit [expr {max(0, [lindex [my page typeArea] 3] - $y - $lift)}]
    }
    lassign [my TextBlockPlace $lines $leading \
        [dict get $options paragraphSpacing] $limit] drawn rest below

    # A line that is followed by more of the same text - the next line of
    # its paragraph, or the first of the next one - is drawn with a space
    # after it (see TextParagraphLine for why). The last line of the WHOLE
    # block is the only one that is not: the last DRAWN line, with a rest
    # held back, is followed by that rest, on the next page of a paginated
    # run or in the caller's next call.
    set last [lindex $lines end]
    foreach entry $drawn {
      lassign $entry line top
      if {[dict get $line text] ne {}} {
        my TextParagraphLine [dict get $line text] $state \
            [expr {$x + [dict get $line offset]}] $y [dict get $line width] \
            $align [dict get $line closes] [dict get $options rotate] \
            [expr {$lift + $top}] [dict get $line hyphen] \
            [expr {$line ne $last}]
      }
    }
    # Text, not lines: the rest may have to be broken again for a column of
    # a different width, and handing back lines would silently fix the old
    # break points. And the TAIL OF THE STRING, not lines joined back
    # together: the first line held back knows where in the string it
    # begins, and everything from there on is the rest - soft hyphens still
    # soft, a word the fallback broke by character still one word, the
    # paragraph breaks where they were.
    set text {}
    set continued 0
    if {[llength $rest]} {
      set text [string range $string [dict get [lindex $rest 0] from] end]
      set continued [expr {![dict get [lindex $rest 0] first]}]
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
    #
    # Nothing drawn - a -height max block placed under the area - and the
    # answer is y as it was given: no line, no ascender to count. It used to
    # be y plus the lift, so an -anchor top block that drew nothing moved
    # the caller's next element down by an ascent it never used.
    if {![llength $drawn]} {
      return [list $y $text $continued]
    }
    return [list [expr {$y + $lift + $below}] $text $continued]
  }

  # Alignment inside the column is a shift along the baseline and is passed
  # to TextRun rather than applied to x - with -rotate the baseline is
  # turned, and a pre-shifted x would rotate about the wrong point (same
  # reasoning as in [text], text.tcl).
  method TextParagraphLine {line state x y width align isLast rotate {lift 0} {hyphen 0} {followed 1}} {
    # The space the line breaker consumed has to reappear in the content
    # stream: a line ends where a word ended, and without it the next line
    # follows immediately - "der Antrieb ist" plus "getauscht" comes back out
    # as "istgetauscht" to anything that reads the text rather than the page.
    # ISO 32000-1 14.8.2.6 says so for tagged documents, and it is measured:
    # pdfinfo -struct-text showed exactly that, while neither veraPDF profile
    # noticed.
    #
    # The same for the line that CLOSES a paragraph when another paragraph
    # follows in the same call: the paragraph break is a line feed in the
    # string, which has no glyph, and without the space the two came back as
    # "First para end.Second para start." from one element - measured with
    # pdfinfo -struct-text, 2026-08-18. Whether something follows is the
    # caller's to say (followed): the last line of a block has nothing after
    # it and gets none.
    #
    # It goes into the DRAWN string only, never into the measured one - the
    # widths below decide the alignment, and a trailing space must not move
    # a right aligned or centred line. Visually it changes nothing either
    # way: it sits after the last glyph of the line. isLast - the line
    # closes its paragraph - keeps its own meaning below: it is what
    # decides that the line is not justified.
    #
    # Only for tagged documents, so nothing that exists today comes out with
    # different bytes.
    set drawn $line
    if {(!$isLast || $followed) && [my state tagged] eq "1"} {
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

package provide tclpdf::textBlock 1.12