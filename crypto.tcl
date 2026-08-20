#
# tclpdf - PDF generation for Tcl
#
# crypto - the primitives the standard security handler needs: AES-256,
# SHA-2 and a source of random bytes, in pure Tcl (Etappe 8)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Why the wheel is reinvented here: the core runs on a bare Tcl installation
# (FEATURES 11). tcllib has "aes" and "sha256", but tcllib is not installed
# under every interpreter this package must run on, and TclTLS - measured on
# 2026-08-09 - offers socket TLS only: there is no tls::encrypt and no
# tls::digest. So the two algorithms the standard security handler needs live
# here, in Tcl, and nowhere else in the package.
#
# Everything in and out of this module is BYTES, never text. A caller that
# hands in a string with characters above U+00FF has made a mistake elsewhere.
#
# What this module deliberately does not promise: constant-time behaviour.
# Table lookups in a scripting language leak timing and cache behaviour, and
# Tcl gives no way to wipe a value from memory. That is acceptable for the job
# at hand - a PDF is encrypted once, locally, against a key the writer already
# holds - and it would be dishonest to claim more.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::crypto {
  namespace export sha256 sha384 sha512 aesEncrypt aesDecrypt aesEncryptBlock random
  namespace ensemble create

  # AES tables, built once when this file is sourced (see BuildTables).
  variable Sbox {}
  variable Sinv {}
  variable Te0 {}
  variable Te1 {}
  variable Te2 {}
  variable Te3 {}
  variable Td0 {}
  variable Td1 {}
  variable Td2 {}
  variable Td3 {}

  # SHA-2 round constants and initial hash values, likewise built once.
  variable K512 {}
  variable K256 {}
  variable H512 {}
  variable H384 {}
  variable H256 {}
}

#
# ---------------------------------------------------------------------------
# AES-256 (FIPS 197), the tables
# ---------------------------------------------------------------------------
#

# Multiplication by x in GF(2^8) with the AES polynomial 0x11b.
proc ::tclpdf::crypto::Xtime {b} {
  return [expr {($b & 0x80) ? ((($b << 1) & 0xff) ^ 0x1b) : ($b << 1)}]
}

# Full multiplication in GF(2^8). Used only while the tables are built.
proc ::tclpdf::crypto::Mul {a b} {
  set result 0
  while {$b} {
    if {$b & 1} {
      set result [expr {$result ^ $a}]
    }
    set a [Xtime $a]
    set b [expr {$b >> 1}]
  }
  return $result
}

# The S-box is COMPUTED, not transcribed: inverse in GF(2^8) followed by the
# affine map of FIPS 197 5.1.1. A 256 entry literal would be one typo away
# from a cipher that encrypts happily and decrypts to garbage; the definition
# is shorter than the table and checks itself against the FIPS 197 C.3 vector
# in the test suite.
#
# From the S-box come the four T-tables of the Rijndael reference code, which
# fold SubBytes, ShiftRows and MixColumns of one round into four lookups and
# three exclusive ors per output word. That is what makes AES in a scripting
# language usable at all.
proc ::tclpdf::crypto::BuildTables {} {
  variable Sbox
  variable Sinv
  variable Te0
  variable Te1
  variable Te2
  variable Te3
  variable Td0
  variable Td1
  variable Td2
  variable Td3

  # Logarithm and exponential over GF(2^8) with the generator 3.
  set powers {}
  set logs [lrepeat 256 0]
  set value 1
  for {set i 0} {$i < 255} {incr i} {
    lappend powers $value
    lset logs $value $i
    set value [expr {$value ^ [Xtime $value]}]
  }

  set Sbox {}
  for {set i 0} {$i < 256} {incr i} {
    if {$i == 0} {
      set inverse 0
    } else {
      set inverse [lindex $powers [expr {(255 - [lindex $logs $i]) % 255}]]
    }
    # b ^ rotl(b,1) ^ rotl(b,2) ^ rotl(b,3) ^ rotl(b,4) ^ 0x63; the bits that
    # the left shifts push above bit 7 are cut off by the final mask.
    lappend Sbox [expr {($inverse ^ (($inverse << 1) | ($inverse >> 7))
        ^ (($inverse << 2) | ($inverse >> 6))
        ^ (($inverse << 3) | ($inverse >> 5))
        ^ (($inverse << 4) | ($inverse >> 4)) ^ 0x63) & 0xff}]
  }

  set Sinv [lrepeat 256 0]
  for {set i 0} {$i < 256} {incr i} {
    lset Sinv [lindex $Sbox $i] $i
  }

  # Te0[x] = [2*S(x), S(x), S(x), 3*S(x)], Td0[x] = [14*T, 9*T, 13*T, 11*T]
  # with T = S^-1(x); the other three tables are byte rotations of the first.
  set Te0 {}
  set Td0 {}
  for {set i 0} {$i < 256} {incr i} {
    set s [lindex $Sbox $i]
    lappend Te0 [expr {([Mul $s 2] << 24) | ($s << 16) | ($s << 8) | [Mul $s 3]}]
    set t [lindex $Sinv $i]
    lappend Td0 [expr {([Mul $t 14] << 24) | ([Mul $t 9] << 16)
        | ([Mul $t 13] << 8) | [Mul $t 11]}]
  }
  set Te1 [lmap v $Te0 {expr {(($v >> 8) | ($v << 24)) & 0xffffffff}}]
  set Te2 [lmap v $Te0 {expr {(($v >> 16) | ($v << 16)) & 0xffffffff}}]
  set Te3 [lmap v $Te0 {expr {(($v >> 24) | ($v << 8)) & 0xffffffff}}]
  set Td1 [lmap v $Td0 {expr {(($v >> 8) | ($v << 24)) & 0xffffffff}}]
  set Td2 [lmap v $Td0 {expr {(($v >> 16) | ($v << 16)) & 0xffffffff}}]
  set Td3 [lmap v $Td0 {expr {(($v >> 24) | ($v << 8)) & 0xffffffff}}]
  return
}

