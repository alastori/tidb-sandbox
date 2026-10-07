"""Offline checks for the reviewed contracts; no provider/network validation.
Run: python3 tests/test_documented_contracts.py
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

LAB = Path(__file__).resolve().parents[1]
TEXT = (LAB / "lab-04-cloudsql-gcs-local-tidb.md").read_text()
ROOT = Path(os.environ.get("TIDB_LAB_TEST_ROOT", str(Path.home() / ".cache/tidb-sandbox/documented-contract-tests")))
ROOT.mkdir(parents=True, exist_ok=True)

def section(start, end):
    return TEXT.split(start, 1)[1].split(end, 1)[0]

class DocumentedContracts(unittest.TestCase):
    def test_private_routes_are_distinct_from_proxy_and_ssh(self):
        connection = section("### 5b.", "### 5c.")
        for term in ["private services access", "service range", "desktop route", "return route", "does not create a network path"]:
            self.assertIn(term, connection)
        self.assertIn("TCP 443", TEXT)
        self.assertIn("TCP 3307", TEXT)
        self.assertIn("13317 is the local listener", TEXT)
        self.assertIn("(#d1-create-a-test-cloud-sql-instance) creates a public-IP source", connection)

    def test_vm_network_readback_is_not_a_route_proof(self):
        for a, b in [("### F1.", "### F2."), ("### G1.", "### G2.")]:
            part = section(a, b)
            self.assertIn("networkInterfaces.network,networkInterfaces.subnetwork", part)
            self.assertIn("does not prove source reachability", part)

    def test_iap_permissions_and_false_branch_are_explicit(self):
        for term in ["35.235.240.0/20", "TCP 22", "roles/iap.tunnelResourceAccessor", "automatically use IAP", "SSH authentication"]:
            self.assertIn(term, TEXT)
        self.assertIn("`USE_IAP=false` only omits the explicit tunnel flag", TEXT)

    def test_explicit_lists_and_column_mapping_are_bounded(self):
        options = section("### 6a.", "### 6b.")
        self.assertIn("approved base tables", options)
        self.assertIn("explicit table lists can include views", options)
        schema = section("### 6c.", "### 6d.")
        for term in ["generated or invisible columns", "stop before import", "`SKIP_ROWS=1` skips the header", "does not map fields by column name"]:
            self.assertIn(term, schema)
        self.assertNotIn("Views are skipped by default.", section("### 6b.", "### 6c."))

    def test_lock_and_metadata_claims_stay_conservative(self):
        self.assertIn("Keep RELOAD for this pinned flush export", TEXT)
        self.assertIn("Metadata preservation is not a DM-readiness check", TEXT)
        self.assertIn("missing or empty coordinates", TEXT)
        self.assertIn("Artifact preservation does not validate a usable later-DM handoff.", TEXT)

    def test_capacity_does_not_claim_a_small_data_exception(self):
        self.assertIn("does not establish an exception to the official capacity prerequisites", TEXT)
        self.assertIn("satisfy the full published temporary-space prerequisite", TEXT)
        self.assertNotIn("90 GiB", TEXT)

    def test_historical_runtime_and_current_offline_checks_are_distinct(self):
        appendix = section("## Appendix I", "## References")
        self.assertIn("Documentation review and offline revision checks", appendix)
        self.assertIn("revised SSH/SCP commands were not replayed against a cloud VM", appendix)
        self.assertIn("Private-IP and IAP routes are not validated.", TEXT)
        self.assertIn("documented-contracts-20261007.json", appendix)

    def test_all_ssh_and_copy_calls_use_the_selected_login_and_flags(self):
        blocks = re.findall(r"^```bash\n(.*?)^```[ \t]*$", TEXT, re.M | re.S)
        ssh = [b for b in blocks if "gcloud compute ssh" in b]
        scp = [b for b in blocks if "gcloud compute scp" in b]
        for b in ssh:
            self.assertNotIn('gcloud compute ssh "$VM"', b)
            self.assertIn('"$VM_LOGIN"', b)
            self.assertIn('"${VM_SSH_ARGS[@]}"', b)
        for b in scp:
            self.assertIn('${VM_LOGIN}:', b)
            self.assertIn('"${VM_SCP_ARGS[@]}"', b)
            self.assertNotIn('"${VM_SSH_ARGS[@]}"', b.split("gcloud compute scp", 1)[1].split("printf", 1)[0])

    def run_reuse(self, iap="false", missing_key=False, bad_user=False, malformed_user=False, relative_key=False, whitespace_key=False):
        reuse = section("### G1.", "### G2.")
        blocks = re.findall(r"^```bash\n(.*?)^```[ \t]*$", reuse, re.M | re.S)
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            root = Path(tmp)
            key = root / ("fixture key path" if whitespace_key else "fixture-key")
            if not missing_key:
                key.write_text("not a key; offline argument fixture only")
            variables = {"WORK_DIR": str(root), "VM": "fixture-vm", "VM_PROJECT": "fixture-project", "ZONE": "us-central1-a", "REGION": "us-central1", "EXPORT_SERVICE_ACCOUNT": "fixture@fixture-project.iam.gserviceaccount.com", "USE_IAP": iap, "VM_SSH_USER": "your-ssh-user" if bad_user else "bad;user" if malformed_user else "fixture_user", "VM_SSH_KEY": os.path.relpath(key) if relative_key else str(key)}
            setup = "set -euo pipefail\n" + "\n".join(k + "=" + shlex.quote(v) for k, v in variables.items()) + "\n"
            capture = """gcloud() {
  printf '%q ' "$@" >> "$WORK_DIR/calls"; printf '\n' >> "$WORK_DIR/calls"
  case "$*" in
    *'value(status)'*) printf 'RUNNING\n';;
    *'value(serviceAccounts[0].email)'*) printf '%s\n' "$EXPORT_SERVICE_ACCOUNT";;
    *'value(id)'*) printf '123456\n';;
    *'networkInterfaces.network,networkInterfaces.subnetwork'*) printf 'NETWORK_READBACK\n';;
    *) printf 'FORBIDDEN_CALL\n' >&2; return 97;;
  esac
}
"""
            code = "\n".join(blocks[2:])
            dump = "\nprintf 'LOGIN=%s\n' \"$VM_LOGIN\"\nprintf 'SSH=%s\n' \"${VM_SSH_ARGS[@]}\"\nprintf 'SCP=%s\n' \"${VM_SCP_ARGS[@]}\"\n"
            r = subprocess.run(["/bin/bash", "--noprofile", "--norc"], input=setup + capture + code + dump, text=True, capture_output=True)
            calls = (root / "calls").read_text() if (root / "calls").exists() else ""
            self.assertNotIn("FORBIDDEN_CALL", r.stderr)
            if iap not in ("true", "false") or missing_key or bad_user or malformed_user or relative_key or whitespace_key:
                self.assertNotEqual(r.returncode, 0)
                self.assertFalse((root / "vm.env").exists())
                if missing_key or bad_user or malformed_user or relative_key or whitespace_key:
                    self.assertEqual(calls, "", "Invalid identity must stop before cloud commands")
                return
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("LOGIN=fixture_user@fixture-vm", r.stdout)
            ssh = [s[4:] for s in r.stdout.splitlines() if s.startswith("SSH=")]
            scp = [s[4:] for s in r.stdout.splitlines() if s.startswith("SCP=")]
            for args, prefix in [(ssh, "--ssh-flag"), (scp, "--scp-flag")]:
                for flag in ["--plain", prefix + "=-i" + str(key), prefix + "=-oBatchMode=yes", prefix + "=-oStrictHostKeyChecking=yes"]:
                    self.assertIn(flag, args)
                self.assertEqual("--tunnel-through-iap" in args, iap == "true")
            self.assertNotIn("--ssh-flag", " ".join(scp))
            self.assertNotIn("--scp-flag", " ".join(ssh))
            self.assertIn("VM_MODE=reused", (root / "vm.env").read_text())
            self.assertNotIn("set-metadata", calls)
            self.assertNotIn("add-metadata", calls)

    def test_bootstrap_session_and_both_transfers_keep_identity_and_flags(self):
        blocks = re.findall(r"^```bash\n(.*?)^```[ \t]*$", TEXT, re.M | re.S)
        bootstrap = next(b for b in blocks if "control.env" in b and "gcloud compute ssh" in b)
        downloads = next(b for b in blocks if "gcloud compute scp" in b and "run.env" in b)
        tools = next(b for b in blocks if "VM_CHECKS" in b)
        for mode in ["created", "reused"]:
            for iap in ["false", "true"]:
                with self.subTest(mode=mode, iap=iap), tempfile.TemporaryDirectory(dir=ROOT) as tmp:
                    root = Path(tmp)
                    part = section("### F1.", "### F2.") if mode == "created" else section("### G1.", "### G2.")
                    start = "VM_SSH_ARGS=" if mode == "created" else "VM_LOGIN="
                    stop = "printf 'Creating disposable VM:" if mode == "created" else "printf 'VM checks passed."
                    args_code = part[part.index(start):part.index(stop)]
                    values = {"WORK_DIR": str(root), "GCP_PROJECT": "fixture-project", "INSTANCE": "fixture-source", "BUCKET": "fixture-bucket", "VM": "fixture-vm", "VM_PROJECT": "fixture-project", "VM_MODE": mode, "ZONE": "us-central1-a", "RUN_ID": "fixture-run", "VM_DIR": "fixture-dir", "GCS_URI": "gs://fixture-bucket/fixture-run", "EXPORT_SERVICE_ACCOUNT": "fixture@fixture-project.iam.gserviceaccount.com", "USE_IAP": iap, "VM_SSH_USER": "fixture_user", "VM_SSH_KEY": str(root / "fixture-key")}
                    setup = "set -euo pipefail\n" + "\n".join(k + "=" + shlex.quote(v) for k, v in values.items()) + "\n"
                    capture = "gcloud() { printf '%q ' \"$@\" >> \"$WORK_DIR/calls\"; printf '\\n' >> \"$WORK_DIR/calls\"; }\n"
                    code = setup + args_code + capture + bootstrap + downloads + (tools if mode == "reused" else "")
                    r = subprocess.run(["/bin/bash", "--noprofile", "--norc"], input=code, text=True, capture_output=True)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    printed = next(line for line in r.stdout.splitlines() if line.startswith("gcloud compute ssh "))
                    persistent = subprocess.run(["/bin/bash", "--noprofile", "--norc"], input=setup + capture + printed + "\n", text=True, capture_output=True)
                    self.assertEqual(persistent.returncode, 0, persistent.stderr)
                    calls = [shlex.split(line) for line in (root / "calls").read_text().splitlines()]
                    ssh_calls = [c for c in calls if c[:2] == ["compute", "ssh"]]
                    scp_calls = [c for c in calls if c[:2] == ["compute", "scp"]]
                    self.assertEqual(len(ssh_calls), 3 if mode == "reused" else 2)
                    self.assertEqual(len(scp_calls), 4)
                    login = "fixture_user@fixture-vm" if mode == "reused" else "fixture-vm"
                    for call in ssh_calls:
                        self.assertEqual(call[2], login)
                    for call in scp_calls:
                        remotes = [arg for arg in call if ":~/" in arg]
                        self.assertTrue(remotes)
                        self.assertTrue(all(arg.startswith(login + ":~/") for arg in remotes))
                    for call in calls:
                        self.assertEqual("--tunnel-through-iap" in call, iap == "true")
                        self.assertEqual("--plain" in call, mode == "reused")
                        if mode == "reused":
                            prefix = "--ssh-flag" if call[1] == "ssh" else "--scp-flag"
                            self.assertIn(prefix + "=-i" + values["VM_SSH_KEY"], call)
                            self.assertIn(prefix + "=-oStrictHostKeyChecking=yes", call)
                            self.assertIn(prefix + "=-oBatchMode=yes", call)
                            other = "--scp-flag" if call[1] == "ssh" else "--ssh-flag"
                            self.assertFalse(any(arg.startswith(other) for arg in call))

    def test_reuse_builds_explicit_identity_for_both_transports(self):
        for iap in ["true", "false"]:
            with self.subTest(iap=iap):
                self.run_reuse(iap)

    def test_reuse_stops_on_missing_key_or_unedited_user(self):
        self.run_reuse(missing_key=True)
        self.run_reuse(bad_user=True)

    def test_reuse_rejects_malformed_user_readable_relative_path_and_whitespace(self):
        for case in ["malformed_user", "relative_key", "whitespace_key"]:
            with self.subTest(case=case):
                self.run_reuse(**{case: True})

    def test_reuse_rejects_invalid_route_setting(self):
        self.run_reuse(iap="invalid")

if __name__ == "__main__":
    unittest.main()
