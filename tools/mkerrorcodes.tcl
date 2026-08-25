#!/bin/sh
#\
exec tclsh "$0" "$@"

#
# tclpdf - PDF generation for Tcl
#
# mkerrorcodes - the "Every topic and its classes" table of the manual, made
# from the sources it describes.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   tclsh8.6 tools/mkerrorcodes.tcl           the table, on stdout
#   tclsh8.6 tools/mkerrorcodes.tcl --check   compare it with doc/tclpdf.md
#   tclsh8.6 tools/mkerrorcodes.tcl --update  write it into doc/tclpdf.md
#
# --check exits 1 on a difference and prints it line by line; that is what
# "make check" runs. --update rewrites the table in place and leaves the rest
# of the manual alone.
#
# WHY THIS FILE EXISTS. The manual says of that table: "This list is generated
# from the source rather than kept by hand". Until 2026-08-25 that sentence was
# true only of the two occasions somebody wrote a throwaway script for it - the
# script was never kept, and between those occasions the table was hand-kept
# after all. It had drifted by then: ten topics were missing classes and one
# topic, LAYOUT, was missing altogether. What is kept by hand drifts, which is
# the reason the table was generated in the first place.
#
# WHAT COUNTS AS A CODE. Every literal that stands in an -errorcode position:
#
#     -errorcode [list TCLPDF FIELD ALIGN $value]     834 places
#     -errorcode {TCLPDF COLORFONT ALIAS}             148 places
#     -errorcode \                                     34 places
#         [list TCLPDF STRUCTURE NAME duplicate name]
#
# All three are correct Tcl and all three are correct here: braces where no
# fact is substituted, [list] where one is, and the continuation wherever the
# message is too long for one line. They are NOT to be unified - but a reader
# of the sources has to see all three, and for a long time neither this table
# nor tests/errorcode.test did. A thousand and sixteen codes in all, counted
# 2026-08-25, beside the one deliberate TCL LOOKUP COMMAND in tclpdf.tcl.
#
# THE TREE is the one ::tclpdfTest::eachModule walks: every *.tcl beside the
# package, sorted, with the generated pkgIndex.tcl left out. Kept in step with
# that proc by hand, because a tool under tools/ may not depend on the test
# suite - "make check" runs both, and a shared helper would make each of them
# report the other's defect.
#

set here [file normalize [file dirname [info script]]]
set root [file dirname $here]
set manual [file join $root doc tclpdf.md]

# --- reading a module ------------------------------------------------------

# The source as LOGICAL lines: {number text}, comments dropped and every
# backslash continuation closed up into the line it belongs to.
#
# Comments are dropped because they QUOTE codes: afm.tcl says "Every refusal
# below carries -errorcode {TCLPDF FONT GLYPH codepoint ...}" in prose, and a
# scan that reads that line has invented a refusal. A comment runs on over a
# trailing backslash, so the skipping has to as well.
#
# The continuations are closed up because thirty-four refusals write
#
#     return -code error \
#         -errorcode [list TCLPDF STRUCTURE NAME duplicate name] \
#
# and the code is on the line BELOW the switch. Folding them one logical line
# at a time rather than over the whole file keeps the number of the line the
# fold started on, which is the number a reader is then given.
proc logicalLines {text} {
  set lines {}
  set comment 0
  set open {}
  set number 0
  set at 0
  foreach line [split $text \n] {
    incr number
    if {$open eq {} && !$comment
        && [string index [string trimleft $line] 0] eq "#"} {
      set comment 1
    }
    if {$comment} {
      set comment [string match {*\\} $line]
      continue
    }
    if {$open eq {}} {
      set at $number
    }
    append open [string trimright $line]
    if {[string match {*\\} $open]} {
      set open "[string range $open 0 end-1] "
      continue
    }
    lappend lines [list $at $open]
    set open {}
  }
  if {$open ne {}} {
    lappend lines [list $at $open]
  }
  return $lines
}