#
# ---------------------------------------------------------------------------
# AES-256, the key schedule
# ---------------------------------------------------------------------------
#

# The encryption round keys, 4*(Nr+1) words of 32 bits. The key length decides
# Nk and with it Nr: 32 bytes give the fourteen rounds of AES-256.
proc ::tclpdf::crypto::ExpandEnc {key} {
  variable Sbox

  set nk [expr {[string length $key] / 4}]
  set total [expr {4 * ($nk + 7)}]
  set back [expr {$nk - 1}]
  binary scan $key Iu* rk
  set rcon 1
  for {set i $nk} {$i < $total} {incr i} {
    set t [lindex $rk end]
    if {$i % $nk == 0} {
      # RotWord, SubWord, then the round constant on the top byte.
      set t [expr {([lindex $Sbox [expr {($t >> 16) & 0xff}]] << 24)
          | ([lindex $Sbox [expr {($t >> 8) & 0xff}]] << 16)
          | ([lindex $Sbox [expr {$t & 0xff}]] << 8)
          | [lindex $Sbox [expr {($t >> 24) & 0xff}]]}]
      set t [expr {$t ^ ($rcon << 24)}]
      set rcon [Xtime $rcon]
    } elseif {$nk > 6 && $i % $nk == 4} {
      # The extra SubWord that only the 256 bit schedule has.
      set t [expr {([lindex $Sbox [expr {($t >> 24) & 0xff}]] << 24)
          | ([lindex $Sbox [expr {($t >> 16) & 0xff}]] << 16)
          | ([lindex $Sbox [expr {($t >> 8) & 0xff}]] << 8)
          | [lindex $Sbox [expr {$t & 0xff}]]}]
    }
    lappend rk [expr {[lindex $rk end-$back] ^ $t}]
  }
  return $rk
}

# One column of the inverse MixColumns, needed to turn an encryption schedule
# into the schedule of the equivalent inverse cipher (FIPS 197 5.3.5).
proc ::tclpdf::crypto::InvMixColumn {w} {
  set b0 [expr {($w >> 24) & 0xff}]
  set b1 [expr {($w >> 16) & 0xff}]
  set b2 [expr {($w >> 8) & 0xff}]
  set b3 [expr {$w & 0xff}]
  return [expr {(([Mul $b0 14] ^ [Mul $b1 11] ^ [Mul $b2 13] ^ [Mul $b3 9]) << 24)
      | (([Mul $b0 9] ^ [Mul $b1 14] ^ [Mul $b2 11] ^ [Mul $b3 13]) << 16)
      | (([Mul $b0 13] ^ [Mul $b1 9] ^ [Mul $b2 14] ^ [Mul $b3 11]) << 8)
      | ([Mul $b0 11] ^ [Mul $b1 13] ^ [Mul $b2 9] ^ [Mul $b3 14])}]
}

# The decryption round keys: the encryption schedule read backwards, with
# InvMixColumns applied to everything but the first and the last group of
# four. This is what lets decryption use tables of the same shape as
# encryption instead of a separate, much slower inverse round.
proc ::tclpdf::crypto::ExpandDec {key} {
  set rk [ExpandEnc $key]
  set last [expr {[llength $rk] - 4}]
  set dk {}
  for {set i $last} {$i >= 0} {incr i -4} {
    lappend dk [lindex $rk $i] [lindex $rk [expr {$i + 1}]] \
        [lindex $rk [expr {$i + 2}]] [lindex $rk [expr {$i + 3}]]
  }
  for {set i 4} {$i < $last} {incr i} {
    lset dk $i [InvMixColumn [lindex $dk $i]]
  }
  return $dk
}

#
# ---------------------------------------------------------------------------
# AES-256, the cipher
# ---------------------------------------------------------------------------
#

