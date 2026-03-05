#!/bin/bash
# Strace POT compilation to see file I/O

WASM_FILE="${1:-examples/bench.wasm}"

echo "=== Stracing POT compilation ==="
echo "File: $WASM_FILE"
echo ""

# Run terra under strace, looking for file operations
strace -f -e trace=openat,read,write,close -s 200 \
    terra -e "
local POT = require('pot')
local f = io.open('$WASM_FILE', 'rb')
local wasm = f:read('*a')
f:close()
local t0 = os.clock()
local exports = POT.load_module(wasm, { _wasi_args = {} })
local t1 = os.clock()
io.stderr:write(string.format('Compile: %.2f ms\\n', (t1 - t0) * 1000))
" 2>&1 | grep -E "openat|\.so|\.o|tmp|/dev/shm" | head -30
