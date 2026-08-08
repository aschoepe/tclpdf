#!/bin/sh

set -e

if [ $# -lt 3 ]; then
    echo "usage: $0 PACKAGE_NAME PACKAGE_VERSION PKG_TCL_SOURCES" >&2
    echo "intended to be called via 'make release' (or 'make archive')" >&2
    exit 1
fi

# CDPATH would make cd print the target directory
unset CDPATH

PACKAGE_NAME=$1
PACKAGE_VERSION=$2
# all remaining arguments are the Tcl source files, whether the caller
# passed them as one quoted list or as individual words
shift 2
PKG_TCL_SOURCES="$@"

# ignore AppleDouble files
# macOS 10.4
COPY_EXTENDED_ATTRIBUTES_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE
# macOS >= 10.5
COPYFILE_DISABLE=1
export COPYFILE_DISABLE

rm -f uv/${PACKAGE_NAME}*.zip uv/${PACKAGE_NAME}*.tar.gz

mkdir -p uv/${PACKAGE_NAME}${PACKAGE_VERSION}

cp ${PKG_TCL_SOURCES} manifest.txt pkgIndex.tcl license.terms uv/${PACKAGE_NAME}${PACKAGE_VERSION}

# icc/ goes into the BINARY archive as well: the output intent profile is a
# runtime part, not documentation - without it no PDF/A and therefore no
# ZUGFeRD. The directory name is kept, the package looks for
# [file join $dir icc sRGB.icc].
cp -R icc uv/${PACKAGE_NAME}${PACKAGE_VERSION}/

# xattr -r -d com.apple.provenance .: recursively (-r) deletes the extended attribute com.apple.provenance from the specified file or directory. com.apple.provenance: An extended attribute used by macOS (e.g., Finder or Gatekeeper) to track the origin of a file, such as downloaded sources.
# tar --no-mac-metadata: Do not store or restore Mac extended metadata (e.g., resource forks, Finder info, and so forth). This metadata is stored in special “AppleDouble” files or as extended attributes. This option is useful when creating archives to be used on non-Mac platforms.
# tar --disable-copyfile: This option is equivalent to setting the environment variable COPYFILE_DISABLE=1. It disables copying of extended attributes and resource forks by preventing the use of the copyfile() API. Use this when you want to avoid creation of ._* AppleDouble files or when those are not needed.
# tar --no-xattrs: Do not store or restore extended file attributes (xattrs). These are often system or application metadata not relevant or supported on other systems.

cd uv
zip -x '.DS_Store' -x '*/.DS_Store' -qr ${PACKAGE_NAME}${PACKAGE_VERSION}.zip ${PACKAGE_NAME}${PACKAGE_VERSION}
tar --no-xattrs --no-mac-metadata --disable-copyfile --exclude='.DS_Store' --exclude='*/.DS_Store' -czf ${PACKAGE_NAME}${PACKAGE_VERSION}.tar.gz ${PACKAGE_NAME}${PACKAGE_VERSION}
rm -fr ${PACKAGE_NAME}${PACKAGE_VERSION}

# The download page is optional: without the template it is skipped rather
# than failing the whole archive run.
if [ -f template-download.html ]; then
    cp template-download.html download.html
    ex - download.html <<!
g/PACKAGE_VERSION/s//${PACKAGE_VERSION}/g
wq
!
else
    echo "archive: template-download.html is missing - download.html not generated" >&2
fi

# The source archive takes the whole tree minus the exclusions below.
#
# examples/assets/xml is excluded ON PURPOSE: those two invoice files come from
# the ZUGFeRD 2.5.2 DE distribution and no licence accompanies them, so they
# must not be redistributed until that is settled (docs/TODO.md). Said out loud
# rather than dropped quietly - a missing file in a release is otherwise found
# by whoever runs the example, not by us.
echo "archive: examples/assets/xml is left out - licence of the ZUGFeRD sample" >&2
echo "archive: invoices not established yet, see docs/TODO.md" >&2

cd ../..
tar --no-xattrs --no-mac-metadata --disable-copyfile \
    --exclude='uv/*' \
    --exclude="${PACKAGE_NAME}/examples/assets/xml" \
    --exclude="${PACKAGE_NAME}/.fslckout" \
    --exclude="${PACKAGE_NAME}/.fossil-settings" \
    --exclude="${PACKAGE_NAME}/.claude" \
    --exclude="${PACKAGE_NAME}/CLAUDE.md" \
    --exclude="${PACKAGE_NAME}/.gitattributes" \
    --exclude="${PACKAGE_NAME}/.vscode" \
    --exclude='.DS_Store' --exclude='*/.DS_Store' \
    --exclude='autom4te.cache' --exclude='configure~' --exclude='config.*' \
    -czf ${PACKAGE_NAME}/uv/${PACKAGE_NAME}${PACKAGE_VERSION}-src.tar.gz ${PACKAGE_NAME}
