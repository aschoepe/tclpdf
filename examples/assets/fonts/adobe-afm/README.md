# Adobe core font metrics - the source of afmData.tcl

The metrics of the fourteen standard faces (ISO 32000-1 9.6.2.2), as Adobe
published them. **Unmodified**: no file here has been touched, and the licence
requires any change to be noted prominently, so if that line ever stops being
true it has to be said here.

`afmData.tcl` is generated from exactly these files:

    tclsh tools/mkafm.tcl examples/assets/fonts/adobe-afm > afmData.tcl

Verified rather than claimed: the output is **byte-identical** to the committed
`afmData.tcl`, under Tcl 8.6.18 and 9.0.4 alike. That is also the evidence that
these are the files it originally came from.

## Why they are here and not only on someone's disk

Until 2026-08-13 the generator took an AFM directory that was named nowhere -
`tools/BUILD-PACKAGE.md` said "the Adobe AFM files" and left it at that. By then
they were no longer on the build machine, so a file whose own header says
"GENERATED - do not edit, rerun the generator" could not be regenerated at all.
The same shape of gap as the pdf4tcl dependency that was removed the same week:
a build step resting on something outside the tree that nothing declared.

Source: <https://github.com/jukka/pcfi>, `src/main/resources/com/adobe/pdf/pcfi/afm`
- a collection of the Adobe Developer Center files.

## Licence - and one condition that binds this directory

From `LICENSE.txt`, which is part of the material and not a summary of it:

> "This file and the 14 PostScript(R) AFM files it accompanies may be used,
> copied, and distributed for any purpose and without charge, with or without
> modification, provided that all copyright notices are retained; that the AFM
> files are not distributed without this file; that all modifications to this
> file or any of the AFM files are prominently noted in the modified file(s);
> and that this paragraph is not modified."

**The AFM files may never travel without `LICENSE.txt`.** Anything that copies,
trims or repackages this directory has to carry it along; a copy of the metrics
on their own is not permitted. `MustRead.html` came from the same directory and
is kept for the same reason.

This grant covers the **metrics only**. The outlines of these fourteen faces
were never released and carry no such permission - see
`../adobe-standard-14/NOTICE.md`, which is why that directory is barred from
both the repository and the source archive while this one is not.
