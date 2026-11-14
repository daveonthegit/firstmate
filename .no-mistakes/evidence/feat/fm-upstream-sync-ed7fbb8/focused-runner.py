# Temporary selector runner: executes existing behavior functions unchanged.
# Bare top-level test calls are omitted only to select relevant cases.
import concurrent.futures,os,pathlib,re,subprocess,signal,json,time
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M7CF729TEKTFDZA3QD5ECVS9')
T=E/'tmp';T.mkdir(exist_ok=True)
selected={
'fm-stow-guard':None,
'fm-placement': ['test_adaptive_capacity_placement'],
'fm-teardown':['test_record_export_archives_before_teardown_or_preserves_sources_on_failure','test_landed_on_other_origin_branch_with_stale_refs_allows','test_refresh_failure_does_not_read_as_landed','test_refreshed_refs_still_refuse_unreachable_commits'],
'fm-pr-merge':['test_expected_head_matching_reaches_each_forge','test_expected_head_mismatch_refuses_before_merge','test_expected_head_push_after_verify_is_refused_by_the_forge','test_expected_head_bad_inputs_refuse_before_effects'],
'fm-watcher-lock':['test_lock_real_directory_residue','test_lock_real_directory_live_nested_owner','test_lock_real_directory_named_refusal','test_lock_real_directory_permission_refusal'],
'fm-capacity-auto':['test_remote_routes_do_not_consume_adaptive_lanes','test_fixed_mode_is_unchanged','test_real_host_auto_smoke'],
}
# The placement suite uses fm_test_run; run its existing small suite directly.
selected['fm-placement']=None
results={}
def one(item):
 n,cases=item; source=R/'tests'/(n+'.test.sh'); temp=None
 if cases is not None:
  s=source.read_text()
  for case in cases:assert re.search(r'^'+case+r'\(\)',s,re.M),case
  s=re.sub(r'^test_\w+\s*$',';',s,flags=re.M)
  # A colon is a no-op; semicolon alone is not a command.
  s=re.sub(r'^;$',':',s,flags=re.M)
  s+='\n'+'\n'.join(cases)+'\nprintf "FOCUSED_CHECK_COMPLETE\\n"\n'
  temp=R/'tests'/('.live-'+n+'.test.sh');temp.write_text(s);source=temp
 env=dict(os.environ,TMPDIR=str(T))
 try:
  with (E/(n+'-focused.log')).open('w') as f:
   p=subprocess.Popen(['bash',str(source)],env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
   try:rc=p.wait(timeout=165)
   except subprocess.TimeoutExpired:
    os.killpg(p.pid,signal.SIGTERM)
    try:p.wait(timeout=10)
    except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
    rc='timeout'
  results[n]={'exit':rc,'selectors':cases or ['existing file']}
  (E/'focused-results.json').write_text(json.dumps(results,indent=2))
  return n,rc
 finally:
  if temp:temp.unlink(missing_ok=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
 for n,rc in ex.map(one,selected.items()):print(n,rc,flush=True)
