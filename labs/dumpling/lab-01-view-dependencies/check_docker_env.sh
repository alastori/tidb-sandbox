#!/bin/bash
# A script to perform a pre-flight check for Docker volume mount compatibility.

echo "--- 0. Performing pre-flight check for Docker volume mount ---"
# Create a temporary file to test the mount
TEST_FILE=".docker_mount_test.tmp"
echo "docker-mount-test" > "$TEST_FILE"

# Attempt to run a lightweight container that reads the test file via a volume mount.
# Redirect stderr to /dev/null to hide "Unable to find image" messages on first run.
MOUNT_TEST_OUTPUT=$(docker run --rm -v "$(pwd)/$TEST_FILE:/test_file:ro" alpine cat /test_file 2>/dev/null)

# Clean up the temporary file immediately
rm "$TEST_FILE"

# Check if the output from the container matches the file's content
if [[ "$MOUNT_TEST_OUTPUT" != "docker-mount-test" ]]; then
  echo "-------------------------------------------------------------------"
  echo "ERROR: Docker volume mount test failed from the current directory."
  echo "This is often caused by running from a network drive, a cloud-synced folder"
  echo "(like iCloud), or a path with special characters or permission issues."
  echo
  echo "Please move the entire project folder to a simple, local directory"
  echo "(e.g., ~/Desktop or ~/Documents/dev) and run the script again."
  echo "-------------------------------------------------------------------"
  exit 1
fi
echo "Volume mount check passed."