# One block, given and returned as four 32 bit words. The loop runs two rounds
# at a time - t from s, then s from t - which saves copying the state back and
# forth; that is the shape of the Rijndael reference code and worth about a
# fifth of the running time here.
#
# ($s0 >> 24) needs no mask: the state words are unsigned 32 bit values.
proc ::tclpdf::crypto::EncryptWords {rk words} {
  variable Te0
  variable Te1
  variable Te2
  variable Te3
  variable Sbox

  lassign $words w0 w1 w2 w3
  set s0 [expr {$w0 ^ [lindex $rk 0]}]
  set s1 [expr {$w1 ^ [lindex $rk 1]}]
  set s2 [expr {$w2 ^ [lindex $rk 2]}]
  set s3 [expr {$w3 ^ [lindex $rk 3]}]

  set k 4
  set half [expr {([llength $rk] / 4 - 1) / 2}]
  while {1} {
    set t0 [expr {[lindex $Te0 [expr {$s0 >> 24}]]
        ^ [lindex $Te1 [expr {($s1 >> 16) & 0xff}]]
        ^ [lindex $Te2 [expr {($s2 >> 8) & 0xff}]]
        ^ [lindex $Te3 [expr {$s3 & 0xff}]] ^ [lindex $rk $k]}]
    set t1 [expr {[lindex $Te0 [expr {$s1 >> 24}]]
        ^ [lindex $Te1 [expr {($s2 >> 16) & 0xff}]]
        ^ [lindex $Te2 [expr {($s3 >> 8) & 0xff}]]
        ^ [lindex $Te3 [expr {$s0 & 0xff}]] ^ [lindex $rk [expr {$k + 1}]]}]
    set t2 [expr {[lindex $Te0 [expr {$s2 >> 24}]]
        ^ [lindex $Te1 [expr {($s3 >> 16) & 0xff}]]
        ^ [lindex $Te2 [expr {($s0 >> 8) & 0xff}]]
        ^ [lindex $Te3 [expr {$s1 & 0xff}]] ^ [lindex $rk [expr {$k + 2}]]}]
    set t3 [expr {[lindex $Te0 [expr {$s3 >> 24}]]
        ^ [lindex $Te1 [expr {($s0 >> 16) & 0xff}]]
        ^ [lindex $Te2 [expr {($s1 >> 8) & 0xff}]]
        ^ [lindex $Te3 [expr {$s2 & 0xff}]] ^ [lindex $rk [expr {$k + 3}]]}]
    incr k 4
    if {[incr half -1] == 0} break
    set s0 [expr {[lindex $Te0 [expr {$t0 >> 24}]]
        ^ [lindex $Te1 [expr {($t1 >> 16) & 0xff}]]
        ^ [lindex $Te2 [expr {($t2 >> 8) & 0xff}]]
        ^ [lindex $Te3 [expr {$t3 & 0xff}]] ^ [lindex $rk $k]}]
    set s1 [expr {[lindex $Te0 [expr {$t1 >> 24}]]
        ^ [lindex $Te1 [expr {($t2 >> 16) & 0xff}]]
        ^ [lindex $Te2 [expr {($t3 >> 8) & 0xff}]]
        ^ [lindex $Te3 [expr {$t0 & 0xff}]] ^ [lindex $rk [expr {$k + 1}]]}]
    set s2 [expr {[lindex $Te0 [expr {$t2 >> 24}]]
        ^ [lindex $Te1 [expr {($t3 >> 16) & 0xff}]]
        ^ [lindex $Te2 [expr {($t0 >> 8) & 0xff}]]
        ^ [lindex $Te3 [expr {$t1 & 0xff}]] ^ [lindex $rk [expr {$k + 2}]]}]
    set s3 [expr {[lindex $Te0 [expr {$t3 >> 24}]]
        ^ [lindex $Te1 [expr {($t0 >> 16) & 0xff}]]
        ^ [lindex $Te2 [expr {($t1 >> 8) & 0xff}]]
        ^ [lindex $Te3 [expr {$t2 & 0xff}]] ^ [lindex $rk [expr {$k + 3}]]}]
    incr k 4
  }

  # The last round has no MixColumns, so it uses the S-box directly.
  return [list \
      [expr {(([lindex $Sbox [expr {$t0 >> 24}]] << 24)
          | ([lindex $Sbox [expr {($t1 >> 16) & 0xff}]] << 16)
          | ([lindex $Sbox [expr {($t2 >> 8) & 0xff}]] << 8)
          | [lindex $Sbox [expr {$t3 & 0xff}]]) ^ [lindex $rk $k]}] \
      [expr {(([lindex $Sbox [expr {$t1 >> 24}]] << 24)
          | ([lindex $Sbox [expr {($t2 >> 16) & 0xff}]] << 16)
          | ([lindex $Sbox [expr {($t3 >> 8) & 0xff}]] << 8)
          | [lindex $Sbox [expr {$t0 & 0xff}]]) ^ [lindex $rk [expr {$k + 1}]]}] \
      [expr {(([lindex $Sbox [expr {$t2 >> 24}]] << 24)
          | ([lindex $Sbox [expr {($t3 >> 16) & 0xff}]] << 16)
          | ([lindex $Sbox [expr {($t0 >> 8) & 0xff}]] << 8)
          | [lindex $Sbox [expr {$t1 & 0xff}]]) ^ [lindex $rk [expr {$k + 2}]]}] \
      [expr {(([lindex $Sbox [expr {$t3 >> 24}]] << 24)
          | ([lindex $Sbox [expr {($t0 >> 16) & 0xff}]] << 16)
          | ([lindex $Sbox [expr {($t1 >> 8) & 0xff}]] << 8)
          | [lindex $Sbox [expr {$t2 & 0xff}]]) ^ [lindex $rk [expr {$k + 3}]]}]]
}

