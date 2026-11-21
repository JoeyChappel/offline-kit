#!/bin/zsh
# usage: package_core.sh <work subdir> <framework name> <short version> <id suffix> [resources dir]
# Like package2.sh, for one core: wraps <work subdir>/{macos,ios,iossim}/<name>.dylib (from build_core.sh) into
# frameworks and an xcframework in Vendor/Cores. Anything in [resources dir] is copied into each framework's Resources
# (flat framework root on iOS), e.g. ScummVM's engine data in "extra".
set -e
WS=$1; N=$2; SHORT=$3; ID=$4; RES=$5
OUT=${0:A:h:h}
FW=$WS/fw; rm -rf $FW
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
ARGS=()
for S in macos ios iossim; do
 F=$FW/$S/$N.framework; mkdir -p $F
 if [ $S = macos ]; then
  mkdir -p $F/Versions/A/Resources
  cp $WS/$S/$N.dylib $F/Versions/A/$N
  plist $N com.joeychappel.offlinekit.core.$ID $SHORT 1 MacOSX $F/Versions/A/Resources/Info.plist
  [ -n "$RES" ] && cp -R $RES/. $F/Versions/A/Resources/
  ln -s A $F/Versions/Current; ln -s Versions/Current/$N $F/$N; ln -s Versions/Current/Resources $F/Resources
  strip -x $F/Versions/A/$N
 else
  cp $WS/$S/$N.dylib $F/$N
  P=iPhoneOS; [ $S = iossim ] && P=iPhoneSimulator
  plist $N com.joeychappel.offlinekit.core.$ID $SHORT 1 $P $F/Info.plist
  [ -n "$RES" ] && cp -R $RES/. $F/
  strip -x $F/$N
 fi
 codesign --force -s - $F
 ARGS+=(-framework $F)
done
rm -rf $OUT/$N.xcframework
xcodebuild -create-xcframework $ARGS -output $OUT/$N.xcframework
