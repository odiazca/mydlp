#!/bin/bash

REVISION=1

if [ -n "$1" ]; then
	REVISION=$1
fi

VERSION=$(git describe |sed -s 's/-.*$//')
NEXTVERSION=""

function incrementVersion {
        local PRE=$(echo $CURRENTVERSION|sed -e 's/\.[0-9]$//')
        local LAST=$(echo $CURRENTVERSION|sed -e 's/^v[0-9]\.[0-9]\.//')
        NEXTVERSION="$PRE"".""$(( $LAST + 1 ))"
}

function applyTemplate {
	local TMPL=$1
	local OUT=$2
	local TMPFILE="$OUT""~"

	cp -af $TMPL $TMPFILE
	sed -i -e "s/%%%VERSION%%%/$NEXTVERSION/g" $TMPFILE
	sed -i -e "s/%%%REVISION%%%/$REVISION/g" $TMPFILE
	mv -f $TMPFILE $OUT
}

incrementVersion

echo "Current version is $NEXTVERSION-$REVISION"

applyTemplate configure.ac.tmpl configure.ac
applyTemplate debian/changelog.tmpl debian/changelog

git submodule init
git submodule update

autoreconf -f -i

