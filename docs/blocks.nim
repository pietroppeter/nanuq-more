## Blocks shared by the nanuq-more docs.

import std/[xmltree, strutils]
import nimib

const
  pyKeywords = ["False", "None", "True", "and", "as", "assert", "class", "def", "del", "elif",
    "else", "except", "for", "from", "if", "import", "in", "is", "lambda", "not", "or", "pass",
    "raise", "return", "try", "while", "with", "yield"]
  pyBuiltins = ["print", "str", "int", "float", "dict", "zip", "tuple", "type", "isinstance", "len"]

func highlightPython*(code: string): string =
  ## Python with highlight.js classes, so it is highlighted without loading anything.
  var i = 0
  template span(cls: string, a, b: int) =
    result.add "<span class=\"hljs-" & cls & "\">" & xmltree.escape(code[a ..< b]) & "</span>"
  while i < code.len:
    let c = code[i]
    if c == '#':
      let j = (let e = code.find('\n', i); if e < 0: code.len else: e)
      span("comment", i, j); i = j
    elif c in {'"', '\''} or (c in {'f', 'r', 'b'} and i + 1 < code.len and code[i + 1] in {'"', '\''} and
         (i == 0 or code[i - 1] notin IdentChars)):
      let start = i
      if c notin {'"', '\''}: inc i
      let q = code[i]
      let triple = code.continuesWith($q & $q & $q, i)
      let close = if triple: $q & $q & $q else: $q
      i += close.len
      while i < code.len and not code.continuesWith(close, i):
        if code[i] == '\\': inc i
        inc i
      i = min(code.len, i + close.len)
      span("string", start, i)
    elif c in Digits and (i == 0 or code[i - 1] notin IdentChars):
      var j = i
      while j < code.len and code[j] in Digits + {'.', '_', 'e'}: inc j
      span("number", i, j); i = j
    elif c in IdentStartChars:
      var j = i
      while j < code.len and code[j] in IdentChars: inc j
      let w = code[i ..< j]
      if w in pyKeywords: span("keyword", i, j)
      elif w in pyBuiltins: span("built_in", i, j)
      else: result.add w
      i = j
    else:
      result.add xmltree.escape($c); inc i

type SourceLang* = enum
  slNim = "nim"         ## Nim source that is shown, not run (highlighted when the page renders)
  slPython = "python"   ## Python source
  slOutput = "output"   ## what a cell printed

newNbBlock(NbSource):
  lang: SourceLang
  code: string
  toHtml:
    case blk.lang
    of slNim: "<pre><code class=\"language-nim hljs\">" & highlightNim(blk.code) & "</code></pre>"
    of slPython: "<pre><code class=\"language-python hljs\">" & highlightPython(blk.code) & "</code></pre>"
    of slOutput: "<pre class=\"nb-output\">" & xmltree.escape(blk.code) & "</pre>"

func source*(nb: var Nb, code: string, lang = slNim) =
  nb.add newNbSource(lang = lang, code = code)

template nbSource*(code: string, lang = slNim) =
  ## Code shown as is: an excerpt of the repository, or code a macro generated.
  nb.source(code, lang)

const sourceStyle* = """
<style>
pre:has(> code.language-python)::before { content: "python"; }
pre:has(> code.language-python):has(+ pre.nb-output) { border-radius: 6px 6px 0 0; }
</style>
"""
