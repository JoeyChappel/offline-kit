#!/bin/zsh
# usage: cc1.sh src outdir ; env: TFLAGS FL
o="$2/${1//\//_}.o"
xcrun clang ${=TFLAGS} -O3 -fPIC -fvisibility=hidden -DIOS -w -ffile-prefix-map=$PWD/= -ffile-prefix-map=/private/tmp/= -ffile-prefix-map=$HOME/= ${=FL} -c $1 -o $o || echo FAIL $1
