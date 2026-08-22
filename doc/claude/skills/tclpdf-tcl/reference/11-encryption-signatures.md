# Encryption and digital signatures

Two claims about a document as a whole, declared with one call each and checked at the write. What they exclude is worth knowing first: encryption excludes every PDF/A claim - and therefore ZUGFeRD - and encryption and a signature exclude each other, in whichever order the two calls are made. A PDF/A or ZUGFeRD document, though, may be signed.

## Encryption: AES-256, and it has to come first

```tcl
package require tclpdf

# /V 5 /R 6, AES-256 for strings, streams and the file - the only revision
# this package writes. RC4 and AES-128 are deprecated in PDF 2.0 and are not
# offered: a writer that offers them offers a choice whose wrong half looks
# exactly like the right one from outside. AESV3 IS a PDF 2.0 feature, so the
# document has to be one - the version is not raised behind the caller's back.
set doc [tclpdf new -unit mm -version 2.0]

# ENCRYPT COMES FIRST: before the first page, the first line of text, before
# [language] and [link], which build their entries at the call. A stream
# written before the cipher was installed would stay in the clear inside a
# file whose /Encrypt says otherwise, and no tool complains about that.
#
# An EMPTY user password is often what is wanted: the document opens for
# everyone and the owner password is what lifts the restrictions. Without
# -owner the user password serves as both; an empty owner password is not
# offered, being the first one any reader tries.
set state [$doc encrypt -user {} -owner "the owner password" \
    -permissions {print copy} -metadata 0]
puts "encryption: [dict get $state method], revision [dict get $state revision],\
    P [dict get $state p]"

# -permissions is a list of NAMES: print modify copy annotate fill assemble
# highres - "all" is the default, the empty list grants nothing and still
# leaves a document that can be read, since reading is not a permission.
# -metadata 0 leaves the XMP packet in the clear, so a cataloguing system can
# index a document it may not open.
$doc page add
$doc font -family helvetica -size 11
$doc text "Encrypted with AES-256. Permissions are a statement of intent that\
    a conforming reader honours - not a lock: the content is decrypted either\
    way once the file opens." -at {20 20} -width 170
$doc write [file join $out ref-11-encrypted.pdf]
puts [$doc encrypt state]
$doc destroy
```

`qpdf --show-encryption ref-11-encrypted.pdf` reads it back - `R = 6`, `AESv3`, and the permission bits one by one. Two things stay readable on purpose: the file identifier `/ID`, which a reader compares before it has any key, and the strings of the encryption dictionary itself. A second `write` of an encrypted document is **not** byte-identical: every string and stream takes a fresh initialisation vector, and reusing one would be the mistake.

```tcl
# The four refusals, each measured here rather than described. An empty -user
# is allowed and is often what is wanted - but then -owner has to say
# something, or both passwords would be empty and every reader would open the
# file as its owner, with every permission granted.
set doc [tclpdf new -unit mm -version 2.0]
if {[catch {$doc encrypt -user {}} message]} { puts "no owner: $message" }
$doc destroy

set doc [tclpdf new -unit mm]                       ;# 1.7
if {[catch {$doc encrypt -user {} -owner secret} message]} { puts "version: $message" }
$doc destroy

set doc [tclpdf new -unit mm -version 2.0]
$doc page add
$doc font -family helvetica -size 10
$doc text "already drawn" -at {20 20}
if {[catch {$doc encrypt -user {} -owner secret} message]} { puts "too late: $message" }
$doc destroy

set doc [tclpdf new -unit mm -version 2.0]
$doc encrypt -user {} -owner secret
if {[catch {$doc pdfa -part 3} message]} { puts "pdfa: $message" }
$doc destroy
```

Not there, deliberately: revisions 2 to 4 and RC4, the public-key handler, encrypting only the attachments, reading someone else's encrypted file (`pdf import` refuses one by name), and SASLprep on the password. The cipher protects confidentiality and nothing else - it is not a signature.

## Signatures: tclpdf prepares, the signature comes from outside

Nothing in this package holds a private key, computes a digest or speaks CMS. `-signer` is a command prefix, called as `{*}$prefix $bytes`, and it has to answer a **CMS SignedData object in DER**. That cut is not convenience: in production the key is on a smart card, in an HSM or with a signing service, and the prefix is where that gets plugged in.

