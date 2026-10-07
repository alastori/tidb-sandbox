"""Offline command-guard tests. Call recording is not provider validation.
Run: python3 tests/test_procedure_guards.py lab-04-cloudsql-gcs-local-tidb.md
"""
import pathlib,re,subprocess,sys,tempfile,unittest,os
DOC=pathlib.Path(sys.argv.pop(1)); os.umask(0o077)
ROOT=pathlib.Path(os.environ.get('TIDB_LAB_TEST_ROOT',str(pathlib.Path.home()/'.cache/tidb-sandbox/procedure-guard-tests'))); ROOT.mkdir(parents=True,exist_ok=True)
TEXT=DOC.read_text(); BLOCKS=re.findall(r'^```bash\n(.*?)^```[ \t]*$',TEXT,re.M|re.S)
def block(prefix):return next(b for b in BLOCKS if b.startswith(prefix))
class ExecutionRegressions(unittest.TestCase):
 def test_auth_checks_refresh_cli_and_adc_without_printing_tokens(self):
  code=block('gcloud auth login --update-adc')
  self.assertIn('gcloud auth print-access-token >/dev/null',code)
  self.assertIn('gcloud auth application-default print-access-token >/dev/null',code)
  for failing in ['none','cli','adc']:
   with self.subTest(failing=failing):
    work=pathlib.Path(tempfile.mkdtemp(dir=ROOT)); (work/'application_default_credentials.json').write_text('Local guard fixture only; not a credential')
    fixture="gcloud() { printf '%s\n' \"$*\" >> \"$CLOUDSDK_CONFIG/calls\"; case \"$*\" in 'auth login --update-adc') return 0;; 'auth print-access-token') test \"$FAILING\" != cli || return 97;; 'auth application-default print-access-token') test \"$FAILING\" != adc || return 98;; *) return 99;; esac; printf 'TOKEN_MUST_NOT_LEAK\n'; }\n"
    r=subprocess.run(['/bin/bash','--noprofile','--norc'],input='set -euo pipefail\n'+fixture+code+'\nprintf PASSED\n',text=True,capture_output=True,env={**os.environ,'CLOUDSDK_CONFIG':str(work),'FAILING':failing})
    self.assertEqual(r.returncode==0,failing=='none'); self.assertNotIn('TOKEN_MUST_NOT_LEAK',r.stdout)
    self.assertEqual('PASSED' in r.stdout,failing=='none')
 def check_skip(self,code,kind):
  for count in ['0','4','missing','invalid']:
   with self.subTest(kind=kind,count=count):
    work=pathlib.Path(tempfile.mkdtemp(dir=ROOT));(work/'results').mkdir()
    (work/'results/source-count.tsv').write_text('table_name\trow_count\n'+('' if count=='missing' else 'empty_table\t'+('bad' if count=='invalid' else count)+'\n'))
    setup='set -euo pipefail\nWORK_DIR='+repr(str(work))+"\nGCP_PROJECT=guard-fixture\nSOURCE_DB=sales_lab\nTARGET_DB=sales_lab\nTABLES=(empty_table)\nGCS_URI=gs://guard-fixture/run\nBASELINE_URI=gs://guard-fixture/run/baseline\nDESKTOP_GCS_CREDENTIALS="+repr(str(work/'results/source-count.tsv'))+"\nTARGET_MYSQL=(capture_mysql)\n"
    capture='gcloud() { printf CLOUD_CALL; return 97; }; capture_mysql() { printf SQL_CALL; return 98; }\n'
    r=subprocess.run(['/bin/bash','--noprofile','--norc'],input=setup+capture+code,text=True,capture_output=True)
    if count=='0':
     self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('CLOUD_CALL',r.stdout);self.assertNotIn('SQL_CALL',r.stdout);self.assertIn('Empty table:',r.stdout)
    elif count=='4':
     self.assertNotEqual(r.returncode,0);self.assertIn('CLOUD_CALL' if kind=='listing' else 'SQL_CALL',r.stdout)
    else:
     self.assertNotEqual(r.returncode,0);self.assertNotIn('CLOUD_CALL',r.stdout);self.assertNotIn('SQL_CALL',r.stdout)
 def test_listing_skips_only_proven_empty_tables(self):self.check_skip(block('for table in "${TABLES[@]}"; do\n'), 'listing')
 def test_import_skips_only_proven_empty_tables(self):self.check_skip(block('TIDB_GCS_CREDENTIALS='), 'import')
 def test_baseline_listing_skips_only_proven_empty_tables(self):
  baseline=next(b for b in BLOCKS if 'BASELINE_URI=' in b and '--rows 0' in b)
  loop=baseline[baseline.index('  for table in \"${TABLES[@]}\"; do'):].rsplit('}',1)[0]
  self.check_skip(loop,'listing')
if __name__=='__main__':unittest.main()
