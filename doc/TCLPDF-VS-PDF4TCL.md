# tclpdf versus pdf4tcl

This page used to carry a measured, row-by-row feature comparison against pdf4tcl 0.9.4, the last official release. It has been retired — and cheerfully so.

pdf4tcl has an actively maintained fork at <https://github.com/gregnix/pdf4tcl>, and its author moves fast: gaps named in public have been closed within a day. Keeping a measured comparison current against that pace would cost nearly as much effort as extending tclpdf itself, and the effort is better spent on the software. So instead of a list that is outdated the moment it is published, this page now says just two things.

First: tclpdf is MIT licensed. If anything over here is useful over there — an approach, a check, a test idea — taking it is exactly what the license is for, and welcome.

Second, the one comparison that has stayed stable while the feature lists moved: the two projects pull in different directions, and they complement each other. pdf4tcl's line is working with existing PDFs — merging, forms, encryption. tclpdf's line is standards-driven generation — PDF/A and PDF/UA with a validation stand, ZUGFeRD/Factur-X and Order-X, typesetting, tables, SVG. Both are pure Tcl, and measured on 2026-08-20 they load side by side in one interpreter without conflict.

The dated snapshot measured against 0.9.4 remains in this repository's history, in the earlier revisions of this file.