```tcl
# Scaffolding, not tclpdf: a throwaway certificate and a signer built on
# openssl. In production only these two procedures change.
proc refCertificates {dir} {
    exec openssl req -x509 -newkey rsa:2048 -keyout [file join $dir key.pem] \
        -out [file join $dir cert.pem] -days 30 -nodes \
        -subj "/C=DE/O=tclpdf reference/CN=E. Mustermann" \
        -addext "keyUsage=critical,digitalSignature,nonRepudiation" 2>@1
}
proc refSigner {dir bytes} {
    # -binary: openssl must not treat the bytes as text with line endings.
    set channel [open [file join $dir content.bin] w]
    fconfigure $channel -translation binary
    puts -nonewline $channel $bytes
    close $channel
    exec openssl cms -sign -binary -in [file join $dir content.bin] \
        -signer [file join $dir cert.pem] -inkey [file join $dir key.pem] \
        -md sha256 -outform DER -out [file join $dir signature.der] 2>@1
    set channel [open [file join $dir signature.der] r]
    fconfigure $channel -translation binary
    set der [read $channel]
    close $channel
    return $der
}

set signing [llength [auto_execok openssl]]
if {$signing} {
    set channel [file tempfile refDir]      ;# a directory of our own, both interpreters
    close $channel
    file delete $refDir
    file mkdir $refDir
    refCertificates $refDir
}
```

### One stage: signed as it is written

```tcl
set doc [tclpdf new -unit mm]
$doc page add
$doc font -family helvetica -size 11
$doc text "An approval signature over the whole file - invisible, because\
    nothing gave it a place to be seen." -at {20 20} -width 170

# The call is made ONCE and before the write; nothing is built at the call
# itself. -size is the room reserved for the value (16384 by default -
# measured, an RSA-2048 object with its issuer is 2599 bytes, so the default
# is generous rather than tight). -field is the partial field name.
if {$signing} {
    $doc sign -signer [list refSigner $refDir] -reason "Approved" \
        -location "Bochum" -date now -field Signature1
} else {
    $doc sign -reason "Approved" -location "Bochum" -field Signature1
}
$doc write [file join $out ref-11-signature.pdf]

# What was declared and what the write made of it. "signed" says whether a
# value was actually written; the SIGNER is deliberately not in the state - a
# command prefix may carry a passphrase, and a state dictionary ends up in a log.
set state [$doc sign state]
puts "signed: [dict get $state signed], /ByteRange [dict get $state byteRange],\
    [dict get $state length] bytes of DER in [dict get $state size] reserved"

# A signed document has to go to a FILE: /ByteRange is computed from the
# finished file, and a channel cannot be read back.
if {[catch {$doc writeChannel stdout} message]} { puts "channel: $message" }
$doc destroy
```

### Two stages: prepared here, signed elsewhere

```tcl
set doc [tclpdf new -unit mm]
$doc page add
$doc font -family helvetica -size 11
$doc text "Prepared without -signer: /ByteRange is filled in all the same,\
    which is the whole purpose of this stage - without it nobody on the other\
    side knows which bytes to hash." -at {20 20} -width 170
$doc sign -reason "Approved"
$doc write [file join $out ref-11-twostage.pdf]
$doc destroy

# THIS CALL WRITES THE FILE, and it cannot be otherwise: /M lies inside the
# bytes it is about to hand out, so the time of signing goes into the file
# BEFORE they leave. A second [digest] of the same file answers the same
# bytes and an empty "date" - it wrote nothing, the file already says when.
set job [::tclpdf::sign digest [file join $out ref-11-twostage.pdf]]
puts "to be signed: [string length [dict get $job bytes]] bytes,\
    room [dict get $job size], claims [dict get $job subFilter]"

if {$signing} {
    # ... the bytes go to the card, the HSM, the service; the DER comes back
    set der [refSigner $refDir [dict get $job bytes]]
    puts "embedded: [::tclpdf::sign embed [file join $out ref-11-twostage.pdf] $der] bytes"

    # ANOTHER signature onto the finished file, as an incremental update: every
    # byte already in it stays where it is, which is what keeps the first
    # signature valid. A second [$doc sign] on one document is refused instead.
    set added [::tclpdf::sign add [file join $out ref-11-twostage.pdf] \
        -signer [list refSigner $refDir] -field Signature2 -reason "Countersigned"]
    puts "appended: [dict get $added appended] bytes"
} else {
    puts "no openssl here - the file keeps its reserved zeros"
}
```

