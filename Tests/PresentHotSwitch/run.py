from pathlib import Path
import os,subprocess,sys
project=Path(__file__).resolve().parents[2]
output=Path(os.environ['PJDV_TEST_ROOT']);output.mkdir(exist_ok=False)
runtime=Path(os.environ.get('PJDV_RUNTIME_SOURCE','/Volumes/Switch-iOS-Dev/Runtime/PJDV/dm/gfx/nvn'))
source=(runtime/'nvn_mtl.m').read_text()
start=source.index('// g_pq_mu covers the worker');end=source.index('// 进后台前（mtl_drain）',start)
fixed=source[start:end]
idle_start=source.index('static int wait_present_idle(')
fixed+=source[idle_start:source.index('int pjdv_metal_session_end(',idle_start)]
fixed+=source[source.index('#define PRING 1024'):source.index('static _Atomic uint64_t g_drawable_ns')]
original=Path(sys.argv[1]).read_text();original=original[original.index('static void link_sync(void) {'):];original=original[:original.index('// 进后台前（mtl_drain）')]
for name,text in [('original',original),('fixed',fixed)]:
 case=output/name;case.mkdir()
 include,fixture=('link_sync_under_test.inc','main.m') if name=='original' else ('link_lifecycle_under_test.inc','lifecycle.m')
 (case/include).write_text(text)
 command=['xcrun','clang','-fobjc-arc','-fblocks','-O2','-fsanitize=address,undefined','-framework','Foundation','-framework','QuartzCore','-I',str(case),'-I',str(runtime),str(project/'Tests/PresentHotSwitch'/fixture),'-o',str(case/'switch-test')]
 subprocess.run(command,check=True)
 result=subprocess.run([str(case/'switch-test')],capture_output=True,text=True,timeout=30)
 (case/'result.txt').write_text(result.stdout+result.stderr)
 if name=='original':
  assert result.returncode==2 and 'active request fell through' in result.stderr,result
  print('EXPECTED FAIL: unmodified build18 loses active display-link request')
 else:
  assert result.returncode==0,result.stderr
  print(result.stdout.strip())
  tsan_case=case/'switch-test-tsan'
  tsan_build=[('-fsanitize=thread' if arg=='-fsanitize=address,undefined' else arg) for arg in command[:-1]]
  subprocess.run(tsan_build+[str(tsan_case)],check=True)
  result=subprocess.run([str(tsan_case)],capture_output=True,text=True,timeout=30)
  (case/'result-tsan.txt').write_text(result.stdout+result.stderr)
  assert result.returncode==0,result.stderr
  print('ThreadSanitizer:',result.stdout.strip())