# The equivalent inverse cipher. Same shape as EncryptWords, but the columns
# are gathered in the other direction (s0 s3 s2 s1) and the tables are the Td
# set; the schedule from ExpandDec makes the two symmetric.
proc ::tclpdf::crypto::DecryptWords {dk words} {
  variable Td0
  variable Td1
  variable Td2
  variable Td3
  variable Sinv

  lassign $words w0 w1 w2 w3
  set s0 [expr {$w0 ^ [lindex $dk 0]}]
  set s1 [expr {$w1 ^ [lindex $dk 1]}]
  set s2 [expr {$w2 ^ [lindex $dk 2]}]
  set s3 [expr {$w3 ^ [lindex $dk 3]}]

  set k 4
  set half [expr {([llength $dk] / 4 - 1) / 2}]
  while {1} {
    set t0 [expr {[lindex $Td0 [expr {$s0 >> 24}]]
        ^ [lindex $Td1 [expr {($s3 >> 16) & 0xff}]]
        ^ [lindex $Td2 [expr {($s2 >> 8) & 0xff}]]
        ^ [lindex $Td3 [expr {$s1 & 0xff}]] ^ [lindex $dk $k]}]
    set t1 [expr {[lindex $Td0 [expr {$s1 >> 24}]]
        ^ [lindex $Td1 [expr {($s0 >> 16) & 0xff}]]
        ^ [lindex $Td2 [expr {($s3 >> 8) & 0xff}]]
        ^ [lindex $Td3 [expr {$s2 & 0xff}]] ^ [lindex $dk [expr {$k + 1}]]}]
    set t2 [expr {[lindex $Td0 [expr {$s2 >> 24}]]
        ^ [lindex $Td1 [expr {($s1 >> 16) & 0xff}]]
        ^ [lindex $Td2 [expr {($s0 >> 8) & 0xff}]]
        ^ [lindex $Td3 [expr {$s3 & 0xff}]] ^ [lindex $dk [expr {$k + 2}]]}]
    set t3 [expr {[lindex $Td0 [expr {$s3 >> 24}]]
        ^ [lindex $Td1 [expr {($s2 >> 16) & 0xff}]]
        ^ [lindex $Td2 [expr {($s1 >> 8) & 0xff}]]
        ^ [lindex $Td3 [expr {$s0 & 0xff}]] ^ [lindex $dk [expr {$k + 3}]]}]
    incr k 4
    if {[incr half -1] == 0} break
    set s0 [expr {[lindex $Td0 [expr {$t0 >> 24}]]
        ^ [lindex $Td1 [expr {($t3 >> 16) & 0xff}]]
        ^ [lindex $Td2 [expr {($t2 >> 8) & 0xff}]]
        ^ [lindex $Td3 [expr {$t1 & 0xff}]] ^ [lindex $dk $k]}]
    set s1 [expr {[lindex $Td0 [expr {$t1 >> 24}]]
        ^ [lindex $Td1 [expr {($t0 >> 16) & 0xff}]]
        ^ [lindex $Td2 [expr {($t3 >> 8) & 0xff}]]
        ^ [lindex $Td3 [expr {$t2 & 0xff}]] ^ [lindex $dk [expr {$k + 1}]]}]
    set s2 [expr {[lindex $Td0 [expr {$t2 >> 24}]]
        ^ [lindex $Td1 [expr {($t1 >> 16) & 0xff}]]
        ^ [lindex $Td2 [expr {($t0 >> 8) & 0xff}]]
        ^ [lindex $Td3 [expr {$t3 & 0xff}]] ^ [lindex $dk [expr {$k + 2}]]}]
    set s3 [expr {[lindex $Td0 [expr {$t3 >> 24}]]
        ^ [lindex $Td1 [expr {($t2 >> 16) & 0xff}]]
        ^ [lindex $Td2 [expr {($t1 >> 8) & 0xff}]]
        ^ [lindex $Td3 [expr {$t0 & 0xff}]] ^ [lindex $dk [expr {$k + 3}]]}]
    incr k 4
  }

  return [list \
      [expr {(([lindex $Sinv [expr {$t0 >> 24}]] << 24)
          | ([lindex $Sinv [expr {($t3 >> 16) & 0xff}]] << 16)
          | ([lindex $Sinv [expr {($t2 >> 8) & 0xff}]] << 8)
          | [lindex $Sinv [expr {$t1 & 0xff}]]) ^ [lindex $dk $k]}] \
      [expr {(([lindex $Sinv [expr {$t1 >> 24}]] << 24)
          | ([lindex $Sinv [expr {($t0 >> 16) & 0xff}]] << 16)
          | ([lindex $Sinv [expr {($t3 >> 8) & 0xff}]] << 8)
          | [lindex $Sinv [expr {$t2 & 0xff}]]) ^ [lindex $dk [expr {$k + 1}]]}] \
      [expr {(([lindex $Sinv [expr {$t2 >> 24}]] << 24)
          | ([lindex $Sinv [expr {($t1 >> 16) & 0xff}]] << 16)
          | ([lindex $Sinv [expr {($t0 >> 8) & 0xff}]] << 8)
          | [lindex $Sinv [expr {$t3 & 0xff}]]) ^ [lindex $dk [expr {$k + 2}]]}] \
      [expr {(([lindex $Sinv [expr {$t3 >> 24}]] << 24)
          | ([lindex $Sinv [expr {($t2 >> 16) & 0xff}]] << 16)
          | ([lindex $Sinv [expr {($t1 >> 8) & 0xff}]] << 8)
          | [lindex $Sinv [expr {$t0 & 0xff}]]) ^ [lindex $dk [expr {$k + 3}]]}]]
}

