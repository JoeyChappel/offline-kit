#!/bin/zsh
# usage: objs_to_sources.sh <makefile folder> <srcroot for relative paths> <work dir>
# Turns <work>/objs.txt (from `make ... dumpobjs`) into cxx.txt / c.txt of absolute source paths.
MK=$1; ROOT=$2; WS=$3
: > $WS/cxx.txt; : > $WS/c.txt; : > $WS/missing.txt
for o in $(cat $WS/objs.txt); do
 [[ $o = /* ]] && b=${o%.o} || b=$ROOT/${o%.o}
 if [ -f $b.cpp ]; then echo $b.cpp >> $WS/cxx.txt
 elif [ -f $b.c ]; then echo $b.c >> $WS/c.txt
 elif [ -f $b.m ]; then echo $b.m >> $WS/c.txt
 else echo $o >> $WS/missing.txt; fi
done
wc -l $WS/cxx.txt $WS/c.txt $WS/missing.txt
