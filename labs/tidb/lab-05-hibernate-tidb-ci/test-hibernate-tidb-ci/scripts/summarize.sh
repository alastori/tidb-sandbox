#!/usr/bin/env bash
set -euo pipefail
SUM=build/summary.txt
if [[ -f "$SUM" ]]; then
  printf "\n==== Test Summary ====\n"
  cat "$SUM"
  mkdir -p artifacts
  cp -r build/test-results/test artifacts/junit-xml
  cp -r build/reports/tests/test artifacts/html-report
  cp "$SUM" artifacts/
  echo "Artifacts under ./artifacts (junit-xml, html-report, summary.txt)"
else
  echo "No summary produced."; exit 1
fi
