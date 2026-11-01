#!/usr/bin/env python3
"""Build the pinned, decoder-only libvpx fallback; never download during a build."""
import argparse,hashlib,json,os,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--output',type=Path);p.add_argument('--platform');a=p.parse_args()
project=Path(__file__).resolve().parents[1];source=project/'ThirdParty/libvpx-1.17.0'
root=a.output or Path(os.environ['DERIVED_FILE_DIR'])/'PJDVVP9';root.mkdir(parents=True,exist_ok=True)
platform=a.platform or os.environ.get('PLATFORM_NAME','macos')
sdk_name={'iphoneos':'iphoneos','iphonesimulator':'iphonesimulator','macosx':'macosx','macos':'macosx'}[platform]
target={'iphoneos':'arm64-apple-ios17.0','iphonesimulator':'arm64-apple-ios17.0-simulator','macosx':'arm64-apple-ios14.0-macabi','macos':'arm64-apple-macos11.0'}[platform]
sdk=subprocess.check_output(['xcrun','--sdk',sdk_name,'--show-sdk-path'],text=True).strip();clang=subprocess.check_output(['xcrun','--find','clang'],text=True).strip()
recipe=dict(version='1.17.0',target=target,sdk=sdk,configure=hashlib.sha256((source/'configure').read_bytes()).hexdigest(),revision=2)
receipt=root/'complete.json';library=root/'libvpx.a'
if library.is_file() and receipt.is_file() and json.loads(receipt.read_text())==recipe:print('VP9 decoder cache ready:',platform);raise SystemExit
# GNU make does not support spaces in source paths. Keep its private source
# snapshot in the derived directory, never change the vendor or MOD input.
snapshot=root/'source'
if not snapshot.exists():shutil.copytree(source,snapshot,ignore=lambda _,names:[n for n in names if n.startswith('.') or n=='__MACOSX'])
build=root/'objects';build.mkdir(exist_ok=True)
flags=f'-target {target} -isysroot {sdk} -O2 -fPIC'
env=dict(os.environ,CC=clang,CXX=clang,AR='/usr/bin/ar',RANLIB='/usr/bin/ranlib',CFLAGS=flags,CXXFLAGS=flags,LDFLAGS=f'-target {target} -isysroot {sdk}')
# Xcode exports BUILD_ROOT; libvpx uses the same name for generated headers.
env['BUILD_ROOT']='.'
for key in ['BUILD_PFX','SRC_PATH','SRC_PATH_BARE','MAKEFLAGS','MFLAGS','MAKEOVERRIDES','MAKELEVEL']:
    env.pop(key,None)
args=['sh' ,str(snapshot/'configure'),'--target=generic-gnu','--disable-vp8','--disable-vp9-encoder','--disable-examples','--disable-tools','--disable-docs','--disable-unit-tests','--disable-webm-io','--disable-libyuv','--disable-vp9-highbitdepth','--disable-runtime-cpu-detect','--enable-pic','--enable-static','--disable-shared','--size-limit=4096x4096']
subprocess.run(args,cwd=build,env=env,check=True)
subprocess.run(['make','-j2','libvpx.a'],cwd=build,env=env,check=True)
shutil.copy2(build/'libvpx.a',library);receipt.write_text(json.dumps(recipe,sort_keys=True)+'\n')
print('Built VP9 decoder:',platform,library.stat().st_size,'bytes')
