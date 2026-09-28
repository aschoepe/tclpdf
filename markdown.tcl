#
# tclpdf - PDF generation for Tcl
#
# markdown - a paragraph written in Markdown, turned into the runs [text
# -runs 1] sets: "**bold**, *italic*, ~~struck~~, [a link](...), # a heading,
# - an item, 1. an item"
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# WHY A SECOND NOTATION (decided by the author, 2026-09-27). Text that
# already comes written in Markdown - from a ticket, a wiki page, a template
# kept by hand - should not have to be rewritten as tags before it can be
# set. The tags stay the first notation, for the reasons markup.tcl gives;
# this is the second, read with the same strictness.
#
# WHY THIS SUBSET. It is the part of Markdown that names something a run or
# a paragraph can be: strong, em, struck, a link, headings 1 to 3, and - since
# 2026-09-28, the author's decision - the items of a flat list, bulleted or
# numbered, one level deep. Underline has no Markdown spelling and gets none
# here: "_" is emphasis in CommonMark, and it is TEXT here, because it stands
# in file names, identifiers and snake_case far more often than around a
# word - -markup tags has <u> for the caller who needs one. Nested lists,
# code, images, quotes, tables and autolinks would need what a run cannot be
# (a second indent, a second face, a picture, a grid), so they are neither
# set nor refused: they come out as they were typed.
#
# WHY STRICT. CommonMark decides whether a "*" opens, closes or is text from
# what stands on both sides of it, and a caller cannot foresee the outcome
# without the specification at hand. Here the rules are few, and a fault is
# refused with its position rather than guessed at - as with the tags.
#
# WHAT THIS MODULE IS: a translator from one string into the list of {text
# options} pairs that textRun.tcl takes, like markup.tcl - and the pairs come
# out of markup.tcl's [emit], from a stack that carries markup.tcl's names
# (strong, em, s, a, h1 to h3, ul, ol, li). There is one vocabulary, not two: what
# "strong" does to a run is decided there alone, so a paragraph written in
# either notation gives the identical list.
#
# THE RULES, as the manual states them:
#
#   - **x** is strong, *x* is em, ***x*** is both (em around strong, as in
#     CommonMark), ~~x~~ is struck, [text](address) is a link. One to three
#     asterisks and exactly two tildes are delimiters; a longer run of either,
#     a single "~" and every "_" are text.
#   - A delimiter whose kind is open closes, and it has to close the
#     innermost open run - otherwise TCLPDF TEXT MARKDOWN NESTING, with the
#     delimiter and the position. A delimiter whose kind is not open opens a
#     run, unless a space, a line end or the end of the text follows it: then
#     it is text ("5 * 3", "a ** b"). Three asterisks where only one of the
#     two kinds is open close that one; what remains is read again.
#   - "[" opens a link unless a space or the end follows it, or a "!"
#     stands in front of it - "![alt](source)" is an image. The link text
#     runs to the first "]", which has to be followed by "(address)" - an
#     address that is not empty and holds no space - otherwise LINK. Runs
#     inside the link text are allowed, a run still open at its "]" is
#     NESTING, and a "[" inside it is text. A "]" outside a link is text.
#   - "# ", "## " and "### " at the start of the text or of a line make that
#     line a heading 1, 2 or 3. It ends at the line feed, which is its
#     paragraph end: where nothing follows, no empty paragraph is added, as
#     behind </h1>. Runs inside a heading are allowed; one still open at its
#     end, or a heading inside an open run, is NESTING; four or more "#" in
#     front of the space are HEADING. A "#" elsewhere, or without the space,
#     is text.
#   - "- ", "* " or "+ " at the start of the text or of a line make that line
#     a bulleted list item, one or two digits with ". " behind them ("1. " to
#     "99. ") a numbered one. An item is a paragraph: it ends at the line
#     feed, which is its paragraph end, exactly as a heading's - where nothing
#     follows, no empty paragraph is added, as behind </li></ul>. Every run of
#     the item carries "item bullet" or "item number"; consecutive items of
#     one kind are one list, and the number written in front of an item is
#     not read - the setting counts. Runs inside an item are allowed; one
#     still open at its end, or an item starting inside an open run, is
#     NESTING. Only the very start of a line counts: an indented "  - b" is
#     not a nested item but a line of text, spaces, dash and all - nesting by
#     indent is not built. Spaces behind the marker's one space are text of
#     the item. A "-", "*" or "+" without the space, or anywhere but at a
#     line start, and "100. " are text, as before - "5 * 3" stays text.
#   - Any other line feed stays a paragraph break, as without markup.
#   - A backslash in front of * ~ [ ] # - + . or \ makes that character
#     text; in front of anything else it is text itself. "\- x" and "1\. x"
#     are how a line starts with what would otherwise be an item marker.
#   - A run still open at the end of the text is OPEN.
#

