#!/usr/bin/env python3
"""Fail closed on absent, skipped, or failing native host XCTest cases."""
import json
import re
import sys
from pathlib import Path

CLASS = 'MinisNativeDevelopmentHostTests'


def verify(tree, source):
    expected = set(re.findall(r'\bfunc\s+(test\w+)\s*\(', source))
    if not expected:
        raise ValueError('host test source contains no test methods')
    found = {}

    def walk(node, in_class=False):
        if isinstance(node, list):
            for child in node:
                walk(child, in_class)
        elif isinstance(node, dict):
            label = str(node.get('name', ''))
            identifier = str(node.get('nodeIdentifier', ''))
            selected = in_class or CLASS in label or CLASS in identifier
            if node.get('nodeType') == 'Test Case' and selected:
                match = re.search(r'\b(test\w+)\s*\(', label)
                if not match:
                    raise ValueError('unrecognized host XCTest case name')
                name = match.group(1)
                if name in found:
                    raise ValueError('duplicate host XCTest case: ' + name)
                found[name] = node.get('result')
            for child in node.values():
                if isinstance(child, (dict, list)):
                    walk(child, selected)

    walk(tree)
    if set(found) != expected:
        raise ValueError(f'host XCTest case mismatch: expected {len(expected)}, observed {len(found)}')
    if any(result != 'Passed' for result in found.values()):
        raise ValueError('host XCTest contains failed, skipped, or unknown results')
    return len(found)


if __name__ == '__main__':
    try:
        count = verify(json.loads(Path(sys.argv[1]).read_text()), Path(sys.argv[2]).read_text())
    except (ValueError, OSError) as error:
        raise SystemExit('error: ' + str(error))
    print(f'{CLASS}: {count} executed, all passed; zero skipped')