#
# ---------------------------------------------------------------------------
# AES-256, the public entries
# ---------------------------------------------------------------------------
#
# Only 256 bit keys, on purpose: for a NEW file, ISO 32000-2 knows exactly one
# content cipher, AESV3 with AES-256, and what does not exist here cannot be
# picked by accident. Everything below refuses any other key length by name.
#

proc ::tclpdf::crypto::CheckKey {key} {
  set length [string length $key]
  if {$length != 32} {
    return -code error -errorcode [list TCLPDF CRYPTO KEYLENGTH $length] \
        "tclpdf: AES-256 needs a key of 32 bytes, not $length"
  }
  return
}

proc ::tclpdf::crypto::CheckIv {iv} {
  set length [string length $iv]
  if {$length != 16} {
    return -code error -errorcode [list TCLPDF CRYPTO IVLENGTH $length] \
        "tclpdf: an AES initialisation vector is 16 bytes, not $length"
  }
  return
}

proc ::tclpdf::crypto::CheckBlocks {data} {
  set length [string length $data]
  if {$length == 0 || $length % 16 != 0} {
    return -code error -errorcode [list TCLPDF CRYPTO BLOCKLENGTH $length] \
        "tclpdf: AES in CBC mode without padding needs a multiple of 16 bytes,\
        not $length"
  }
  return
}

# AES-256 in CBC mode, WITHOUT padding: the caller decides on the padding,
# because the PDF standard security handler wants PKCS#5 for strings and
# streams but nothing at all inside algorithm 2.B.
proc ::tclpdf::crypto::aesEncrypt {key iv data} {
  CheckKey $key
  CheckIv $iv
  CheckBlocks $data
  return [CbcEncrypt [ExpandEnc $key] $iv $data]
}

proc ::tclpdf::crypto::aesDecrypt {key iv data} {
  CheckKey $key
  CheckIv $iv
  CheckBlocks $data
  return [CbcDecrypt [ExpandDec $key] $iv $data]
}

# One block in ECB mode. ISO 32000-2 needs exactly this once, for the /Perms
# entry of the encryption dictionary, and it is a single block by definition -
# a chaining mode over one block would only obscure that.
proc ::tclpdf::crypto::aesEncryptBlock {key block} {
  CheckKey $key
  set length [string length $block]
  if {$length != 16} {
    return -code error -errorcode [list TCLPDF CRYPTO BLOCKLENGTH $length] \
        "tclpdf: an AES block is 16 bytes, not $length"
  }
  binary scan $block Iu4 words
  return [binary format I* [EncryptWords [ExpandEnc $key] $words]]
}

# The chaining itself, on 32 bit words rather than bytes: the whole message is
# unpacked once and packed once, and the exclusive or of the chain costs four
# operations per block instead of sixteen.
proc ::tclpdf::crypto::CbcEncrypt {rk iv data} {
  binary scan $iv Iu4 chain
  binary scan $data Iu* words
  set out {}
  foreach {w0 w1 w2 w3} $words {
    lassign $chain c0 c1 c2 c3
    set chain [EncryptWords $rk [list [expr {$w0 ^ $c0}] [expr {$w1 ^ $c1}] \
        [expr {$w2 ^ $c2}] [expr {$w3 ^ $c3}]]]
    lappend out {*}$chain
  }
  return [binary format I* $out]
}

proc ::tclpdf::crypto::CbcDecrypt {dk iv data} {
  binary scan $iv Iu4 chain
  binary scan $data Iu* words
  set out {}
  foreach {w0 w1 w2 w3} $words {
    lassign $chain c0 c1 c2 c3
    lassign [DecryptWords $dk [list $w0 $w1 $w2 $w3]] p0 p1 p2 p3
    lappend out [expr {$p0 ^ $c0}] [expr {$p1 ^ $c1}] [expr {$p2 ^ $c2}] \
        [expr {$p3 ^ $c3}]
    set chain [list $w0 $w1 $w2 $w3]
  }
  return [binary format I* $out]
}