`pdfsig` on the result says `Not total document signed` for the **first** signature and `Total document signed` for the second. That is not a complaint: the first covers its own revision, and the file has grown since.

### A visible signature draws itself

```tcl
set doc [tclpdf new -unit mm]
$doc page add
$doc font -family helvetica -size 11
$doc text "-rect and -appearance make the field visible, and neither works\
    without the other." -at {20 20} -width 170

# The appearance is a form XObject the CALLER builds - this package does not
# draw one, because a signature appearance is layout and the caller's document
# does layout already. GIVE THE FORM THE SIZE OF THE -rect: an appearance
# stream is mapped from its bounding box into the rectangle of its annotation,
# so a 70 x 26 form in a 35 x 13 rectangle comes out at half size.
$doc form create signatureBox -size {70 26} -script {
    $doc rect -at {0 0} -size {70 26} -stroke {0.30 0.30 0.40} -width 0.3 -radius 1
    $doc font -family helvetica -style bold -size 8 -color {0.20 0.25 0.45}
    $doc text "Signed by E. Mustermann" -at {4 8}
    $doc font -style {} -size 6.5 -color {0.35 0.35 0.4}
    $doc text "Reason: approval. The time of signing" -at {4 14}
    $doc text "is in the signature dictionary." -at {4 18}
}
# -rect is {x y w h}, the TOP LEFT corner and the size, y from the top, on the
# page -page names (counted from 0 as [page current] counts). Where it lands
# and which form the name stands for are worked out at the WRITE, so both may
# be created after this call.
$doc sign -field Visible1 -page 0 -rect {120 40 70 26} -appearance signatureBox \
    -reason "Approved" -name "E. Mustermann"
$doc write [file join $out ref-11-signature-visible.pdf]
puts "visible field: [dict get [$doc sign state] rect]"
$doc destroy

if {$signing} { file delete -force $refDir }
```

What a visible appearance **cannot** show is the time of signing, unless the signing happens at the write: in the two-stage way the file is signed later, possibly on another machine, so a picture naming a time there would be a picture of something that has not happened. Say in the appearance where the time is to be found instead.

## What to know before promising anything

- **`-subfilter` is the caller's choice**: `pkcs7` (`/adbe.pkcs7.detached`, the default, PDF 1.6) or `cades` (`/ETSI.CAdES.detached`, PDF 2.0). Each brings its own version floor and a document below it is refused rather than raised. The default claims less **and** has the lower floor - deliberately, since PDF/A-2 and -3 are written as 1.7 at most.
- **`cades` is a promise about the CMS object, not a second name for it.** ETSI EN 319 142-1 puts `signing-time` at "shall not be present", and a signer writes that attribute unless told otherwise. An object carrying it is refused with `TCLPDF SIGN SIGNINGTIME`, on both ways in. pyHanko and the EU DSS library leave it out by themselves; `openssl cms -sign` needs `-no_signing_time`, which OpenSSL 3 has and the LibreSSL shipped as `/usr/bin/openssl` on macOS does not; BouncyCastle adds it unasked.
- **A PDF/A or ZUGFeRD document may be signed** - measured: veraPDF `isCompliant true`, 0 failed checks, Mustangproject valid, the embedded invoice byte-identical to the unsigned file's.
- **A timestamp needs nothing here**: an RFC 3161 token is an *unsigned* attribute of the CMS object, so the signer puts it there and this package never sees it as anything but bytes. Reserve enough room - such an object measured 7108 bytes against the 16384 reserved by default.
- **Not there**: a document timestamp (`/DocTimeStamp`), `/DocMDP` certification, and a signature and encryption in one file.
- A signed document is **not** byte-identical over two writes - `/M` and the CMS object carry the moment. One prepared *without* `-signer` is, and stays so until `::tclpdf::sign digest` names a time in it.
- `::tclpdf::sign digest`, `embed` and `add` are **package commands**, not document methods: the second stage happens in another process, often on another machine and days later. A script that only embeds a signature never creates a document, so it needs `package require tclpdf::sign` of its own.
