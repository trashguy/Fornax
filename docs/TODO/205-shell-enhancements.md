# Phase 205: Shell Enhancements

## Status: Done

## Goal

Add control flow and conditional operators to fsh. All changes to existing `cmd/fsh/main.zig`.

## Depends On

- Phase 24 (shell) — done

---

## 205.1: `#` comment support (~10 lines)

Ignore `#` to end-of-line outside quotes during tokenization.

## 205.2: `&&` / `||` operators (~30 lines)

Short-circuit: `cmd1 && cmd2` runs cmd2 only if `$?`==0. `cmd1 || cmd2` runs cmd2 only if `$?`!=0.

## 205.3: `test` / `[` builtin (~50 lines)

`test -f path` (file exists), `test -d path` (dir exists), `test "$a" = "$b"` (string equal), `test "$a" != "$b"`. Sets exit status 0/1.

## 205.4: `if/else/fi` (~60 lines)

```
if test -f /boot/cat; then
    echo "cat exists"
else
    echo "no cat"
fi
```

## 205.5: `while/do/done` (~40 lines)

```
while test -f /tmp/running; do
    ps
done
```

---

## Files

| File | Change |
|------|--------|
| `cmd/fsh/main.zig` | All changes in existing file |

**Phase 205 total: ~190 lines added. No new files. No kernel changes.**

---

## Verify

1. `if test -f /boot/cat; then echo yes; fi` → "yes"
2. `echo a && echo b` → both printed
3. `false || echo fallback` → "fallback"
4. `# this is a comment` → no output
5. `while test -f /tmp/running; do ps; done` → loops until file removed
