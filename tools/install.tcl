#!/bin/sh
#\
exec tclsh "$0" "$@"

#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# Installation helper for "make install".
#
# Usage: install.tcl <file> ... <destdir>
#
# Why Tcl instead of "install -d" and "cp": the Makefile should be able to run
# the same line on every platform, including those that carry neither a BSD nor
# a GNU cp with the same switches (Windows). "file copy" and "file mkdir" behave
# identically everywhere - and "file copy" copies byte for byte, without a
# channel and without an encoding detour.
#

if {[llength $argv] < 2} {
  puts stderr "usage: [file tail [info script]] <file> ... <destdir>"
  exit 1
}

set dest [lindex $argv end]
set files [lrange $argv 0 end-1]

if {[catch {file mkdir $dest} err]} {
  puts stderr "install: destination directory $dest: $err"
  exit 1
}

set errors 0
foreach f $files {
  if {![file exists $f]} {
    puts stderr "install: $f is missing"
    incr errors
    continue
  }
  if {[catch {file copy -force -- $f [file join $dest [file tail $f]]} err]} {
    puts stderr "install: $f -> $dest: $err"
    incr errors
    continue
  }
  puts "install: [file tail $f] -> $dest"
}

exit [expr {$errors ? 1 : 0}]
