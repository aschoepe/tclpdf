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
# "file copy" also carries the mode of the source over, and the source is a
# working checkout whose files may be private to their owner. Measured on
# 2026-11-25: 37 of the 108 modules were 0600, they arrived as 0600, and
# Apache with mod_websh, running as another user, could not load the package
# until a chmod 644. Every file put down is therefore set to u=rw,go=r and
# every directory to u=rwx,go=rx afterwards - written symbolically, because
# "file attributes -permissions" answers 00644 under Tcl 8.6 and 0o644 under
# 9.0, and the symbolic form says the same on both without a number in
# between. Only the destination and what lands in it are touched; its
# parents, even those "file mkdir" makes on the way, keep their modes.
#

if {[llength $argv] < 2} {
  puts stderr "usage: [file tail [info script]] <file|directory> ... <destdir>"
  exit 1
}

# The mode an installed file or directory gets, set on the copy only. A link
# is left alone: its permissions are those of the file it points to, which
# may lie outside the destination. Windows has no -permissions attribute and
# no use for one here.
proc release {path} {
  if {$::tcl_platform(platform) ne "unix"} {
    return
  }
  switch -- [file type $path] {
    file      { file attributes $path -permissions u=rw,go=r }
    directory { file attributes $path -permissions u=rwx,go=rx }
  }
}

set dest [lindex $argv end]
set sources [lrange $argv 0 end-1]

if {[catch {file mkdir $dest; release $dest} err]} {
  puts stderr "install: destination directory $dest: $err"
  exit 1
}

# Copy a directory tree entry by entry. "file copy" would do it in one call,
# but it refuses when the target already exists - which it does on every
# reinstall.
proc copyTree {source target} {
  file mkdir $target
  release $target
  set count 0
  foreach entry [glob -nocomplain -directory $source *] {
    set leaf [file join $target [file tail $entry]]
    if {[file isdirectory $entry]} {
      incr count [copyTree $entry $leaf]
    } else {
      file copy -force -- $entry $leaf
      release $leaf
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
    if {[catch {file copy -force -- $source $target; release $target} err]} {
      puts stderr "install: $source -> $dest: $err"
      incr errors
      continue
    }
    puts "install: [file tail $source] -> $dest"
  }
}

exit [expr {$errors ? 1 : 0}]
