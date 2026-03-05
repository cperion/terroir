#!/bin/bash
# Watch for file creation during POT compilation

echo "Watching for file I/O during compilation..."

# Use inotifywait if available, otherwise strace with write filter
if command -v inotifywait &> /dev/null; then
    inotifywait -m -r -e create,modify /tmp /dev/shm 2>&1 &
    INOTIFY_PID=$!
    sleep 0.5
fi

terra -e "
local POT = require('pot')
local f = io.open('examples/bench.wasm', 'rb')
local wasm = f:read('*a')
f:close()
local t0 = os.clock()
local exports = POT.load_module(wasm, { _wasi_args = {} })
local t1 = os.clock()
io.stderr:write(string.format('Compile: %.2f ms\\n', (t1 - t0) * 1000))
" 2>&1 | grep -i compile

if [ -n "$INOTIFY_PID" ]; then
    sleep 0.5
    kill $INOTIFY_PID 2>/dev/null
fi

# Check for memory-mapped files
echo ""
echo "Checking /dev/shm for Terra files:"
ls -la /dev/shm/ 2>/dev/null | grep -E "terra|llvm|jit" || echo "No Terra/LLVM files in /dev/shm"

# Check /tmp
echo ""
echo "Checking /tmp for terra files:"
ls -la /tmp/terra* 2>/dev/null || echo "No terra files in /tmp"
