#!/bin/bash
set -euo pipefail
v=$1; mode=$2; DD="$RUNNER_TEMP/today-ci/dd"; mkdir -p "$RUNNER_TEMP/today-ci"
t(){ echo "::notice::lab +$((SECONDS)) $*"; }
./dev bootstrap --tool xcodegen; ./dev generate
L=ios/Today.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; mkdir -p "$(dirname $L)"; cp ios/Dependencies/Package.resolved "$L"
if [ "$mode" = edit ]; then sed -i '' 's/Text("Evening")/Text("EveningLab7319")/' ios/Sources/Features/FeatureToday/DayPartCards.swift; grep -c EveningLab7319 ios/Sources/Features/FeatureToday/DayPartCards.swift; fi
python3 .lab/mtime.py
defaults write com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges -bool YES
ACT=build-for-testing; SCH=TodayCI; EX=(); D=(-destination 'generic/platform=iOS Simulator')
XC=(env -i "HOME=$HOME" "PATH=$PATH" "DEVELOPER_DIR=$DEVELOPER_DIR" xcodebuild)
case $v in sdk) D=(-sdk iphonesimulator);; today) ACT=build; SCH=Today;; cs) EX=(CODE_SIGNING_ALLOWED=NO);; esac
t start
"${XC[@]}" $ACT -project ios/Today.xcodeproj -scheme $SCH -configuration Debug "${D[@]}" -jobs 3 ARCHS=arm64 ENABLE_DEBUG_DYLIB=NO -derivedDataPath "$DD" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates COMPILER_INDEX_STORE_ENABLE=NO SWIFT_ENABLE_EXPLICIT_MODULES=NO "${EX[@]+"${EX[@]}"}" 2>&1 | perl -MTime::HiRes=time -ne 'BEGIN{$s=time;$|=1} printf "%6.1f %s",time-$s,$_' > /tmp/x.log
t built
if [ "$mode" = edit ]; then echo "MARKER in One.app: $(grep -rl EveningLab7319 "$DD/Build/Products/Debug-iphonesimulator/One.app" | head -3 | tr '\n' ' ')"; echo "MARKER in TodayMock: $(grep -rl EveningLab7319 "$DD"/Build/Products/Debug-iphonesimulator/*Mock*.app | head -3 | tr '\n' ' ')"; fi
du -sh ~/Library/Caches/org.swift.swiftpm || true; find ~/Library/Caches/org.swift.swiftpm -maxdepth 2 | head
grep -E '^ *[0-9.]+ (SwiftCompile|Ld |\*\*|Resolve|Resolved|Prepare)' /tmp/x.log | awk '{n[$2]++; if(!($2 in f)){f[$2]=$1}; l[$2]=$1} END{for(k in n) print "SUM",k,"n="n[k],"first="f[k],"last="l[k]}'
tail -1 /tmp/x.log
if [ "$mode" = seed ]; then
  [ "$v" = mc ] && rm -rf "$DD/ModuleCache.noindex"
  find "$DD" -type f | wc -l; for d in "$DD"/SourcePackages/* "$DD"/ModuleCache.noindex "$DD"/Build/Products "$DD"/Build/Intermediates.noindex; do echo "$(find "$d" -type f | wc -l) $(du -sh "$d")"; done
fi
