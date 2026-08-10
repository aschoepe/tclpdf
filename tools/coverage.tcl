#!/usr/bin/env tclsh
#
# tclpdf - PDF generation for Tcl
#
# coverage - which document methods does anything actually call?
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A TclOO FILTER on the document class sees every method call - private ones
# and lazily loaded ones included, which no static scan of the sources can do.
# Run the whole test suite and every example through it and what is left over
# is the code nothing exercises.
#
# That list is worth having. Measured on 2026-08-10 it held eight methods, and
# every defect found in the review that day sat in one of them: four documented
# call forms that did not exist, a colour operator with too few operands, a
# table border that silently drew nothing. Untested is where defects live, and
# this says exactly where untested is.
#
#   tclsh8.6 tools/coverage.tcl            everything, with a report
#   tclsh8.6 tools/coverage.tcl <script>   one script, machine readable
#
# Method coverage is the WEAKEST measure there is - it says "entered once",
# nothing about branches. Read it as a floor, not as a result.

set here [file normalize [file dirname [info script]]]
set root [file dirname $here]

# --- the measuring run -----------------------------------------------------
#
# One child process per script: the examples set global variables and would
# otherwise overwrite each other's state, and a single failing one would take
# the whole measurement with it.

if {[llength $argv] == 2} {
  lassign $argv target scratch

  lappend auto_path $root
  package require tclpdf
  # Load every topic up front, so a method missing from the report is one
  # nothing called - not one whose module was never loaded.
  foreach package [package names] {
    if {[string match tclpdf::* $package]} {
      catch {package require $package}
    }
  }

  array set tclpdfSeen {}
  oo::define ::tclpdf::document::document {
    method TclpdfCoverage {args} {
      if {![catch {lindex [self target] 1} method] && $method ne {}} {
        set ::tclpdfSeen($method) 1
      }
      return [next {*}$args]
    }
    filter TclpdfCoverage
  }

  proc tclpdfReport {} {
    foreach method [lsort [array names ::tclpdfSeen]] {
      puts stdout "CALLED $method"
    }
    foreach method [lsort [info class methods \
        ::tclpdf::document::document -all -private]] {
      puts stdout "EXISTS $method"
    }
  }

  # tcltest calls [exit], which would skip the report.
  rename exit tclpdfExit
  proc exit {{code 0}} {
    tclpdfReport
    tclpdfExit $code
  }

  # An example writes to its first argument and, without one, into the CURRENT
  # DIRECTORY - which is the project root here. Left unset, a coverage run
  # scattered twenty PDFs among the sources, where "fossil extras" then listed
  # them as files waiting to be added. A measuring tool must not change what it
  # measures.
  #
  # The test suite is the other way round: all.tcl hands its argv straight to
  # [tcltest::configure], so a file name there makes the whole run fail - and
  # it fails QUIETLY, because this driver only reads the report. That is how
  # the first version reported five methods as uncalled that are covered.
  if {[file tail $target] eq "all.tcl"} {
    set argv {}
    set argc 0
  } else {
    set argv [list [file join $scratch [file rootname [file tail $target]].pdf]]
    set argc 1
  }
  set argv0 $target
  set failed [catch {source $target} error]
  tclpdfReport
  if {$failed} {
    puts stderr "coverage: $target failed: $error"
  }
  return
}

# --- the driver ------------------------------------------------------------

set scripts [lsort [glob -nocomplain [file join $root examples *.tcl]]]
set scripts [lsearch -all -inline -not $scripts [file join $root examples common.tcl]]
lappend scripts [file join $root tests all.tcl]

set scratch [file normalize [file join / tmp tclpdf-coverage-[pid]]]
file mkdir $scratch

array set called {}
array set exists {}
foreach script $scripts {
  set channel [open [list |[info nameofexecutable] [info script] \
      $script $scratch 2>@1] r]
  foreach line [split [read $channel] \n] {
    if {[regexp {^CALLED (.*)$} $line -> method]} {
      set called($method) 1
    } elseif {[regexp {^EXISTS (.*)$} $line -> method]} {
      set exists($method) 1
    }
  }
  catch {close $channel}
  puts stderr "  [file tail $script]"
}

# Methods TclOO brings along are not ours to cover.
file delete -force $scratch

set inherited {<cloned> destroy eval unknown varname variable}
set missing {}
foreach method [lsort [array names exists]] {
  if {$method in $inherited || [string match Tclpdf* $method]} {
    continue
  }
  if {![info exists called($method)]} {
    lappend missing $method
  }
}

set total [expr {[llength [array names exists]] - [llength $inherited]}]
puts ""
puts "[array size called] of $total methods called"
if {[llength $missing]} {
    puts "\nnever called:"
    foreach method $missing {
      puts "  $method"
    }
} else {
  puts "\nnothing uncalled."
}
