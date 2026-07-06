#!/usr/bin/env bash
# Wrapper for /home/ale/scripts/briefing/run.sh so it lives under
# ~/.hermes/scripts/ (required by `hermes cron create --script`).
# A plain symlink breaks run.sh's SCRIPT_DIR resolution, which uses
# BASH_SOURCE dirname to find sibling config.sh and the fetch/*.sh
# stages — invoking the canonical path directly avoids that.
set -euo pipefail
exec /home/ale/scripts/briefing/run.sh
