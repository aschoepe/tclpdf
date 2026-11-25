#
# tclpdf - PDF generation for Tcl
#
# textMissing - what happens to a character no face can set
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# THE RULE STAYS. A character that neither the family nor a face of the
# -fallback chain has a glyph for is refused, TCLPDF FONT GLYPH, and that is
# the default of everything below: a missing glyph has no good SILENT answer
# - dropping it loses data, .notdef prints an empty box, another face changes
# the design - and examples/02.04-missing-glyphs.tcl says why at length. What
# it also says is where the line runs: "ASKED FOR, it is a different matter
# ... what is wrong is only the silent version". This module is the asked-for
# version, in two steps.
#
#   textMissing   the QUESTION: which characters of this string can the chain
#                 not set, as {codepoint position ...}, all of them in one
#                 call. Without it the only answer was the refusal, one
#                 position per call - and under Tcl 8.6 that position counts
#                 code points while [string replace] counts UTF-16 units, so
#                 a caller repairing a string by the error's position hit the
#                 character in front of an emoji and got the same refusal
#                 back, for ever.
#
#   -missing replace, -replacement char
#                 the ANSWER on request: two options of the font state, so
#                 they reach wherever -fallback reaches - a paragraph, a table
#                 cell, textPath, leader, pageNumbers, an SVG drawing. Only
#                 where the WHOLE chain has nothing is a character replaced;
#                 the replacement (U+FFFD by default) has to be settable by
#                 the chain itself, and that is asked at the call that writes
#                 the option, like an unknown -fallback alias - not at the
#                 first line that needs it.
#
# WHAT GOES INTO THE FILE. The replacement is drawn as a glyph of the face
# that has it, and the ToUnicode map of that face says what the glyph IS -
# U+FFFD - exactly as it does for a mirrored bracket. Beside it the ORIGINAL
# character stands as an ActualText span (ISO 32000-2, 14.9.4), the device
# text.tcl already uses for the mirrored bracket and the break hyphen. So the
# page shows the replacement, and copying, searching and a screen reader get
# the character that was written: the text is not falsified for the reader
# who cannot see it, which under PDF/UA is the reader the document is for.
#
# WHAT THE CALLER IS TOLD, on two roads that exist already:
#
#   textReplaced  {codepoint count ...} of everything drawn as a replacement
#                 since the last time it was asked - see the method for why
#                 "since asked" and not "the last call" as [svg info] has it
#   glyphReplaced an event on the bus, per replaced character, with the code
#                 point, its position in the line and the faces that were
#                 asked - so a log in a batch run needs no question at all
#
# Both are fed where the replacement is DRAWN, never where it is measured: a
# paragraph measures the same word a dozen times while it is broken, and a
# count that grew with every measurement would answer how hard the line
# breaker worked rather than what is on the page.
#
# WHERE IT HOOKS IN. The walk of the line is [TextSegments], in text.tcl, and
# it is not copied here: the branch that found no face for a character calls
# [TextMissingSegment], which hands back a segment of its own - the face of
# the replacement, the replacement, the original and its position. Measuring
# ([TextPoints]) and drawing ([TextShow]) walk those same segments, so the
# width of a line is the width of what is drawn and cannot differ from it.
# The question [textMissing] asks is the same walk again, in a mode that
# replaces nothing and only collects. Without -missing replace none of this
# module is loaded, and a document that never asks for it writes the bytes it
# always wrote.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.9-
package require tclpdf::text 1.28-
package require tclpdf::document 1.18-

namespace eval ::tclpdf::textMissing {
  # The values of -missing. "query" is the third mode [TextSegments] knows,
  # and it is not one of them: it is what [textMissing] sets for its own walk
  # and never what a caller can write.
  variable modes {error replace}
}

