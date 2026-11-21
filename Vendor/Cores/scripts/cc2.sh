#!/bin/zsh
# usage: cc2.sh <file>   env: T DEFS O, optional CXXSTD (default "-std=c++23 -fno-rtti")
f=${1//..\//up_}; f=${f#./}; o="$O/${f//\//_}.o"
case $1 in
 *.c) xcrun clang ${=T} -O3 -fPIC -fvisibility=hidden -w -ffile-prefix-map=$PWD/= -ffile-prefix-map=/private/tmp/= -ffile-prefix-map=$HOME/= ${=DEFS} -c $1 -o $o || echo "FAIL $1";;
 *.m) xcrun clang ${=T} -O3 -fPIC -fvisibility=hidden -w -ffile-prefix-map=$PWD/= -ffile-prefix-map=/private/tmp/= -ffile-prefix-map=$HOME/= ${=DEFS} -c $1 -o $o || echo "FAIL $1";;
 *) xcrun clang++ ${=T} -O3 -fPIC -fvisibility=hidden -w ${=CXXSTD:--std=c++23 -fno-rtti} -stdlib=libc++ -ffile-prefix-map=$PWD/= -ffile-prefix-map=/private/tmp/= -ffile-prefix-map=$HOME/= ${=DEFS} -c $1 -o $o || echo "FAIL $1";;
esac
