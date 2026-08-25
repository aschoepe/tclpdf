#
# tclpdf - PDF generation for Tcl
#
# layer - optional content (ISO 32000-2, 8.11)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Optional content is the mechanism behind what readers call layers: content
# that carries a name and can be shown or hidden, one group at a time. The
# pieces the standard gives it are an optional content group (/OCG) as the
# thing being switched, a /OCProperties entry in the catalogue listing every
# group and the default configuration, and a bracket in the content stream
# - /OC /name BDC ... EMC - or an /OC entry on an XObject saying which group
# a piece of drawing belongs to.
#
# Usage:
#
#   $doc layer create draft -title "Draft stamp" -visible 0
#   $doc layer draw draft -script {
#     $doc text "DRAFT" -at {60 150} -size 60 -color {0.9 0.85 0.85}
#   }
#   $doc layer state draft 1              ;# show it after all
#   $doc layer radio {german english}     ;# at most one of them on
#   $doc layer configure -title "Default view" -listMode VisiblePages
#
# THE API, AND WHY IT IS THIS ONE.
#
# A layer is DECLARED once and DRAWN INTO many times, so the two are two
# calls. [form create] has the same shape and for the same reason - the name
# is an alias in the caller's world, the resource name in the file is this
# module's business - and a caller who knows one knows the other: an alias
# first, options after, an unknown alias refused with the known ones listed.
#
# [layer draw ... -script] rather than a begin/end pair, exactly as
# [form create -script] and [structure -script] are scripts: a bracket that
# has to be closed by a second call is a bracket that one early [return]
# leaves open, and an unclosed BDC swallows every drawing that follows it
# (14.6.1). With the script the close is this module's job and happens even
# when the script fails - the error is then re-raised with its own stack, as
# [FormCreate] does. The script runs in the CALLER's frame rather than at
# global level - see [layer] below for the measurement that decided it.
#
# What a layer is NOT given here:
#
#   - an /OC entry on a form or image XObject (8.11.3.3). It would have to be
#     written into the XObject's dictionary, which is xObject.tcl's and
#     image.tcl's to write - a topic reaching into another topic, which this
#     package does not do. The bracket around the Do says the same thing
#     (8.11.3.2 gives it first), and it says it per PLACEMENT rather than
#     once for every placement there will ever be:
#         $doc layer draw draft -script { $doc form place logo -at {10 10} }
#   - an /OC entry on an annotation (12.5.3). Same reason, link.tcl's to
#     write, and there is no bracket that would stand in for it - a link
#     cannot be hidden with a layer here. Named rather than half-built.
#   - /AS and the usage dictionaries (8.11.4.4). ISO 19005-2/-3, 6.9 forbids
#     /AS in any configuration dictionary, so a PDF/A document may not have
#     it at all, and nothing here writes it - which is why no combination of
#     this module and [pdfa] has to be refused on that count.
#   - alternate configurations (/Configs). One default configuration is what
#     a document written from a script needs; a second one is a viewer
#     preset for a reader to switch to, and nothing here would fill it.
#
# HOW IT ATTACHES. Through the bus, not through the core: [onSelf catalog]
# for /OCProperties and the resource category Properties for the names the
# stream uses - the arrangement attach.tcl and pdfa.tcl use. The core knows
# one line about this module, the topic table entry in document.tcl.
#
# THE IMPORT SEAM. import.tcl carries the /OCProperties of a FOREIGN page
# into the catalogue when that page had layers, and it merges with what is
# already there by reading the entry back with its own parser. This module
# therefore does two things: it builds its entry on the catalog event, which
# is after every import, and it reads the groups already in the entry out of
# it and carries them along - into /OCGs, into /Order, and into /ON or /OFF
# according to the state that same entry gives them, which is the state they
# had in the file they were imported from. So the two are not two writers
# fighting over one key: whoever writes last has both halves. Measured
# (2026-08-21): a document with one layer of its own that imports a page
# with two foreign ones writes /OCGs with all three, and a write, then a
# further import, then a second write comes out with all three again - the
# import's reduced entry is the input of the next catalog run and is rebuilt
# from it.
#
# A document that imports layers and declares NONE of its own never reaches
# this module at all - nothing hooks it onto the catalog event then - which
# is why the entry import.tcl writes has to be conforming on its own, /Name
# included. It is (measured 2026-08-22 with veraPDF: 6.9-1 passes on a
# PDF/A-3B document whose only layers are imported ones).
#
# PDF/A. ISO 19005-2 and -3 have four requirements in clause 6.9 (NOT 6.1.13,
# which is the implementation limits), and veraPDF spells them out:
#
#   6.9-1  every configuration dictionary shall have a /Name, non-empty
#   6.9-2  that /Name shall be unique among all configuration dictionaries
#   6.9-3  where /Order is present it shall reference ALL the OCGs in the file
#   6.9-4  /AS shall not appear in any configuration dictionary
#
# All four are met by construction: /Name is always written and an empty one
# is refused at [layer configure]; there is one configuration dictionary and
# no /Configs, so its name is unique; /Order is built from the same list as
# /OCGs, the imported groups included; /AS is never written. Measured with
# veraPDF 1.30 - a PDF/A-3B document with two layers, one of them off, and a
# radio group: 0 failed checks.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::layer {
  # Table 96: the two intents the standard names. It also admits "any
  # second-class name", which is an extension mechanism (Annex E) nothing
  # here produces - a typed word that no reader knows would switch nothing
  # and say nothing, so it is refused where it is written.
  #
  # The trap in the entry, worth knowing before reaching for it: a
  # configuration considers only the groups whose intent it shares, and the
  # default configuration's intent is View (Table 99). A group created with
  # -intent Design alone is therefore NOT switched by the configuration this
  # module writes - its content stays visible whatever the panel says. That
  # is what the standard prescribes, so it is documented rather than
  # prevented; a layer meant to be switched wants View, which is the default
  # when -intent is not given at all.
  variable intents {View Design}

  # Table 99, /ListMode.
  variable listModes {AllPages VisiblePages}
}

