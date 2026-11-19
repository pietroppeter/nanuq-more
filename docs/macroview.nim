## Macro expansions for the distributions deep dive (docs/distributions.nim):
## what `continuous`, `discrete` and `polarsExpr` write, expanded from the real
## source at compile time, so the page always shows the code the plugin is
## built from.

import std/[macros, strutils, os]
import polarsplugin
import nanuqmore/distmacro

const repoRoot = currentSourcePath.parentDir.parentDir

proc plainNames(n: NimNode): NimNode =
  ## `n` with generated symbols turned back into the plain names they were made from.
  case n.kind
  of nnkSym, nnkIdent: result = ident(($n).split('`')[0])
  of nnkOpenSymChoice, nnkClosedSymChoice: result = ident($n[0])
  of nnkNone, nnkEmpty, nnkLiterals: result = n
  else:
    result = copyNimNode(n)
    for c in n: result.add plainNames(c)
    # quote binds `a[i]` to a call of the `[]` symbol: write it back as brackets
    if result.kind in nnkCallKinds and result[0].kind == nnkIdent:
      if result[0].eqIdent("[]"):
        result = newTree(nnkBracketExpr, result[1 .. ^1])
      elif result[0].eqIdent("[]="):
        result = newAssignment(newTree(nnkBracketExpr, result[1 .. ^2]), result[^1])

proc tidyGensyms*(n: NimNode): string =
  ## The code of `n`, as a person would write it.
  repr(plainNames(n))

proc blockOf*(text, start: string): string =
  ## The lines of `text` from the first one starting with `start` to the next blank line.
  var keep = false
  var got: seq[string]
  for line in text.splitLines:
    if line.startsWith(start): keep = true
    if keep:
      if line.strip.len == 0: break
      got.add line
  got.join("\n")

proc sourceBlock*(path, start: string): string =
  ## `blockOf` a file of the repository.
  blockOf(readFile(repoRoot / path), start)

macro expandedDistribution*(path, start: static string): untyped =
  ## What the `continuous`/`discrete` block of `path` starting with `start` expands to.
  let st = parseStmt(blockOf(staticRead(repoRoot / path), start))
  let cmd = st[0]
  let ast =
    if cmd[0].eqIdent("continuous"): getAst(continuous(cmd[1], cmd[2]))
    else: getAst(discrete(cmd[1], cmd[2]))
  newLit(tidyGensyms(ast))

macro expandedPolarsExpr*(code: static string): untyped =
  ## What `{.polarsExpr.}` makes of the proc in `code` (written without the pragma).
  newLit(tidyGensyms(getAst(polarsExpr(parseStmt(code)[0]))))

proc chunks(text: string): seq[string] =
  ## Top-level statements: a line without indentation and the indented lines after it.
  for line in text.splitLines:
    if result.len == 0 or (line.len > 0 and line[0] != ' '): result.add line
    else: result[^1].add "\n" & line

proc procNamed*(text, name: string): string =
  ## The definition (not the forward declaration) of proc `name` in `text`.
  for c in chunks(text):
    let c = c.strip(leading = false)
    if (c.startsWith("proc " & name & "(") or c.startsWith("proc " & name & "*(")) and
       not c.endsWith("{.inline.}"):
      return c
  raise newException(KeyError, "no proc " & name)

proc forwardDecls*(text: string): string =
  ## The forward declarations in `text`.
  var got: seq[string]
  for c in chunks(text):
    let c = c.strip(leading = false)
    if c.startsWith("proc ") and c.endsWith("{.inline.}"): got.add c
  got.join("\n")

proc withoutTemplates*(def: string): string =
  ## `def` with its block of local templates folded into one comment line.
  var names: seq[string]
  var skipping = false
  var lines: seq[string]
  for line in def.splitLines:
    if line.startsWith("  template "):
      names.add line[11 ..< line.find('(')]
      skipping = true
      continue
    if skipping and (line.strip.len == 0 or line.startsWith("    ")): continue
    if skipping:
      lines.add "  # " & $names.len & " local templates: " & names.join(", ")
      skipping = false
    lines.add line
  lines.join("\n")

proc publicProcs*(text: string): seq[string] =
  ## The exported procs in `text`: the plugin functions.
  for c in chunks(text):
    if c.startsWith("proc ") and "*(" in c.splitLines[0]: result.add c.strip(leading = false)