package require Tcl 8.6.11-
package require tclpdf::markup 1.1-

namespace eval ::tclpdf::markdown {
  # How each name the stack can carry is written in Markdown - the spelling
  # a refusal quotes. What a name DOES to a run is not here: that is
  # markup.tcl's vocabulary, read by [::tclpdf::markup::emit].
  variable delimiters {em * strong ** s ~~ a [ h1 # h2 ## h3 ### ul - ol 1. li -}
  # The names that make a line a paragraph of its own - a heading, or a list
  # item - rather than a run in it. They stand at the bottom of the stack,
  # below every run, and a line feed ends them.
  variable lineBlocks {h1 h2 h3 ul ol li}
  # A run of delimiter characters, and the names it stands for; opened in
  # this order, so that *** is em around strong.
  variable runs {* em ** strong *** {em strong} ~~ s}
  # The characters a backslash turns into text.
  variable escapable {* ~ [ ] # - + . \\}
}

# The pairs a Markdown string sets as. Every refusal names the position in
# the string, counted in characters from 0, as the tags do.
#
# The state lives here and the helpers below reach it with [upvar]: the
# pairs so far, the text not yet emitted, the stack of {name href} entries
# that markup.tcl's [emit] reads, where each entry was opened, and - while a
# link is open - where its "]" stands and where reading goes on behind it.
proc ::tclpdf::markdown::parse {text} {
  variable escapable
  variable lineBlocks
  set pairs {}
  set buffer {}
  set stack {}
  set opened {}
  set linkEnd -1
  set linkResume -1
  set position 0
  set length [string length $text]
  set lineStart 1
  while {$position < $length} {
    set char [string index $text $position]
    if {$lineStart && [LineMarker $text]} {
      set lineStart 0
      continue
    }
    set lineStart 0
    switch -- $char {
      "\\" {
        set next [string index $text $position+1]
        if {$next ne {} && $next in $escapable} {
          append buffer $next
          incr position 2
        } else {
          append buffer $char
          incr position
        }
      }
      "\n" {
        LineEnd $text
        set lineStart 1
      }
      "*" - "~" {
        Delimiter $text
      }
      "\[" {
        LinkOpen $text
      }
      "\]" {
        if {$position == $linkEnd} {
          LinkClose
        } else {
          append buffer $char
          incr position
        }
      }
      default {
        append buffer $char
        incr position
      }
    }
  }
  # A heading or a list item is always at the bottom of the stack and ends
  # with the text; any other entry still open is a run nobody closed.
  if {[llength $stack] && [lindex $stack end 0] ni $lineBlocks} {
    set delimiter [Spelling [lindex $stack end 0]]
    set start [lindex $opened end]
    return -code error -errorcode [list TCLPDF TEXT MARKDOWN OPEN $delimiter $start] \
        "tclpdf: \"$delimiter\" at position $start is still open at the end\
        of the text - close it, or write it with a backslash in front to\
        make it text"
  }
  lassign [::tclpdf::markup::emit $pairs $buffer $stack] pairs buffer
  return $pairs
}

# How a stack name is written, for a refusal.
proc ::tclpdf::markdown::Spelling {name} {
  variable delimiters
  return [dict get $delimiters $name]
}

# The start of a line: a heading marker ("# " to "### "), a list item marker
# ("- ", "* ", "+ ", "1. " to "99. "), or neither. Answers 1 when it opened
# the paragraph the marker stands for, 0 when there is no marker and the
# caller reads on as usual.
proc ::tclpdf::markdown::LineMarker {text} {
  upvar 1 pairs pairs buffer buffer stack stack opened opened position position
  if {[regexp -start $position {\A(#+) } $text -> marker]} {
    set level [string length $marker]
    if {$level > 3} {
      return -code error -errorcode [list TCLPDF TEXT MARKDOWN HEADING $position] \
          "tclpdf: \"$marker \" at position $position is no heading - a heading\
          is \"# \", \"## \" or \"### \"; write \\# for a literal \"#\""
    }
    set names [list h$level]
    set what heading
  } elseif {[regexp -start $position {\A([-*+]|[0-9]{1,2}\.) } $text -> marker]} {
    # The kind comes from the marker; the number in front of the "." is
    # not kept - the setting counts the items.
    set names [expr {[string index $marker end] eq "." ? {ol li} : {ul li}}]
    set what "list item"
  } else {
    return 0
  }
  if {[llength $stack]} {
    set delimiter [Spelling [lindex $stack end 0]]
    return -code error -errorcode [list TCLPDF TEXT MARKDOWN NESTING $marker $position] \
        "tclpdf: the $what at position $position starts inside the\
        \"$delimiter\" opened at position [lindex $opened end] - a $what\
        is a paragraph, close the run first"
  }
  lassign [::tclpdf::markup::emit $pairs $buffer $stack] pairs buffer
  foreach name $names {
    lappend stack [list $name {}]
    lappend opened $position
  }
  incr position [expr {[string length $marker] + 1}]
  return 1
}

# A line feed. Inside a heading or a list item it is that paragraph's end,
# and its paragraph break goes out as a pair of its own - only where
# something follows, as behind </h1> and </ul>. Anywhere else it is text,
# and a paragraph break as such.
proc ::tclpdf::markdown::LineEnd {text} {
  variable lineBlocks
  upvar 1 pairs pairs buffer buffer stack stack opened opened position position
  set depth [llength [lmap entry $stack {
    if {[lindex $entry 0] ni $lineBlocks} continue
    set entry
  }]]
  if {!$depth} {
    append buffer "\n"
    incr position
    return
  }
  if {[llength $stack] > $depth} {
    set delimiter [Spelling [lindex $stack end 0]]
    set what [expr {[lindex $stack 0 0] in {ul ol} ? "list item" : "heading"}]
    return -code error -errorcode [list TCLPDF TEXT MARKDOWN NESTING $delimiter $position] \
        "tclpdf: the $what ends at position $position with the\
        \"$delimiter\" opened at position [lindex $opened end] still open -\
        close it on the $what's line"
  }
  lassign [::tclpdf::markup::emit $pairs $buffer $stack] pairs buffer
  set stack {}
  set opened {}
  incr position
  if {$position < [string length $text]} {
    lappend pairs "\n" {}
  }
  return
}

# A run of "*" or "~" at the current position: a closer, an opener, or text.
proc ::tclpdf::markdown::Delimiter {text} {
  variable runs
  upvar 1 pairs pairs buffer buffer stack stack opened opened position position
  regexp -start $position {\A(?:\*+|~+)} $text run
  if {![dict exists $runs $run]} {
    # "~", "~~~", "****" and longer: text.
    append buffer $run
    incr position [string length $run]
    return
  }
  set names [dict get $runs $run]
  set open {}
  foreach name $names {
    if {[lsearch -exact -index 0 $stack $name] >= 0} {
      lappend open $name
    }
  }
  if {[llength $open] == 1 && [llength $names] == 2} {
    # Three asterisks where one of the two kinds is open: this closes that
    # one, and the asterisks behind it are read again as a run of their own.
    set names $open
    set run [expr {$open eq "em" ? "*" : "**"}]
  }
  if {[llength $open]} {
    set count [llength $names]
    set innermost [lmap entry [lrange $stack end-[expr {$count - 1}] end] {
      lindex $entry 0
    }]
    if {[lsort $innermost] ne [lsort $names]} {
      set delimiter [Spelling [lindex $stack end 0]]
      return -code error -errorcode [list TCLPDF TEXT MARKDOWN NESTING $run $position] \
          "tclpdf: \"$run\" at position $position closes a run that is not\
          the innermost open one - the \"$delimiter\" opened at position\
          [lindex $opened end] is"
    }
    lassign [::tclpdf::markup::emit $pairs $buffer $stack] pairs buffer
    set stack [lrange $stack 0 end-$count]
    set opened [lrange $opened 0 end-$count]
    incr position [string length $run]
    return
  }
  set next [string index $text $position+[string length $run]]
  if {$next eq {} || [string is space $next]} {
    # "5 * 3", "a ** b", a delimiter at the very end: text.
    append buffer $run
    incr position [string length $run]
    return
  }
  lassign [::tclpdf::markup::emit $pairs $buffer $stack] pairs buffer
  foreach name $names {
    lappend stack [list $name {}]
    lappend opened $position
  }
  incr position [string length $run]
  return
}

# A "[": text, or a link. The address is read here, before the link text is
# - the pairs of the link text carry it, and they are emitted as the text
# goes along.
proc ::tclpdf::markdown::LinkOpen {text} {
  upvar 1 pairs pairs buffer buffer stack stack opened opened position position \
      linkEnd linkEnd linkResume linkResume
  set next [string index $text $position+1]
  if {$linkEnd >= 0 || $next eq {} || [string is space $next]
      || [string index $text $position-1] eq "!"} {
    # "[ ", a "[" at the very end, a "[" inside a link text, and the "["
    # of an image, "![alt](source)": text.
    append buffer "\["
    incr position
    return
  }
  set close [LinkBracket $text $position]
  if {$close < 0
      || ![regexp -start [expr {$close + 1}] {\A\(([^)]*)\)} $text whole href]
      || $href eq {} || [regexp {\s} $href]} {
    return -code error -errorcode [list TCLPDF TEXT MARKDOWN LINK $position] \
        "tclpdf: \"\[\" at position $position opens a link, which needs\
        \"](address)\" behind its text, with an address that is not empty\
        and holds no space; write \\\[ for a literal \"\[\""
  }
  lassign [::tclpdf::markup::emit $pairs $buffer $stack] pairs buffer
  lappend stack [list a $href]
  lappend opened $position
  set linkEnd $close
  set linkResume [expr {$close + 1 + [string length $whole]}]
  incr position
  return
}

# Where the "]" that ends the link text opened at "start" stands: the first
# one no backslash turns into text. -1 when there is none.
proc ::tclpdf::markdown::LinkBracket {text start} {
  variable escapable
  set length [string length $text]
  set index [expr {$start + 1}]
  while {$index < $length} {
    switch -- [string index $text $index] {
      "\\" {
        if {[string index $text $index+1] in $escapable} {
          incr index
        }
      }
      "\]" {
        return $index
      }
    }
    incr index
  }
  return -1
}

# The "]" of the open link: the link text goes out with the address, and
# reading goes on behind the ")".
proc ::tclpdf::markdown::LinkClose {} {
  upvar 1 pairs pairs buffer buffer stack stack opened opened position position \
      linkEnd linkEnd linkResume linkResume
  if {[lindex $stack end 0] ne "a"} {
    set delimiter [Spelling [lindex $stack end 0]]
    return -code error -errorcode [list TCLPDF TEXT MARKDOWN NESTING "\](" $position] \
        "tclpdf: the link text ends at position $position with the\
        \"$delimiter\" opened at position [lindex $opened end] still open -\
        close it inside the brackets"
  }
  lassign [::tclpdf::markup::emit $pairs $buffer $stack] pairs buffer
  set stack [lrange $stack 0 end-1]
  set opened [lrange $opened 0 end-1]
  set position $linkResume
  set linkEnd -1
  set linkResume -1
  return
}

package provide tclpdf::markdown 1.1
