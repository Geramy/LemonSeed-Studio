#!/bin/bash
# Record the bundled R9700 fixtures on the Mac running mac_linuxgpu.
#
#   Packages/StudioTelemetry/Tools/capture_fixtures.sh [idle|load|all]
#
# idle: 60 s while upstream amdgpu runs in a session (waits up to an hour
# for one). load: waits up to two hours for gpu_busy_percent >= 15 (a
# request already running; this tool never sends one) and records 60 s.
# Only a read-only observer is opened. Then run `swift test`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../Sources/StudioTelemetry/Resources/Fixtures"
what="${1:-all}"
if [[ $what == idle || $what == all ]]; then
    python3 "$here/capture_fixture.py" --name r9700-idle \
        --description "AMD Radeon AI PRO R9700 over Thunderbolt, upstream amdgpu in a session, no GPU work" \
        --wait-for-ready 3600 --duration 60 -o "$out/r9700-idle.json"
fi
if [[ $what == load || $what == all ]]; then
    python3 "$here/capture_fixture.py" --name r9700-load \
        --description "AMD Radeon AI PRO R9700 over Thunderbolt while a GPU workload runs" \
        --wait-for-ready 3600 --wait-for-load 7200 --threshold 15 --duration 60 -o "$out/r9700-load.json"
fi
