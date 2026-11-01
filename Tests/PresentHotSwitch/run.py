from pathlib import Path
import os,subprocess,sys
project=Path(__file__).resolve().parents[2]
output=Path(os.environ['PJDV_TEST_ROOT']);output.mkdir(exist_ok=False)
runtime=Path(os.environ.get('PJDV_RUNTIME_SOURCE','/Volumes/Switch-iOS-Dev/Runtime/PJDV/dm/gfx/nvn'))
source=(runtime/'nvn_mtl.m').read_text()
start=source.index('static void link_sync(void) {');end=source.index('// 进后台前（mtl_drain）',start)
fixed=source[start:end]
original=Path(sys.argv[1]).read_text();original=original[original.index('static void link_sync(void) {'):];original=original[:original.index('// 进后台前（mtl_drain）')]
for name,text in [('original',original),('fixed',fixed)]:
 case=output/name;case.mkdir();(case/'link_sync_under_test.inc').write_text(text)
 command=['xcrun','clang','-fobjc-arc','-fblocks','-fsanitize=address,undefined','-framework','Foundation','-framework','QuartzCore','-I',str(case),'-I',str(runtime),str(project/'Tests/PresentHotSwitch/main.m'),'-o',str(case/'switch-test')]
 subprocess.run(command,check=True)
 result=subprocess.run([str(case/'switch-test')],capture_output=True,text=True)
 (case/'result.txt').write_text(result.stdout+result.stderr)
 if name=='original':
  assert result.returncode==2 and 'active request fell through' in result.stderr,result
  print('EXPECTED FAIL: unmodified build18 loses active display-link request')
 else:
  assert result.returncode==0,result.stderr
  print(result.stdout.strip())