# AES-128 in CBC mode without padding, INTERNAL and capitalised on purpose.
#
# It exists for one caller and one reason: step (b) of algorithm 2.B in
# ISO 32000-2 prescribes "encrypt K1 using AES-128 (CBC, no padding) with the
# first 16 bytes of K as the key and the second 16 bytes of K as the
# initialisation vector". Revision 6 of the standard security handler cannot
# be built without it. It is not in the ensemble and it is not for encrypting
# anything a reader will ever see - the file content is AES-256 and nothing
# else.
proc ::tclpdf::crypto::Aes128CbcNoPad {key iv data} {
  set length [string length $key]
  if {$length != 16} {
    return -code error -errorcode [list TCLPDF CRYPTO KEYLENGTH $length] \
        "tclpdf: the hardened hash of algorithm 2.B needs a key of 16 bytes,\
        not $length"
  }
  CheckIv $iv
  CheckBlocks $data
  return [CbcEncrypt [ExpandEnc $key] $iv $data]
}

#
# ---------------------------------------------------------------------------
# SHA-2 (FIPS 180-4)
# ---------------------------------------------------------------------------
#

# The round constants are the first 64 bits of the fractional parts of the
# cube roots of the first eighty primes; the SHA-256 constants are the top
# half of the first sixty-four of them, and the SHA-256 initial hash values
# are the top half of the SHA-512 ones. Deriving them costs nothing and takes
# two long lists of magic numbers out of the file.
proc ::tclpdf::crypto::BuildConstants {} {
  variable K512
  variable K256
  variable H512
  variable H384
  variable H256

  set K512 [lmap value {
    0x428a2f98d728ae22 0x7137449123ef65cd 0xb5c0fbcfec4d3b2f 0xe9b5dba58189dbbc
    0x3956c25bf348b538 0x59f111f1b605d019 0x923f82a4af194f9b 0xab1c5ed5da6d8118
    0xd807aa98a3030242 0x12835b0145706fbe 0x243185be4ee4b28c 0x550c7dc3d5ffb4e2
    0x72be5d74f27b896f 0x80deb1fe3b1696b1 0x9bdc06a725c71235 0xc19bf174cf692694
    0xe49b69c19ef14ad2 0xefbe4786384f25e3 0x0fc19dc68b8cd5b5 0x240ca1cc77ac9c65
    0x2de92c6f592b0275 0x4a7484aa6ea6e483 0x5cb0a9dcbd41fbd4 0x76f988da831153b5
    0x983e5152ee66dfab 0xa831c66d2db43210 0xb00327c898fb213f 0xbf597fc7beef0ee4
    0xc6e00bf33da88fc2 0xd5a79147930aa725 0x06ca6351e003826f 0x142929670a0e6e70
    0x27b70a8546d22ffc 0x2e1b21385c26c926 0x4d2c6dfc5ac42aed 0x53380d139d95b3df
    0x650a73548baf63de 0x766a0abb3c77b2a8 0x81c2c92e47edaee6 0x92722c851482353b
    0xa2bfe8a14cf10364 0xa81a664bbc423001 0xc24b8b70d0f89791 0xc76c51a30654be30
    0xd192e819d6ef5218 0xd69906245565a910 0xf40e35855771202a 0x106aa07032bbd1b8
    0x19a4c116b8d2d0c8 0x1e376c085141ab53 0x2748774cdf8eeb99 0x34b0bcb5e19b48a8
    0x391c0cb3c5c95a63 0x4ed8aa4ae3418acb 0x5b9cca4f7763e373 0x682e6ff3d6b2b8a3
    0x748f82ee5defb2fc 0x78a5636f43172f60 0x84c87814a1f0ab72 0x8cc702081a6439ec
    0x90befffa23631e28 0xa4506cebde82bde9 0xbef9a3f7b2c67915 0xc67178f2e372532b
    0xca273eceea26619c 0xd186b8c721c0c207 0xeada7dd6cde0eb1e 0xf57d4f7fee6ed178
    0x06f067aa72176fba 0x0a637dc5a2c898a6 0x113f9804bef90dae 0x1b710b35131c471b
    0x28db77f523047d84 0x32caab7b40c72493 0x3c9ebe0a15c9bebc 0x431d67c49c100d4c
    0x4cc5d4becb3e42b6 0x597f299cfc657e2a 0x5fcb6fab3ad6faec 0x6c44198c4a475817
  } {expr {wide($value)}}]
  set K256 [lmap value [lrange $K512 0 63] {
    expr {($value >> 32) & 0xffffffff}
  }]

  set H512 [lmap value {
    0x6a09e667f3bcc908 0xbb67ae8584caa73b 0x3c6ef372fe94f82b 0xa54ff53a5f1d36f1
    0x510e527fade682d1 0x9b05688c2b3e6c1f 0x1f83d9abfb41bd6b 0x5be0cd19137e2179
  } {expr {wide($value)}}]
  set H256 [lmap value $H512 {expr {($value >> 32) & 0xffffffff}}]

  # SHA-384 starts from the ninth to sixteenth prime instead - the one place
  # where it differs from SHA-512 besides the truncation.
  set H384 [lmap value {
    0xcbbb9d5dc1059ed8 0x629a292a367cd507 0x9159015a3070dd17 0x152fecd8f70e5939
    0x67332667ffc00b31 0x8eb44a8768581511 0xdb0c2e0d64f98fa7 0x47b5481dbefa4fa4
  } {expr {wide($value)}}]
  return
}