# The indirect references in one array of an optional content properties
# dictionary - /OCGs, every group in the file, or /OFF, the ones that start
# out switched off - as PDF syntax ("5 0 R"), or {} when there is no such
# array.
#
# This reads back what import.tcl put into the catalogue - and what this
# module itself put there on an earlier write. A full parser is not needed
# and would be the wrong tool: the entry has exactly two producers and both
# write one flat array of references per key, so what is wanted is the first
# bracketed list after that key. import.tcl has a real parser for the same
# job and cannot be borrowed - a topic does not require another topic -
# which is why this is the small half of the question rather than a copy of
# the large one.
#
# "The first list after the key" is safe because both producers write the
# configuration's /Name last: it is the one value in the entry that a caller
# dictates, and a title reading "/OFF [4 0 R]" in front of the real array
# would be taken for it.
proc ::tclpdf::layer::groupReferences {entry {key OCGs}} {
  set at [string first /$key $entry]
  if {$at < 0} {
    return {}
  }
  set open [string first \[ $entry $at]
  if {$open < 0} {
    return {}
  }
  set close [string first \] $entry $open]
  if {$close < 0} {
    return {}
  }
  set result {}
  foreach reference [regexp -all -inline {\d+\s+\d+\s+R} \
      [string range $entry $open $close]] {
    # Spelled the way [writer ref] spells it, so that the references can be
    # compared as strings against this module's own.
    lappend result [join [regexp -all -inline {\S+} $reference] " "]
  }
  return $result
}

