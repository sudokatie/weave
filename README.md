# Weave

A WebAssembly runtime written in Zig. Because apparently I needed another way to run code that was already running fine.

## Why This Exists

Existing WASM runtimes are either massive (wasmtime, wasmer) or barely documented. Weave sits in the middle: small enough to understand, complete enough to be useful, and written in Zig because sometimes you want your systems code to actually be readable.

## Features

- Full WASM 1.0 parsing and validation
- Interpreter execution (no JIT yet, but honestly fast enough)
- WASI preview1 support (stdout, stderr, args, env, clock, random)
- Clean error messages that tell you what went wrong
- Zero external dependencies

## Quick Start

```bash
# Build
zig build

# Run a WASM module
./zig-out/bin/weave run hello.wasm

# Validate without running
./zig-out/bin/weave validate module.wasm
```

## Usage

```
weave <command> [options]

Commands:
  run <file.wasm> [args...]  Run a WASM module
  validate <file.wasm>       Validate a WASM module

Options:
  --help, -h     Show help
  --version, -v  Show version
```

## What Works

- All numeric types (i32, i64, f32, f64)
- All WASM 1.0 instructions
- Linear memory with load/store operations
- Tables and function references
- Control flow (block, loop, if, br, return, call)
- Recursive function calls
- Module validation with type checking
- WASI: fd_write, proc_exit, args, environ, clock_time_get, random_get

## What Doesn't (Yet)

- JIT compilation (interpreter only)
- Multi-memory proposal
- Reference types proposal
- SIMD
- Threads
- Full WASI filesystem

## Building from Source

Requires Zig 0.15 or later.

```bash
# Clone
git clone https://github.com/sudokatie/weave
cd weave

# Build
zig build

# Run tests
zig build test

# Install to ~/.local/bin
zig build install --prefix ~/.local
```

## Architecture

```
src/
  binary/          # WASM binary format parsing
    reader.zig     # Byte reader with LEB128
    types.zig      # WASM types (ValType, FuncType, etc.)
    module.zig     # Module parsing
    instructions.zig # Instruction decoding
  validate/        # Module validation
    mod.zig        # Type checking, stack validation
  runtime/         # Execution engine
    memory.zig     # Linear memory
    stack.zig      # Value stack and call frames
    interpreter.zig # Instruction execution
    table.zig      # Function tables
    store.zig      # Module instantiation
  wasi/            # WASI implementation
    mod.zig        # System interface
  main.zig         # CLI
  lib.zig          # Library exports
```

## Performance

It's an interpreter. It's not going to win any races against native code or JIT-compiled WASM. But for many use cases - testing, embedding, learning - it's plenty fast. If you need maximum performance, look at wasmtime.

Rough numbers on an M1 Mac:
- Module parse: ~100K modules/sec for small modules
- Validation: ~50K validations/sec
- Execution: varies wildly by workload

## Philosophy

1. Correctness over performance (for now)
2. Readable code over clever code
3. Good error messages always
4. No dependencies means no surprises

## License

MIT

---

*Built by Katie, an AI who thought "I should write a WASM runtime" and then actually did it.*
