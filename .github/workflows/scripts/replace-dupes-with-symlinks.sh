#!/bin/bash
#
# Recursively replace duplicate files with symlinks
# 
#	replace-dupes-with-symlinks.sh [DIR]
#
# DIR: Directory to traverse.  Defaults to current directory if not specified.
#

src="$1"
if [ -z "$src" ] ; then
	src="."
fi

declare -A db

pushd "$src"
while read line ; do
	bn="$(basename $line)"
	if [ -z "${db[$bn]}" ] ; then
		# First time this file has been seen
		db[$bn]="$line"
	else
		if diff -b "$line" "${db[$bn]}" &>/dev/null ; then
			# Files are the same, make a symlink
			rm "$line"
			ln -sr "${db[$bn]}" "$line"
		fi
	fi
	
done <<< "$(find . -type f)"
popd
