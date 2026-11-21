#!/bin/zsh
set -e
W="${CORES:?Set CORES to the folder holding the cloned core repositories and work/ (see ../README.md)}/work"
OUT=${0:A:h:h}
mkdir -p $OUT; rm -rf $W/fw
plist() { # name id short ver platform(MacOSX|iPhoneOS|iPhoneSimulator) dest
 local min; if [ $5 = MacOSX ]; then min="<key>LSMinimumSystemVersion</key><string>26.0</string>"; else min="<key>MinimumOSVersion</key><string>26.0</string>"; fi
 cat > $6 <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>$1</string>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$3</string>
<key>CFBundleVersion</key><string>$4</string>
<key>CFBundleSupportedPlatforms</key><array><string>$5</string></array>
$min
</dict></plist>
P
}
for C in pce; do
 N=mednafen_pce_fast_libretro; SHORT=1.31.0
 VER=1
 ARGS=()
 for S in macos ios iossim; do
  SRC=$W/$C/$S/$N.dylib
  F=$W/fw/$S/$N.framework; mkdir -p $F
  if [ $S = macos ]; then
   mkdir -p $F/Versions/A/Resources
   cp $SRC $F/Versions/A/$N
   plist $N com.joeychappel.offlinekit.core.$C $SHORT $VER MacOSX $F/Versions/A/Resources/Info.plist
   ln -s A $F/Versions/Current; ln -s Versions/Current/$N $F/$N; ln -s Versions/Current/Resources $F/Resources
  else
   cp $SRC $F/$N
   P=iPhoneOS; [ $S = iossim ] && P=iPhoneSimulator
   plist $N com.joeychappel.offlinekit.core.$C $SHORT $VER $P $F/Info.plist
  fi
  strip -x $F/$( [ $S = macos ] && echo Versions/A/ )$N 2>/dev/null || true
  codesign --force -s - $F
  ARGS+=(-framework $F)
 done
 rm -rf $OUT/$N.xcframework
 xcodebuild -create-xcframework $ARGS -output $OUT/$N.xcframework
done
