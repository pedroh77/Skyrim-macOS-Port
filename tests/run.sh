#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
h=upstream/recomp/host
cc -std=gnu11 -Imacos -I"$h" -include tests/linux_time.h tests/null_probe.c macos/{FNVPad,FNVDisplay,FNVProbe,ProbeRuntime}.c "$h"/{d3d9,d3d9_null,dinput,gheap,input,com}.c -lm -pthread -o "$out/probe"
"$out/probe"