# Where the modules are, in the order eachModule walks them.
proc modules {root} {
  set paths {}
  foreach path [lsort [glob -directory $root *.tcl]] {
    if {[file tail $path] eq "pkgIndex.tcl"} {
      continue
    }
    lappend paths $path
  }
  return $paths
}

# One word of an -errorcode list, read the way Tcl reads it: brackets against
# brackets and braces against braces, so that a whole substitution counts as
# the single word it is. Returns {word next}, where next is the index just
# past the word; the word is empty when the list ends first, which is the
# answer to "does anything follow?".
#
# Needed because the class position is the one place in these lists where a
# substitution stands - [string toupper $option] - and reading it as three
# whitespace-separated pieces loses the two facts that matter: where the word
# ends, and what comes after it.
#
# The closer is "]" for a [list and "}" for a brace, and at depth zero it ends
# the code. Quoted strings are not treated specially: no -errorcode in this
# package puts a quote before the message, and a scan that tried would need a
# Tcl parser rather than a loop.
proc balancedWord {body index closer} {
  set length [string length $body]
  while {$index < $length
      && [string is space -strict [string index $body $index]]} {
    incr index
  }
  if {$index >= $length || [string index $body $index] eq $closer} {
    return [list {} $index]
  }
  set start $index
  set depth 0
  while {$index < $length} {
    set char [string index $body $index]
    if {$depth == 0
        && ($char eq $closer || [string is space -strict $char])} {
      break
    }
    switch -exact -- $char {
      {[} - "\{" {
        incr depth
      }
      {]} - "\}" {
        incr depth -1
        if {$depth < 0} {
          # A closer of the other kind at depth zero: the line is not
          # shaped like an -errorcode list after all, so the word ends
          # here rather than running to the end of the message.
          break
        }
      }
    }
    incr index
  }
  return [list [string range $body $start [expr {$index - 1}]] $index]
}

# --- the codes -------------------------------------------------------------
#
# topics(NAME)   the classes of that topic, in the order first seen
# computed(NAME) file:line of a code whose class position is not a literal
#                and is certainly a class position, because a further word
#                follows it
# unsure(NAME)   file:line of a code whose third word is not a literal and is
#                the LAST word - a computed class and a fact written after the
#                topic name look exactly alike there, see below
# foreign        codes whose first word is neither TCLPDF nor Tcl's own

array set topics {}
array set computed {}
array set unsure {}
set foreign {}

# The opener is either "[list " or "{"; after it come the first word and the
# topic, both of which are literals wherever this package raises a code.
#
# The class is deliberately NOT matched here. A regexp splits on whitespace,
# and a substituted class has whitespace inside it: "[string toupper $option]"
# is one word to Tcl and three to a regexp, so a pattern that reads three
# words cannot see where the class ends, let alone whether anything follows
# it. That question is what tells the two cases below apart, so the class is
# scanned off the body with [balancedWord] instead, from where the topic ends.
set pattern {-errorcode\s+(\[list\s+|\{)\s*([^\s\]\}]+)(?:\s+([^\s\]\}]+))?}

