#!/usr/bin/env python3
"""Publish only bounded compiler/configuration diagnostics, never raw log tails."""
import pathlib
import re
import sys
from collections import deque

ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
ERROR = re.compile(r'(?:\bfatal error:|\berror:|\bERROR:|\bconfigure: error:|\bxcodebuild: error:|Undefined symbols for architecture|ld: (?:symbol|library|framework).*not found|No rule to make target|C compiler cannot create executables)', re.I)
SENSITIVE = re.compile(r'(?:token|password|passwd|secret|authorization|credential|private.key|bearer|gh[pousr]_|github_pat_)', re.I)
URL = re.compile(r'\b(?:https?|ssh|git)://\S+|\b[\w.+-]+@[\w.-]+\b')
PATH = re.compile(r'(?<![\w])(?:~?/|[A-Za-z]:\\)[^\s\'\"<>|,;:]+')
IDENTIFIER = re.compile(r'\b(?:[0-9a-f]{8}-[0-9a-f-]{27,}|[0-9a-f]{32,}|(?:\d{1,3}\.){3}\d{1,3})\b', re.I)

def summarize(lines):
    hits = deque(maxlen=12)
    for raw in lines:
        text = ANSI.sub('', raw).strip()
        if not ERROR.search(text) or SENSITIVE.search(text):
            continue
        text = URL.sub('[address]', text)
        text = PATH.sub('[path]', text)
        text = IDENTIFIER.sub('[identifier]', text)
        text = ''.join(c for c in text if c.isprintable())[:400]
        if text and text not in hits:
            hits.append(text)
    return list(hits)

def escape(text):
    return text.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')

if __name__ == '__main__':
    path = pathlib.Path(sys.argv[1])
    if path.is_file():
        with path.open(errors='replace') as source:
            messages = summarize(source)
    else:
        messages = []
    for message in messages or ['Build failed; no allowlisted diagnostic found. Full diagnostics remain in the private-access Actions artifact.']:
        print('::error title=Build diagnostic::' + escape(message))