oo::define ::tclpdf::document::document {

  # $doc layer create <name> ?-title text? ?-visible 0? ?-intent View?
  # $doc layer draw   <name> -script {...}
  # $doc layer names
  # $doc layer state  <name> ?0|1?
  # $doc layer radio  {name name ...}
  # $doc layer configure ?-title text? ?-listMode AllPages?
  method layer {subcommand args} {
    switch -- $subcommand {
      create {return [my LayerCreate {*}$args]}
      draw {
        # The frame the -script has to run in, taken HERE and handed on.
        #
        # It is the CALLER's, not the global one: a script that says $doc
        # where $doc is a local variable of the proc around it must work, and
        # with "uplevel #0" it does not. Measured 2026-08-21 under both
        # interpreters: inside a proc holding its document in a local
        # variable, [structure -script] draws and [form create -script]
        # answers 'can't read "doc": no such variable' - the two spellings
        # disagree, and the second is the one nobody would choose on purpose.
        # Taken at the public entry because a private method is one frame
        # further in, and the number would then depend on the road taken.
        return [my LayerDraw [expr {[info level] - 1}] {*}$args]
      }
      names {return [dict keys [my state layers]]}
      state {return [my LayerVisible {*}$args]}
      radio {return [my LayerRadio {*}$args]}
      configure {return [my LayerConfigure {*}$args]}
      default {
        return -code error -errorcode [list TCLPDF LAYER SUBCOMMAND $subcommand] \
            "tclpdf: unknown layer subcommand \"$subcommand\" -\
            known are: create, draw, names, state, radio, configure"
      }
    }
  }

  # Declare a group. The object is written HERE and once - an OCG dictionary
  # is three fixed entries and nothing about it changes later, so it needs no
  # [reservation] and no rebuild per write. What does change - which groups
  # are on, which are in a radio set - lives in the configuration dictionary,
  # and that one IS rebuilt on every catalog event.
  method LayerCreate {name args} {
    set options [::tclpdf::option parse {title {} visible 1 intent {}} $args \
        "layer create"]
    if {$name eq {}} {
      return -code error -errorcode [list TCLPDF LAYER ARGUMENT name] \
          "tclpdf: layer create needs a name"
    }
    set layers [my state layers]
    if {[dict exists $layers $name]} {
      return -code error -errorcode [list TCLPDF LAYER NAME $name] \
          "tclpdf: a layer named \"$name\" already exists"
    }
    if {![string is boolean -strict [dict get $options visible]]} {
      return -code error -errorcode [list TCLPDF LAYER ARGUMENT visible] \
          "tclpdf: -visible of layer create is a boolean, not\
          \"[dict get $options visible]\""
    }
    variable ::tclpdf::layer::intents
    set intent [dict get $options intent]
    foreach word $intent {
      if {$word ni $intents} {
        return -code error -errorcode [list TCLPDF LAYER ARGUMENT intent] \
            "tclpdf: -intent of layer create is\
            [join $intents { or }], or both (ISO 32000-2, Table 96), not\
            \"$word\""
      }
    }
    # The title is what a reader shows in its layer panel, and a layer with
    # no title is a row a user cannot tell from the next one. The alias is
    # the caller's own word for the same thing, so it stands in - rather than
    # a /Name the standard permits to be empty and nobody can act on.
    set title [dict get $options title]
    if {$title eq {}} {
      set title $name
    }
    # Optional content is PDF 1.5 (ISO 32000-1, Table 28 - /OCProperties).
    # A document set to an older version is told so here, at the call that
    # wanted it, rather than writing a catalogue key the header disowns.
    my RequireVersion 1.5 "layer"
    set writer [my writer]
    set pairs [list Type /OCG Name [my Str $title]]
    if {[llength $intent] == 1} {
      lappend pairs Intent [::tclpdf::pdfObj name [lindex $intent 0]]
    } elseif {[llength $intent] > 1} {
      lappend pairs Intent [::tclpdf::pdfObj arr [lmap word $intent {
        ::tclpdf::pdfObj name $word
      }]]
    }
    set number [$writer add [::tclpdf::pdfObj dictionary $pairs]]

    # The name the content stream uses. It has to be a resource in the
    # Properties subdictionary (8.11.3.2, 14.6.2), and the resource
    # dictionary is the document's shared one - which is why a bracket works
    # inside a form XObject and inside a tiling pattern as well: both point
    # their /Resources at that same object.
    set count [my state layerCount]
    if {$count eq {}} {
      set count 0
    }
    my state layerCount [incr count]
    set resource OC$count
    my resource Properties $resource [$writer ref $number]

    dict set layers $name [dict create number $number resource $resource \
        title $title intent $intent \
        visible [expr {[dict get $options visible] ? 1 : 0}]]
    my state layers $layers
    if {[my state layerHooked] eq {}} {
      my state layerHooked 1
      my onSelf catalog LayerCatalog
    }
    return $name
  }

  # Put what the script draws into the group.
  #
  # The bracket has to open and close in ONE content stream (8.11.3.2 lists
  # the streams it may sit in; each of them is one). Both ways out of that
  # are checked after the script and named: a script that added a page has
  # its EMC written on the page the BDC is on, so the file stays well formed,
  # and then says so - the content after the page break was NOT in the layer,
  # and silence about that is a document that looks right and is not.
  #
  # An empty script writes nothing at all, and SO DOES A MISSING ONE - the
  # two are the same call, deliberately, and [layer draw draft] on its own is
  # a no-op that answers the layer's name. "/OC /OC1 BDC EMC" around nothing
  # is a bracket with no content, which is what the standard's DP operator
  # exists for; writing it as an empty pair instead is the defect this
  # package has already paid for twice, in the type area and in the text
  # block. Refusing the missing -script instead would buy nothing: the alias
  # is checked either way, so the typo that matters - a layer that does not
  # exist - is still refused by name, and the precedent in this package is
  # [form create], where an empty -script is a form with no content and said
  # so in as many words.
  method LayerDraw {level name args} {
    set options [::tclpdf::option parse {script {}} $args "layer draw"]
    set record [my LayerRecord $name]
    if {[string trim [dict get $options script]] eq {}} {
      return $name
    }
    # The stream the bracket begins in: the top canvas while a form or a tile
    # is being built, the current page otherwise. [PageIndex] refuses a
    # document with no page here, before anything is written.
    set depth [my canvas depth]
    set page [expr {$depth ? {} : [my PageIndex {}]}]
    my content "/OC [::tclpdf::pdfObj name [dict get $record resource]] BDC\n"
    set failed [catch {uplevel #$level [dict get $options script]} result info]
    # BOTH ways out close the bracket, which is what this method exists for -
    # the refusal below used to be written BEFORE the EMC and left the BDC
    # standing, and an unclosed BDC swallows every drawing that follows it.
    # A drawing surface the script pushed and did not pop is popped here:
    # what it collected goes nowhere in any case (nothing will ever finish
    # that form), and while it is on the stack it is where [content] writes,
    # so the EMC would land in it instead of in the stream the BDC is in.
    # A script that popped the surface the bracket began in cannot be helped
    # that way - that stream is gone, and writing the EMC into whatever is
    # current now would close a bracket in a stream that never opened one.
    set escaped [expr {[my canvas depth] != $depth}]
    while {[my canvas depth] > $depth} {
      my canvas pop
    }
    set now [expr {$depth ? {} : [my PageIndex {}]}]
    if {[my canvas depth] == $depth} {
      my content "EMC\n" $page
    }
    if {$escaped} {
      return -code error -errorcode [list TCLPDF LAYER SCRIPT $name] \
          "tclpdf: the -script of layer \"$name\" left the\
          content stream it began in - a /OC bracket opens and closes in one\
          stream (ISO 32000-2, 8.11.3.2)"
    }
    if {$failed} {
      return -options $info $result
    }
    if {$now ne $page} {
      return -code error -errorcode [list TCLPDF LAYER SCRIPT $name] \
          "tclpdf: the -script of layer \"$name\" added a page\
          - a /OC bracket opens and closes on one page (ISO 32000-2,\
          8.11.3.2), so what was drawn after the break is not in the layer;\
          draw one bracket per page"
    }
    return $name
  }

  # Whether the group starts out visible - read with no value, set with one.
  # It is a property of the CONFIGURATION, not of the group (Table 99), which
  # is why it can still be changed after the group has been drawn into.
  method LayerVisible {name args} {
    my LayerRecord $name
    set layers [my state layers]
    if {![llength $args]} {
      return [dict get $layers $name visible]
    }
    if {[llength $args] > 1} {
      return -code error -errorcode [list TCLPDF LAYER STATE arguments] \
          "tclpdf: layer state takes a name and at most one\
          value"
    }
    set value [lindex $args 0]
    if {![string is boolean -strict $value]} {
      return -code error -errorcode [list TCLPDF LAYER STATE value] \
          "tclpdf: layer state takes a boolean, not \"$value\""
    }
    dict set layers $name visible [expr {$value ? 1 : 0}]
    my state layers $layers
    if {[dict get $layers $name visible]} {
      my LayerExclusive $name
    }
    return [dict get $layers $name visible]
  }

  # A set of groups of which at most one is on at a time - /RBGroups, the
  # radio button paradigm of Table 99. The typical use is one language per
  # layer.
  method LayerRadio {members} {
    if {[llength $members] < 2} {
      return -code error -errorcode [list TCLPDF LAYER RADIO members] \
          "tclpdf: layer radio takes two or more layer names -\
          a radio group of one switches nothing (ISO 32000-2, Table 99), got\
          \"$members\""
    }
    set seen {}
    foreach name $members {
      my LayerRecord $name
      if {[dict exists $seen $name]} {
        return -code error -errorcode [list TCLPDF LAYER RADIO $name] \
            "tclpdf: layer \"$name\" appears twice in the same\
            radio group"
      }
      dict set seen $name 1
    }
    set groups [my state layerRadio]
    lappend groups $members
    my state layerRadio $groups
    # "Mutually exclusive" is a statement about the STATE as well as about
    # the switching (Table 99): a configuration whose /ON array holds two
    # members of one radio set describes a state the reader it is written
    # for cannot produce. Two layers created without -visible 0 - which is
    # the default and the usual way a language pair is declared - were
    # exactly that. So the set is made exclusive here, at the call that
    # declares it: the FIRST member that is on stays on, the rest go off,
    # and [layer state] reports what the file will say rather than something
    # the write silently corrects.
    set layers [my state layers]
    foreach name $members {
      if {[dict get $layers $name visible]} {
        my LayerExclusive $name
        break
      }
    }
    return $members
  }

  # Switch off every OTHER member of every radio group this layer is in -
  # the one place the exclusivity is enforced, called from where a group is
  # declared and from where a member is switched on.
  method LayerExclusive {name} {
    set layers [my state layers]
    set changed 0
    foreach group [my state layerRadio] {
      if {$name ni $group} continue
      foreach member $group {
        if {$member eq $name || ![dict get $layers $member visible]} continue
        dict set layers $member visible 0
        set changed 1
      }
    }
    if {$changed} {
      my state layers $layers
    }
    return
  }

  # The default configuration dictionary's own settings. Read with no
  # arguments - which is also how [LayerCatalog] asks for them, so the
  # defaults exist in one place rather than one here and one there.
  method LayerConfigure {args} {
    set current [my state layerConfig]
    if {$current eq {}} {
      set current [dict create title Default listMode {}]
    }
    if {![llength $args]} {
      return $current
    }
    set options [::tclpdf::option parse $current $args "layer configure"]
    # ISO 19005-2 and -3, 6.9: every configuration dictionary shall have a
    # /Name. Refused rather than written empty, because an empty one fails
    # veraPDF check 6.9-1 and there is nothing a reader could show for it.
    if {[dict get $options title] eq {}} {
      return -code error -errorcode [list TCLPDF LAYER CONFIGURE title] \
          "tclpdf: -title of layer configure is the /Name of\
          the default configuration and may not be empty - ISO 19005-2/-3,\
          6.9 requires it on every optional content configuration dictionary"
    }
    variable ::tclpdf::layer::listModes
    if {[dict get $options listMode] ne {}
        && [dict get $options listMode] ni $listModes} {
      return -code error -errorcode [list TCLPDF LAYER CONFIGURE listMode] \
          "tclpdf: -listMode of layer configure is\
          [join $listModes { or }] (ISO 32000-2, Table 99), not\
          \"[dict get $options listMode]\""
    }
    my state layerConfig $options
    return $options
  }

  # One lookup, one wording: [form place]'s, because a caller who mistyped an
  # alias needs the list of the ones that exist.
  method LayerRecord {name} {
    set layers [my state layers]
    if {![dict exists $layers $name]} {
      return -code error -errorcode [list TCLPDF LAYER NAME $name] \
          "tclpdf: no layer named \"$name\" - known are:\
          [join [dict keys $layers] {, }]"
    }
    return [dict get $layers $name]
  }

  # /OCProperties (Table 98). Runs on the catalog event, which is after every
  # import, and it is idempotent: it creates nothing, it only rewrites one
  # catalogue key out of the state and out of whatever is in that key already
  # - see the head of this file for the import seam.
  method LayerCatalog {} {
    set layers [my state layers]
    if {![dict size $layers]} {
      return
    }
    set writer [my writer]
    set mine {}
    set on {}
    set off {}
    dict for {name record} $layers {
      set reference [$writer ref [dict get $record number]]
      lappend mine $reference
      if {[dict get $record visible]} {
        lappend on $reference
      } else {
        lappend off $reference
      }
    }
    # The groups an import brought. They keep the state THE FILE THEY CAME
    # FROM gave them: import.tcl reads that file's default configuration and
    # writes the result into this entry, and the entry is where it is read
    # back from here - the same seam the /OCGs array travels over, for the
    # same reason (see the head of this file). A group the entry does not
    # name as off is on, which is what a group is unless a configuration
    # says otherwise (Table 99, /BaseState).
    #
    # They go into /Order as well - /Order must list every group in the file
    # or a PDF/A validator reports it (veraPDF 6.9-3), and a group missing
    # from /Order is one no reader offers to switch.
    set entry [my catalogEntry OCProperties]
    set hidden [::tclpdf::layer::groupReferences $entry OFF]
    set foreign {}
    foreach reference [::tclpdf::layer::groupReferences $entry] {
      if {$reference in $mine} continue
      lappend foreign $reference
      if {$reference in $hidden} {
        lappend off $reference
        continue
      }
      lappend on $reference
    }
    set all [concat $mine $foreign]

    set config [my LayerConfigure]
    set pairs [list Order [::tclpdf::pdfObj arr $all] \
        ON [::tclpdf::pdfObj arr $on]]
    if {[llength $off]} {
      lappend pairs OFF [::tclpdf::pdfObj arr $off]
    }
    set radio {}
    foreach group [my state layerRadio] {
      lappend radio [::tclpdf::pdfObj arr [lmap name $group {
        $writer ref [dict get $layers $name number]
      }]]
    }
    if {[llength $radio]} {
      lappend pairs RBGroups [::tclpdf::pdfObj arr $radio]
    }
    if {[dict get $config listMode] ne {}} {
      lappend pairs ListMode [::tclpdf::pdfObj name [dict get $config listMode]]
    }
    # The /Name goes LAST - import.tcl writes it last as well, and the
    # comment there says why: it is the one value in the configuration a
    # caller dictates, and [groupReferences] takes the first /OCGs and the
    # first /OFF it finds. A title reading "/OFF [4 0 R]" in front of them
    # would be read as one of them.
    lappend pairs Name [my Str [dict get $config title]]
    # No /BaseState: its default is ON, /ON and /OFF are written out in full,
    # and Table 99 permits the value ON alone in the default configuration
    # anyway - a key that may only ever hold its own default is one to leave
    # out. No /AS either, ever (ISO 19005-2/-3, 6.9).
    my catalogEntry OCProperties [::tclpdf::pdfObj dictionary [list \
        OCGs [::tclpdf::pdfObj arr $all] \
        D [::tclpdf::pdfObj dictionary $pairs]]]
    return
  }
}

package provide tclpdf::layer 1.2