oo::define ::tclpdf::document::document {

  # $doc textMissing string ?font options?  -> {codepoint position ...}
  #
  # The characters of the string that neither the family nor any face of the
  # -fallback chain can set, in the order they stand. The codepoint is
  # written U+XXXX and the position is the 0-based index in CODE POINTS - the
  # two facts TCLPDF FONT GLYPH carries, so a caller can treat a refusal and
  # this answer alike. An empty list means the string can be set as it is.
  #
  # A line feed is where a paragraph breaks and not a character of any line,
  # so it is passed over and counted, as [textWidth] passes it over by
  # measuring the lines one at a time. The three characters that never reach
  # a face (text.tcl, neverDrawn) are not missing either: nothing is drawn
  # for them, so no face can lack them.
  method textMissing {string args} {
    my TextInit
    # The options [textWidth] takes, for the same reason: this asks a string
    # about faces, it does not place it.
    set known {}
    foreach name $::tclpdf::text::lineOptions {
      dict set known $name {}
    }
    ::tclpdf::option parse $known $args "textMissing"
    set state [my TextMerge $args]
    dict set state missing query
    set result {}
    set offset 0
    foreach line [split $string \n] {
      foreach segment [my TextSegments $state $line] {
        if {[llength $segment] > 2} {
          lassign $segment -> -> original position
          lappend result [my TextMissingCode $original] \
              [expr {$offset + $position}]
        }
      }
      # Code points, as [TextSegments] counts them: [split] keeps a
      # surrogate pair of Tcl 8.6 together, [string length] does not.
      incr offset [expr {[llength [split $line {}]] + 1}]
    }
    return $result
  }

  # $doc textReplaced  -> {codepoint count ...}
  #
  # What was drawn as a replacement since this was last asked, each code
  # point once, in the order it first came, with how often.
  #
  # SINCE ASKED, AND NOT "THE LAST CALL" as [svg info] has it, because a
  # drawing is one call and text is not: a table sets every cell through a
  # [text] of its own, a leader sets two, and pageNumbers draws at [write],
  # once per page - a report that started afresh with every one of those
  # would answer for the last cell of the table or the last page number. So
  # the count runs across the calls, and asking for it is what starts it
  # afresh: asked after each call it is per call, asked once at the end it
  # is the document. Drawn at write time means counted at write time, and a
  # document written twice draws its page numbers twice.
  method textReplaced {} {
    set replaced [my state textReplaced]
    my state textReplaced {}
    return $replaced
  }

  # The value of -missing or -replacement, checked as it is written - in
  # [font] and per call alike, through [TextCheck], which hands over only a
  # value other than the default so that a document that never names either
  # option never loads this module.
  #
  # Whether the CHAIN can set the replacement is a second question and is
  # asked in [TextMissingCheck]: it depends on -family and -fallback, which
  # the same call may change.
  method TextMissingOption {name value} {
    if {$name eq "missing"} {
      if {$value ni $::tclpdf::textMissing::modes} {
        return -code error -errorcode [list TCLPDF FONT ARGUMENT missing] \
            "tclpdf: -missing is error or replace, not \"$value\" - error\
            refuses a character no face of the chain has, replace draws\
            -replacement in its place"
      }
      return $value
    }
    # .notdef is NOT offered, and it is named because it is what a caller
    # who wants "the box" writes. PDF/UA forbids a reference to it outright
    # and PDF/A-2 and -3 the same way (ISO 14289-1, 7.21.8; ISO 19005-2,
    # 6.2.11.8), and a reader draws it as an empty box or as nothing - the
    # silent answer this module exists to avoid.
    if {$value eq ".notdef"} {
      return -code error -errorcode [list TCLPDF FONT ARGUMENT replacement] \
          "tclpdf: -replacement .notdef is not offered - PDF/UA and PDF/A\
          forbid a reference to the .notdef glyph, and a reader draws it as\
          an empty box or as nothing; name a character the chain has, such\
          as U+FFFD (the default) or \"?\""
    }
    if {[llength [split $value {}]] != 1} {
      return -code error -errorcode [list TCLPDF FONT ARGUMENT replacement] \
          "tclpdf: -replacement is one character, not\
          \"$value\" - the character drawn where no face has a glyph,\
          U+FFFD by default; a space leaves a gap"
    }
    # A character nothing draws would replace the missing one by nothing at
    # all - the dropped character again, which is the one answer this does
    # not give. A space is allowed: it leaves a visible gap, and the manual
    # says so.
    if {$value in $::tclpdf::text::neverDrawn} {
      return -code error -errorcode [list TCLPDF FONT ARGUMENT replacement] \
          "tclpdf: -replacement [my TextMissingCode $value] draws nothing -\
          the soft hyphen, the zero width space and the byte order mark\
          never reach a face, so the missing character would vanish without\
          a trace; a space leaves a visible gap"
    }
    return $value
  }

  # Can the chain of this state set its own replacement? Asked wherever the
  # state is written with -missing replace - [font], and [TextMerge] for a
  # call that changes the family, the chain or either option - because a
  # replacement no face has would be refused at the first line that needs
  # it, which may be a page number at [write].
  #
  # Through [TextCovers], the question the walk itself asks, so the two
  # cannot disagree about a face.
  method TextMissingCheck {state} {
    set replacement [dict get $state replacement]
    set chain [my TextChain $state]
    foreach face $chain {
      if {[my TextCovers $face $replacement]} {
        return
      }
    }
    set u [my TextMissingCode $replacement]
    return -code error \
        -errorcode [list TCLPDF FONT REPLACEMENT $u $chain] \
        "tclpdf: -missing replace draws -replacement $u, and none of the\
        fonts [join $chain {, }] has a glyph for it - name a replacement\
        the chain has (\"?\" is in every standard face), or add a face that\
        has $u to -fallback (DejaVu Sans has U+FFFD)"
  }

  # The segment for a character no face of the chain has, called by
  # [TextSegments] from the branch that used to refuse it:
  #
  #   {face replacement original position}
  #
  # The face is the first one of the chain that has the replacement, as the
  # walk would have chosen it for that character. In the query mode of
  # [textMissing] nothing is replaced and the face and the replacement are
  # empty - only the last two are read.
  method TextMissingSegment {state chain char position} {
    if {[dict get $state missing] eq "query"} {
      return [list {} {} $char $position]
    }
    set replacement [dict get $state replacement]
    foreach face $chain {
      if {[my TextCovers $face $replacement]} {
        return [list $face $replacement $char $position]
      }
    }
    # Not reached through [font] or [TextMerge], which both asked this
    # already; said rather than drawn as a gap should a road get here that
    # did not.
    my TextMissingCheck $state
  }

  # The show operators of a replaced segment, as [TextShow] built them, put
  # into an ActualText span with the original character - and the place the
  # replacement is told: counted for [textReplaced] and announced on the
  # bus. Here because this is where it is DRAWN; see the head of the file.
  #
  # The span is the one text.tcl writes for a mirrored bracket, a text string
  # in UTF-16BE with its byte order mark, a pair for a character beyond the
  # BMP. It goes into the content stream as a hex string directly, without
  # the document's string constructors, for the reason [TextShow] gives: a
  # content stream is encrypted as a whole.
  method TextMissingShow {state segment show} {
    lassign $segment -> -> original position
    set u [my TextMissingCode $original]
    set replaced [my state textReplaced]
    dict incr replaced $u
    my state textReplaced $replaced
    my emit glyphReplaced $u $position [my TextChain $state]
    return "/Span <</ActualText\
        [::tclpdf::pdfObj hexStr [::tclpdf::pdfObj::Utf16Be $original]]>>\
        BDC\n${show}EMC\n"
  }

  # A character as U+XXXX, the notation of TCLPDF FONT GLYPH: upper case,
  # four digits or more, the whole code point under both interpreters.
  method TextMissingCode {char} {
    return U+[format %04X [scan $char %c]]
  }
}

package provide tclpdf::textMissing 1.0
