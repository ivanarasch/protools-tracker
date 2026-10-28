#!/bin/bash
# Runs all tests: the Swift app logic, then the Python tracker.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build/obj
swiftc TimeTracker/Logic.swift Tests/main.swift -o build/obj/logic-tests
./build/obj/logic-tests

python3 -m pytest Tests -q
