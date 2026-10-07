"""Keep current cloud evidence and runbook validation limits in sync."""
import hashlib
import json
from pathlib import Path
import re
import unittest

LAB = Path(__file__).resolve().parents[1]
DOC = LAB / "lab-04-cloudsql-gcs-local-tidb.md"
EVIDENCE = LAB / "evidence/all-paths-cloud-20261007.json"

class CloudValidationClaims(unittest.TestCase):
    def test_prerequisite_names_remaining_route_limits(self):
        text = DOC.read_text()
        prerequisites = text.split("## Prerequisites", 1)[1].split("## Step 1", 1)[0]
        self.assertIn("Private-IP and IAP routes are not validated.", prerequisites)
        self.assertNotIn("Bucket provisioning and the VM export path are untested.", prerequisites)

    def test_fresh_evidence_does_not_erase_limits(self):
        text = DOC.read_text()
        self.assertIn("**Fresh cloud branch tests (2026-10-07):**", text)
        self.assertNotIn("The revised procedure has not had a fresh Cloud SQL export/import replay.", text)
        self.assertIn("Artifact preservation does not validate a usable later-DM handoff.", text)

    def test_replica_limit_is_current(self):
        self.assertNotIn("Read-replica exports and concurrent writes were not tested.", DOC.read_text())

    def test_target_rejection_names_the_native_precheck(self):
        failures = json.loads(EVIDENCE.read_text())["real_failure_tests"]
        self.assertIn("Populated-target repeat IMPORT INTO rejected by TiDB precheck (Error 8173).", failures)

    def test_mutation_replay_is_bound_to_subset_jobs(self):
        receipt = json.loads(EVIDENCE.read_text())
        mutation = next(case for case in receipt["cloud_cases"] if case["id"] == "public_subset_filesize_mutation")
        self.assertTrue(mutation.get("mutation_replay_uses_the_listed_subset_jobs", False))

    def test_receipt_matches_only_verified_routes_and_code(self):
        self.assertTrue(EVIDENCE.is_file(), "Fresh cloud evidence receipt is missing")
        receipt = json.loads(EVIDENCE.read_text())
        self.assertEqual(receipt["routes"], {"A": "passed", "B": "blocked", "C": "blocked", "D": "passed"})
        self.assertEqual(receipt["cloud_finished_jobs"], sum(len(case["jobs"]) for case in receipt["cloud_cases"]))
        self.assertTrue(receipt["cleanup"]["all_owned_active_resources_absent"])
        self.assertTrue(receipt["cleanup"]["possible_GCS_soft_delete_storage_charges"])
        blocks = re.findall(r"^```bash\n(.*?)^```[ \t]*$", DOC.read_text(), re.M | re.S)
        digest = hashlib.sha256(json.dumps(blocks, ensure_ascii=False).encode()).hexdigest()
        revision = json.loads((LAB / "evidence/documented-contracts-20261007.json").read_text())
        self.assertEqual(revision["status"], "documentation_and_offline_revision_only")
        self.assertFalse(revision["current_cloud_replay_performed"])
        self.assertFalse(revision["current_database_replay_performed"])
        self.assertEqual(revision["historical_cloud_receipt_sha256"], hashlib.sha256(EVIDENCE.read_bytes()).hexdigest())
        self.assertEqual(revision["historical_cloud_tested_document_sha256"], receipt["tested_document_sha256"])
        self.assertEqual(revision["historical_cloud_tested_bash_blocks_sha256"], receipt["tested_bash_blocks_sha256"])
        self.assertEqual(revision["historical_routes"], receipt["routes"])
        self.assertEqual(revision["current_document_sha256"], hashlib.sha256(DOC.read_bytes()).hexdigest())
        self.assertEqual(digest, revision["current_bash_blocks_sha256"])
        self.assertNotEqual(digest, receipt["tested_bash_blocks_sha256"])
        self.assertTrue(revision["changed_bash_fences"])

if __name__ == "__main__":
    unittest.main()