foreach path [modules $root] {
  set name [file tail $path]
  set channel [open $path]
  set text [read $channel]
  close $channel
  foreach entry [logicalLines $text] {
    lassign $entry line body
    # -- before the pattern: it begins with a dash, and regexp would
    # otherwise read it as an option of its own. -all -inline hands back
    # ONE flat list of every match and its groups rather than a list of
    # matches, so the loop takes four elements at a time. -indices,
    # because the class is scanned off the body from where the topic
    # ends, and only indices say where that is.
    foreach {whole opener first topic} \
        [regexp -all -inline -indices -- $pattern $body] {
      set word [string range $body {*}$first]
      if {$word ne "TCLPDF"} {
        # Tcl's own codes are not ours to document. tclpdf.tcl raises
        # one deliberately - an unknown subcommand answers in Tcl's
        # wording - and anything else is a defect that
        # tests/errorcode.test reports.
        if {$word ne "TCL"} {
          lappend foreign "$name:$line: $word"
        }
        continue
      }
      # A code of one word has no topic: the group did not take part and
      # its indices are -1. The scan for a class then starts behind the
      # first word, and finds the end of the list at once.
      set topicName {}
      set after [lindex $first 1]
      if {[lindex $topic 0] >= 0} {
        set topicName [string range $body {*}$topic]
        set after [lindex $topic 1]
      }
      if {![info exists topics($topicName)]} {
        set topics($topicName) {}
      }
      set closer "\}"
      if {[string index $body [lindex $opener 0]] eq {[}} {
        set closer {]}
      }
      lassign [balancedWord $body [expr {$after + 1}] $closer] class next
      if {[regexp {^[A-Z][A-Z0-9]*$} $class]} {
        if {$class ni $topics($topicName)} {
          lappend topics($topicName) $class
        }
        continue
      }
      if {$class eq {} || [string is alpha -strict $class]} {
        # Nothing there at all, or a word of plain letters: a fact
        # written after the topic name, readable as it stands.
        continue
      }
      # A substitution where a class would be. Two different things are
      # written that way, and what tells them apart is whether the list
      # goes on:
      #
      #   [list TCLPDF VERSION $version]                 a fact, right
      #   [list TCLPDF INITIALVIEW [string toupper $option] $value]
      #
      # In the second the substituted word cannot be a fact, because a
      # fact follows it - so it stood in the class position and no
      # reader of the source can name it. That is certain and is
      # reported whatever else the topic has.
      #
      # In the first the two cases coincide, and nothing in the source
      # can separate them; the topic is judged by what its OTHER codes
      # do, once every module has been read, so the place is remembered
      # here and judged in [complain].
      lassign [balancedWord $body $next $closer] follows
      if {$follows ne {}} {
        lappend computed($topicName) "$name:$line"
      } else {
        lappend unsure($topicName) "$name:$line"
      }
    }
  }
}

# --- the table -------------------------------------------------------------

# The rows, in the shape the manual carries them: the topic in code quotes, its
# classes in code quotes and alphabetical - alphabetical because the reader
# looks a class up rather than reading the row through, and because the order
# they happen to be raised in changes with every edit to a module.
proc table {} {
  global topics computed
  set rows {}
  lappend rows "| topic | classes |"
  lappend rows "| --- | --- |"
  foreach topic [lsort [array names topics]] {
    set classes $topics($topic)
    if {[llength $classes]} {
      set cell {}
      foreach class [lsort $classes] {
        lappend cell "`$class`"
      }
      set cell [join $cell { }]
    } elseif {[info exists computed($topic)]} {
      # No class this tool can read, but one it knows is there: a fact
      # follows the computed word, so the word was a class. Saying "the
      # facts follow the topic directly" here would be a plain untruth
      # about the code, which is worse than the gap the row admits to.
      set cell "the class is computed and cannot be named here"
    } else {
      set cell "the facts follow the topic directly"
    }
    lappend rows "| `$topic` | $cell |"
  }
  return $rows
}

# The table as it stands in the manual: the header row and every row that
# follows it without a gap. Found by the header rather than by a line number,
# and the section heading is named as well so that another table of the same
# two columns could never be mistaken for this one.
proc current {path} {
  set channel [open $path]
  set text [read $channel]
  close $channel
  set lines [split $text \n]
  set start -1
  set seen 0
  for {set index 0} {$index < [llength $lines]} {incr index} {
    set line [lindex $lines $index]
    if {[string match "*Every topic and its classes*" $line]} {
      set seen 1
    }
    if {$seen && [string trim $line] eq "| topic | classes |"} {
      set start $index
      break
    }
  }
  if {$start < 0} {
    return {}
  }
  set stop $start
  while {$stop + 1 < [llength $lines]
      && [string index [string trim [lindex $lines [expr {$stop + 1}]]] 0] eq "|"} {
    incr stop
  }
  return [list $start $stop [lrange $lines $start $stop]]
}