# The padding of 5.1.1: one 0x80 byte, zeros up to 56 bytes modulo 64, then
# the message length in bits as a 64 bit big-endian number.
proc ::tclpdf::crypto::Pad256 {bytes} {
  set length [string length $bytes]
  append bytes \x80
  append bytes [binary format x[expr {(55 - $length) % 64}]]
  append bytes [binary format W [expr {$length * 8}]]
  return $bytes
}

# The same for the 1024 bit block of SHA-384/512 (5.1.2). The length field is
# 128 bits wide; the top eight bytes are always zero here, because a message
# of 2**64 bits is not going to reach this procedure.
proc ::tclpdf::crypto::Pad512 {bytes} {
  set length [string length $bytes]
  append bytes \x80
  append bytes [binary format x[expr {(111 - $length) % 128}]]
  append bytes [binary format x8]
  append bytes [binary format W [expr {$length * 8}]]
  return $bytes
}

# SHA-256. Everything stays below 2**32 by masking after each addition, so no
# value ever leaves the machine word range.
#
# The rotations are written out rather than factored into a procedure: a
# procedure call per rotation would be six per round and eighty rounds per
# block. rotr(x,n) is (x >> n) | (x << (32-n)); the bits the left shift pushes
# above bit 31 are cut off by the mask around the whole term.
proc ::tclpdf::crypto::sha256 {bytes} {
  variable K256
  variable H256

  lassign $H256 h0 h1 h2 h3 h4 h5 h6 h7
  binary scan [Pad256 $bytes] Iu* words
  set total [llength $words]
  for {set base 0} {$base < $total} {incr base 16} {
    set w [lrange $words $base [expr {$base + 15}]]
    for {set i 16} {$i < 64} {incr i} {
      set x [lindex $w end-14]
      set y [lindex $w end-1]
      lappend w [expr {([lindex $w end-15]
          + (((($x >> 7) | ($x << 25)) ^ (($x >> 18) | ($x << 14))
              ^ ($x >> 3)) & 0xffffffff)
          + [lindex $w end-6]
          + (((($y >> 17) | ($y << 15)) ^ (($y >> 19) | ($y << 13))
              ^ ($y >> 10)) & 0xffffffff)) & 0xffffffff}]
    }
    set a $h0
    set b $h1
    set c $h2
    set d $h3
    set e $h4
    set f $h5
    set g $h6
    set h $h7
    for {set i 0} {$i < 64} {incr i} {
      set t1 [expr {($h
          + (((($e >> 6) | ($e << 26)) ^ (($e >> 11) | ($e << 21))
              ^ (($e >> 25) | ($e << 7))) & 0xffffffff)
          + (($e & $f) ^ (~$e & $g))
          + [lindex $K256 $i] + [lindex $w $i]) & 0xffffffff}]
      set t2 [expr {((((($a >> 2) | ($a << 30)) ^ (($a >> 13) | ($a << 19))
              ^ (($a >> 22) | ($a << 10))) & 0xffffffff)
          + (($a & $b) ^ ($a & $c) ^ ($b & $c))) & 0xffffffff}]
      set h $g
      set g $f
      set f $e
      set e [expr {($d + $t1) & 0xffffffff}]
      set d $c
      set c $b
      set b $a
      set a [expr {($t1 + $t2) & 0xffffffff}]
    }
    set h0 [expr {($h0 + $a) & 0xffffffff}]
    set h1 [expr {($h1 + $b) & 0xffffffff}]
    set h2 [expr {($h2 + $c) & 0xffffffff}]
    set h3 [expr {($h3 + $d) & 0xffffffff}]
    set h4 [expr {($h4 + $e) & 0xffffffff}]
    set h5 [expr {($h5 + $f) & 0xffffffff}]
    set h6 [expr {($h6 + $g) & 0xffffffff}]
    set h7 [expr {($h7 + $h) & 0xffffffff}]
  }
  return [binary format I8 [list $h0 $h1 $h2 $h3 $h4 $h5 $h6 $h7]]
}

