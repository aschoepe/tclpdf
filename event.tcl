#
# tclpdf - PDF generation for Tcl
#
# event - the hook points a document offers while it is being written
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# This is the one decision that cannot be retrofitted. Attachments, ZUGFeRD,
# XMP metadata and later the PDF/A output intent all need to add objects of
# their own and to write keys into the catalog - and none of them may require
# an edit inside the document core to do it. A feature that has to patch the
# core to attach itself is designed wrong - it ends in plugins reaching into
# an object marked internal, and every one of them breaks on the next change.
#
# So the document is an emitter and those features are subscribers. The class
# here holds no PDF knowledge at all - which event names exist is decided by
# the document, not here.
#
# ONE CONTRACT COMES WITH SUBSCRIBING: the write-time events (beforeWrite,
# resources, catalog, info) fire on EVERY write, and a document may be written
# more than once. A subscriber that creates objects must therefore be
# idempotent - reserve its object numbers once, through the document's
# [reservation], and write over them on later runs. One that reserves fresh
# numbers per run grows the file with every write and leaves the earlier
# objects unreachable; nothing reports that, the file merely gets larger.
#

package require Tcl 8.6.11-
# Unlike zlib, TclOO really is a package in both interpreters - measured, 1.1.0
# under 8.6.18 and 1.3.1 under 9.0.4. So requesting it is safe here and states
# the dependency; the zlib rule does not apply.
package require TclOO

namespace eval ::tclpdf::event {}

# Inherited by the document rather than mixed in at run time: a document is an
# emitter from the moment it exists, and a subscriber must not have to wait for
# a mixin to be applied.
oo::class create ::tclpdf::event::emitter {
  variable tclpdfSubscribers tclpdfNextToken

  # Takes no arguments: a subclass calls [next] without any and keeps its own.
  constructor {} {
    set tclpdfSubscribers {}
    set tclpdfNextToken 0
  }

  # Subscribe to an event. The script is a command prefix; it is called with
  # the emitting object followed by whatever the emitter passes on, so a
  # subscriber never has to capture the object from its surroundings.
  #
  # Returns a token for [off]. Subscribers run in registration order.
  method on {event script} {
    if {$script eq {}} {
      return -code error "tclpdf: empty callback for event \"$event\""
    }
    set token e[incr tclpdfNextToken]
    dict lappend tclpdfSubscribers $event [list $token $script]
    return $token
  }

  # Remove a subscription. Unknown tokens are silently accepted: unsubscribing
  # twice is not an error worth stopping a document over.
  method off {token} {
    dict for {event entries} $tclpdfSubscribers {
      set kept {}
      foreach entry $entries {
        if {[lindex $entry 0] ne $token} {
          lappend kept $entry
        }
      }
      if {[llength $kept]} {
        dict set tclpdfSubscribers $event $kept
      } else {
        dict unset tclpdfSubscribers $event
      }
    }
    return
  }

  # Fire an event and return how many subscribers ran.
  #
  # Errors are deliberately NOT caught. A ZUGFeRD attachment that fails
  # silently produces an invoice that passes every validator and carries no
  # invoice data - the failure has to reach the caller.
  method emit {event args} {
    if {![dict exists $tclpdfSubscribers $event]} {
      return 0
    }
    set count 0
    # Iterate over a copy: a subscriber may legitimately subscribe or
    # unsubscribe while the event is running.
    foreach entry [dict get $tclpdfSubscribers $event] {
      uplevel #0 [list {*}[lindex $entry 1] [self] {*}$args]
      incr count
    }
    return $count
  }

  # Which events currently have subscribers - for tests and for diagnostics.
  method subscribers {{event {}}} {
    if {$event eq {}} {
      return [dict keys $tclpdfSubscribers]
    }
    if {![dict exists $tclpdfSubscribers $event]} {
      return {}
    }
    return [lmap entry [dict get $tclpdfSubscribers $event] {lindex $entry 0}]
  }
}

package provide tclpdf::event 1.1