# --- what the run says -----------------------------------------------------

# The two things a reader has to be told whatever the mode, because neither
# shows up in the table itself: a code of a foreign shape, and a class this
# tool cannot name. Written to stderr so that the plain run stays a table.
proc complain {} {
  global foreign computed unsure topics
  foreach entry [lsort -unique $foreign] {
    puts stderr "mkerrorcodes: code with a foreign first word - $entry"
  }
  array set doubtful {}
  # Certain: a fact stands behind the computed word, so the word was a
  # class. Said whatever else the topic holds.
  foreach topic [array names computed] {
    lappend doubtful($topic) {*}$computed($topic)
  }
  # Uncertain: the computed word is the last in the list, where a class and a
  # fact written after the topic name look the same. THE DECISION, taken
  # 2026-08-26: a topic with no literal class anywhere is read as putting its
  # facts after its name, and a substitution there is exactly right - TCLPDF
  # VERSION $version, six places, the only shape of it in the tree. The topic
  # is only reported when it has literal classes elsewhere, because that is
  # the MIXTURE that cannot be read: a topic that has classes and computes
  # one of them keeps it out of this table, and out of the manual with it.
  #
  # Silence is the safe side here, not the convenient one: this tool gates
  # "make check", and a warning it raises over every correct TCLPDF VERSION
  # would be turned off within the week, taking the certain cases with it.
  # The case it lets past - a computed class as the last word of a topic that
  # has no other class - does not occur in the tree today, counted the same
  # day; should one be written, the row will say "the facts follow the topic
  # directly" and be wrong, and the sharper test above will not save it.
  foreach topic [array names unsure] {
    if {![llength $topics($topic)]} {
      continue
    }
    lappend doubtful($topic) {*}$unsure($topic)
  }
  foreach topic [lsort [array names doubtful]] {
    puts stderr "mkerrorcodes: $topic computes a class - not in the table:\
      [join [lsort -unique $doubtful($topic)] {, }]"
  }
}

# --- the modes -------------------------------------------------------------

set mode "--print"
if {[llength $argv]} {
  set mode [lindex $argv 0]
}
set rows [table]

switch -exact -- $mode {
  --print {
    complain
    puts [join $rows \n]
  }
  --check {
    complain
    set found [current $manual]
    if {![llength $found]} {
      puts stderr "mkerrorcodes: no table under \"Every topic and its\
        classes\" in $manual"
      exit 1
    }
    lassign $found start stop have
    if {$have eq $rows} {
      puts "the error code table in [file tail $manual] is the one the\
        source makes ([array size topics] topics)"
      exit 0
    }
    puts stderr "mkerrorcodes: the table in $manual is not the one the\
      source makes - run: tclsh8.6 tools/mkerrorcodes.tcl --update"
    # Line by line rather than as two blocks: what a reader needs is the
    # ROW that differs, and a whole-table dump buries it.
    foreach row $rows {
      if {$row ni $have} {
        puts stderr "  source has: $row"
      }
    }
    foreach row $have {
      if {$row ni $rows} {
        puts stderr "  manual has: $row"
      }
    }
    exit 1
  }
  --update {
    complain
    set found [current $manual]
    if {![llength $found]} {
      puts stderr "mkerrorcodes: no table under \"Every topic and its\
        classes\" in $manual"
      exit 1
    }
    lassign $found start stop have
    set channel [open $manual]
    set text [read $channel]
    close $channel
    set lines [split $text \n]
    set lines [lreplace $lines $start $stop {*}$rows]
    set channel [open $manual w]
    puts -nonewline $channel [join $lines \n]
    close $channel
    puts "[file tail $manual]: [llength $rows] lines of table,\
      [array size topics] topics"
  }
  default {
    puts stderr "usage: [file tail [info script]] \[--print|--check|--update\]"
    exit 1
  }
}