# SHA-512 and SHA-384 share everything but the initial hash values and the
# length of the result, so they share this procedure.
#
# The 64 bit words are held as SIGNED wide integers and wrapped with wide()
# after every addition and every left shift - measured under 8.6.18 and 9.0.4,
# wide() truncates to 64 bits instead of raising. Working with unsigned values
# instead would push every word above 2**63 into a bignum and slow the whole
# thing down. The right shifts must be masked explicitly, because >> on a
# negative wide is arithmetic and would drag the sign bit along.
proc ::tclpdf::crypto::Sha512Core {bytes initial} {
  variable K512

  lassign $initial h0 h1 h2 h3 h4 h5 h6 h7
  binary scan [Pad512 $bytes] W* words
  set total [llength $words]
  for {set base 0} {$base < $total} {incr base 16} {
    set w [lrange $words $base [expr {$base + 15}]]
    for {set i 16} {$i < 80} {incr i} {
      set x [lindex $w end-14]
      set y [lindex $w end-1]
      lappend w [expr {wide([lindex $w end-15]
          + (((($x >> 1) & ((1 << 63) - 1)) | wide($x << 63))
              ^ ((($x >> 8) & ((1 << 56) - 1)) | wide($x << 56))
              ^ (($x >> 7) & ((1 << 57) - 1)))
          + [lindex $w end-6]
          + (((($y >> 19) & ((1 << 45) - 1)) | wide($y << 45))
              ^ ((($y >> 61) & ((1 << 3) - 1)) | wide($y << 3))
              ^ (($y >> 6) & ((1 << 58) - 1))))}]
    }
    set a $h0
    set b $h1
    set c $h2
    set d $h3
    set e $h4
    set f $h5
    set g $h6
    set h $h7
    for {set i 0} {$i < 80} {incr i} {
      set t1 [expr {wide($h
          + (((($e >> 14) & ((1 << 50) - 1)) | wide($e << 50))
              ^ ((($e >> 18) & ((1 << 46) - 1)) | wide($e << 46))
              ^ ((($e >> 41) & ((1 << 23) - 1)) | wide($e << 23)))
          + (($e & $f) ^ (~$e & $g))
          + [lindex $K512 $i] + [lindex $w $i])}]
      set t2 [expr {wide(((($a >> 28) & ((1 << 36) - 1)) | wide($a << 36))
              ^ ((($a >> 34) & ((1 << 30) - 1)) | wide($a << 30))
              ^ ((($a >> 39) & ((1 << 25) - 1)) | wide($a << 25)))
          + (($a & $b) ^ ($a & $c) ^ ($b & $c))}]
      set h $g
      set g $f
      set f $e
      set e [expr {wide($d + $t1)}]
      set d $c
      set c $b
      set b $a
      set a [expr {wide($t1 + $t2)}]
    }
    set h0 [expr {wide($h0 + $a)}]
    set h1 [expr {wide($h1 + $b)}]
    set h2 [expr {wide($h2 + $c)}]
    set h3 [expr {wide($h3 + $d)}]
    set h4 [expr {wide($h4 + $e)}]
    set h5 [expr {wide($h5 + $f)}]
    set h6 [expr {wide($h6 + $g)}]
    set h7 [expr {wide($h7 + $h)}]
  }
  return [binary format W8 [list $h0 $h1 $h2 $h3 $h4 $h5 $h6 $h7]]
}

proc ::tclpdf::crypto::sha512 {bytes} {
  variable H512
  return [Sha512Core $bytes $H512]
}

# SHA-384 is SHA-512 with other starting values, cut to 48 bytes.
proc ::tclpdf::crypto::sha384 {bytes} {
  variable H384
  return [string range [Sha512Core $bytes $H384] 0 47]
}

#
# ---------------------------------------------------------------------------
# Random bytes
# ---------------------------------------------------------------------------
#
# The file encryption key and every initialisation vector come from here, and
# a guessable key is not encryption. So there is exactly one source, the
# operating system, and no fallback: if /dev/urandom cannot be read, this
# refuses by name. Tcl's rand() is a seeded linear generator and would turn a
# refusal into a file that merely looks encrypted - the fork this package
# learned from shipped that mistake and had to fix it later.
#

proc ::tclpdf::crypto::random {n} {
  if {![string is integer -strict $n] || $n < 0} {
    return -code error -errorcode [list TCLPDF CRYPTO COUNT $n] \
        "tclpdf: the number of random bytes is a non-negative integer,\
        not \"$n\""
  }
  if {$n == 0} {
    return ""
  }
  set source /dev/urandom
  if {[catch {open $source r} channel]} {
    return -code error -errorcode [list TCLPDF CRYPTO RANDOM] \
        "tclpdf: no source of cryptographically strong random bytes\
        ($source): $channel"
  }
  # "-translation binary" ALONE: "-encoding binary" throws under Tcl 9.
  fconfigure $channel -translation binary
  set bytes ""
  set failure {}
  while {[string length $bytes] < $n} {
    set chunk {}
    if {[catch {read $channel [expr {$n - [string length $bytes]}]} chunk]} {
      set failure $chunk
      break
    }
    if {$chunk eq ""} {
      set failure "the source gave [string length $bytes] of $n bytes"
      break
    }
    append bytes $chunk
  }
  close $channel
  if {$failure ne {}} {
    return -code error -errorcode [list TCLPDF CRYPTO RANDOM] \
        "tclpdf: no source of cryptographically strong random bytes\
        ($source): $failure"
  }
  return $bytes
}

::tclpdf::crypto::BuildTables
::tclpdf::crypto::BuildConstants

package provide tclpdf::crypto 1.0
