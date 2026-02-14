# Phase 24: Shell

## Goal

A minimal interactive shell — the first program where a user types commands
and things happen. This is the "it feels like an OS" milestone.

## Decision Points (discuss before implementing)

- **How minimal?** Options:
  1. Bare minimum: read line, split on spaces, spawn program, wait. No pipes,
     no redirection, no variables.
  2. Basic: above + simple PATH lookup, cd, exit builtins
  3. Plan 9 rc-style: slightly richer, `$var`, `; &&`, but still simple
- **Program lookup**: Where does the shell find executables? Hardcoded `/bin`?
  A PATH variable? Search the namespace?
- **Builtins**: What's built into the shell vs external commands?
  - `cd` must be builtin (changes shell's own namespace)
  - `exit` must be builtin
  - `ls`, `cat`, `echo` — could be external programs or builtins. External is
    more correct but requires those programs to exist.

## Minimal Design

```
shell loop:
  1. Print prompt ("fornax% ")
  2. Read line from /dev/console
  3. Parse: command = first word, args = rest
  4. If builtin (cd, exit): handle directly
  5. Else: spawn("/bin/{command}"), wait for it to exit
  6. Goto 1
```

## Verify

1. Shell prints prompt, waits for input
2. Type "hello" → shell spawns /bin/hello, hello runs, shell prompts again
3. Type "exit" → shell exits
4. This is Milestone 6: interactive OS
