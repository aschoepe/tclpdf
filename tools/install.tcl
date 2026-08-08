#!/bin/sh
#\
exec tclsh "$0" "$@"

#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# Installation helper for "make install".
#
# Usage: install.tcl <file|directory> ... <destdir>
#
# Why Tcl instead of "install -d" and "cp": the Makefile should be able to run
# the same line on every platform, including those that carry neither a BSD nor
# a GNU cp with the same switches (Windows). "file copy" and "file mkdir" behave
# identically everywhere - and "file copy" copies byte for byte, without a
# channel and without an encoding detour.
#
# A DIRECTORY argument keeps its name and is copied recursively - that is how
# icc/sRGB.icc arrives as icc/sRGB.icc rather than as sRGB.icc next to the Tcl
# modules. The package looks for it at [file join $dir icc sRGB.icc], so the
# level matters.
#

if {[llength $argv] < 2} {
  puts stderr "usage: [file tail [info script]] <file|directory> ... <destdir>"
  exit 1
}

set dest [lindex $argv end]
set sources [lrange $argv 0 end-1]

if {[catch {file mkdir $dest} err]} {
  puts stderr "install: destination directory $dest: $err"
  exit 1
}

# Copy a directory tree entry by entry. "file copy" would do it in one call,
# but it refuses when the target already exists - which it does on every
# reinstall.
proc copyTree {source target} {
  file mkdir $target
  set count 0
  foreach entry [glob -nocomplain -directory $source *] {
    set leaf [file join $target [file tail $entry]]
    if {[file isdirectory $entry]} {
      incr count [copyTree $entry $leaf]
    } else {
      file copy -force -- $entry $leaf
      incr count
    }
  }
  return $count
}

set errors 0
foreach source $sources {
  if {![file exists $source]} {
    puts stderr "install: $source is missing"
    incr errors
    continue
  }
  set target [file join $dest [file tail $source]]
  if {[file isdirectory $source]} {
    if {[catch {copyTree $source $target} result]} {
      puts stderr "install: $source -> $dest: $result"
      incr errors
      continue
    }
    puts "install: [file tail $source]/ -> $dest ($result file(s))"
  } else {
    if {[catch {file copy -force -- $source $target} err]} {
      puts stderr "install: $source -> $dest: $err"
      incr errors
      continue
    }
    puts "install: [file tail $source] -> $dest"
  }
}

exit [expr {$errors ? 1 : 0}]
