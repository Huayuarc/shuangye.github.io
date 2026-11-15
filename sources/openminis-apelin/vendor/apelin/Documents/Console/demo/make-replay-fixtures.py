#!/usr/bin/env python3
"""Turn console runs captured on a device into the replay fixtures.

Usage: make-replay-fixtures.py <capture> [--out <dir>]

<capture> holds out/*.jsonl (the console's output, Documents/Console.md ▸
Output) and scripts/*.json (the scripts that wrote them; each run names its
script in `run.start`). The fixtures are written to --out, by default
Packages/ApelinKit/Sources/ApelinReplay/Fixtures beside this repository:

  replies.json       every plain reply: {operation, request, response | error,
                     source}, in the order the runs made them, the request
                     rebuilt from the script with its `${…}` references
  tasks/<name>.json  one per task: {name, source, taskID, kind, start
                     {operation, request, response}, state, events}, named
                     <script prefix>-<label of the step that started it>;
                     events from every run that read the task (step.event
                     lines and attach batches), merged by seq

On the way every string is scrubbed: the bootstrap's `.jbroot-<hex>` becomes
`.jbroot-` and as many zeros, a hostname in `uname -a` or a shell prompt
becomes `device`, a model identifier `iPhone0,0`, a kernel build
`xnu-00000.000.000~0/RELEASE_ARM64_DEVICE` with a neutral build date; a
terminal `output` event's base64 is written again from its scrubbed text.
A build keeps the head and tail of its log lines, a log stream its first
--log-stream-events entries with long messages cut; the events are then
numbered from 1 again with no gap. Finally the output is searched for what
must never be in the repository — a key, a Mac path, a scrubbed value
that survived, an address — and nothing is written if anything is found.
"""

from __future__ import annotations

import argparse
import base64
import copy
import json
import re
import sys
from pathlib import Path
from typing import NoReturn

sys.dont_write_bytecode = True

REPOSITORY = Path(__file__).resolve().parents[3]
DEFAULT_OUT = REPOSITORY / "Packages/ApelinKit/Sources/ApelinReplay/Fixtures"

# Every attach answers a batch; its events belong to the task, not a reply.
ATTACH_OPERATIONS = {"buildAttach", "environmentAttach", "agentAttach", "ptyAttach", "logStream", "confirmLoadedAttach"}
# Errors from the wire (Envelope.swift ▸ ApelinError.Code); the console's own
# (`taskEnded`, `expectationFailed`, …) say nothing about the operation.
WIRE_ERRORS = {
    "unimplemented", "badRequest", "unknownOperation", "unsupportedVersion", "denied", "notFound",
    "conflict", "cancelled", "timeout", "backendUnavailable", "unavailable", "internal",
}
TERMINAL_STATES = {"succeeded", "failed", "cancelled", "interrupted"}

PLACEHOLDER_HOST = "device"
PLACEHOLDER_MODEL = "iPhone0,0"
PLACEHOLDER_XNU = "xnu-00000.000.000~0"
PLACEHOLDER_RELEASE = "RELEASE_ARM64_DEVICE"
PLACEHOLDER_DATE = "Thu Jan{gap}1 00:00:00 UTC 2026"

SCRUBS = [
    # The bootstrap's random folder name, kept in shape.
    (re.compile(r"\.jbroot-([0-9A-Fa-f]+)"), lambda m: ".jbroot-" + "0" * len(m.group(1))),
    # `uname -a`: Darwin <host> <release> Darwin Kernel Version …
    (re.compile(r"\bDarwin \S+ (\d+\.\d+(?:\.\d+)?) Darwin Kernel"), lambda m: f"Darwin {PLACEHOLDER_HOST} {m.group(1)} Darwin Kernel"),
    # bash's default prompt, `\h:\W \u$`, after bracketed paste is turned on.
    (re.compile(r"(\x1b\[\?2004h)[^\s:\x1b]+:"), lambda m: f"{m.group(1)}{PLACEHOLDER_HOST}:"),
    (re.compile(r"\b(?:iPhone|iPad|iPod|Watch|AppleTV|RealityDevice)\d+,\d+\b"), lambda m: PLACEHOLDER_MODEL),
    (re.compile(r"\bxnu-\d[\d.]*~\d+"), lambda m: PLACEHOLDER_XNU),
    (re.compile(r"\bRELEASE_ARM64_\w+"), lambda m: PLACEHOLDER_RELEASE),
    # A kernel build date, in `uname -a` or quoted back by a model.
    (re.compile(r"\b[A-Z][a-z]{2} [A-Z][a-z]{2}( +)\d{1,2} \d{2}:\d{2}:\d{2} [A-Z]{2,5} \d{4}\b"),
     lambda m: PLACEHOLDER_DATE.format(gap=m.group(1))),
]

# What the written fixtures must not contain. Only the name of a pattern is
# ever printed, never what it matched.
FORBIDDEN = {
    "an API key": re.compile(r"sk-[A-Za-z0-9]{8}|(?i:bearer)\s+[A-Za-z0-9._-]{12}"),
    "a bootstrap folder name": re.compile(r"\.jbroot-(?!0+\b)[0-9A-Fa-f]+"),
    "a Mac path": re.compile(r"/Users/|/private/tmp/|/var/folders/|\bclaude-\d"),
    "a model identifier": re.compile(r"\b(?:iPhone|iPad|iPod|Watch|AppleTV|RealityDevice)(?!0,0\b)\d+,\d+"),
    "a kernel build": re.compile(r"xnu-(?!00000\.000\.000~0)\d|RELEASE_ARM64_(?!DEVICE\b)\w|VRESEARCH"),
    # Searched in the written JSON, where ESC is spelled \u001b.
    "a hostname": re.compile(r"\bDarwin (?!device )\S+ \d+\.\d+[.\d]* Darwin Kernel|\\u001b\[\?2004h(?!device:)[^\s:\\]+:"),
    "an IPv4 address": re.compile(r"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])"),
    "a MAC address": re.compile(r"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b"),
    "a device identifier": re.compile(r"\b[0-9A-F]{8}-[0-9A-F]{16}\b|\b[0-9a-f]{40}\b|(?i:\becid\b|\bserial ?number\b)"),
    "an e-mail address": re.compile(r"[\w.+-]+@[\w-]+\.[A-Za-z]{2,}"),
}


def fail(message: str) -> NoReturn:
    print(f"error: make-replay-fixtures: {message}", file=sys.stderr)
    sys.exit(1)


def scrub_text(text: str) -> str:
    for pattern, replacement in SCRUBS:
        text = pattern.sub(replacement, text)
    return text


def scrub(value):
    if isinstance(value, str):
        return scrub_text(value)
    if isinstance(value, list):
        return [scrub(item) for item in value]
    if isinstance(value, dict):
        return {scrub_text(key): scrub(item) for key, item in value.items()}
    return value


# MARK: - References


REFERENCE = re.compile(r"\$\{([^}]+)\}")


def value_at(value, path: str):
    for key in path.split("."):
        if isinstance(value, dict) and key in value:
            value = value[key]
        elif isinstance(value, list) and key.isdigit() and int(key) < len(value):
            value = value[int(key)]
        else:
            return None
    return value


def substitute(value, results: dict):
    """The console's `${label.path}`: a whole-string reference becomes the
    value, one inside a longer string is spliced in as text — a string as it
    is, anything else as its JSON."""
    if isinstance(value, str):
        whole = REFERENCE.fullmatch(value)
        if whole:
            return value_at(results, whole.group(1))

        def spliced(match: re.Match) -> str:
            found = value_at(results, match.group(1))
            return found if isinstance(found, str) else compact(found)

        return REFERENCE.sub(spliced, value)
    if isinstance(value, list):
        return [substitute(item, results) for item in value]
    if isinstance(value, dict):
        return {key: substitute(item, results) for key, item in value.items()}
    return value


# MARK: - Reading the runs


def is_handle(value) -> bool:
    return isinstance(value, dict) and set(value) == {"taskID", "kind"}


def task_handle(response):
    return response.get("task", response) if isinstance(response, dict) else None


def is_batch(value) -> bool:
    return isinstance(value, dict) and {"taskID", "events", "lastSeq", "state", "finished"} <= set(value)


class Task:
    def __init__(self, task_id: str):
        self.task_id = task_id
        self.kind = None
        self.name = None
        self.source = None
        self.start = None
        self.events: dict[int, dict] = {}
        self.batch_state = None

    def add_event(self, event: dict, where: str) -> None:
        seq = event["seq"]
        known = self.events.get(seq)
        if known is not None and known != event:
            fail(f"task {self.task_id} event {seq} differs between reads ({where})")
        self.events[seq] = event


def read_runs(capture: Path):
    runs = []
    for path in sorted((capture / "out").glob("*.jsonl")):
        lines = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        start = next((line for line in lines if line["type"] == "run.start"), None)
        if start is None:
            fail(f"{path.name} has no run.start")
        runs.append((start["runID"], start["script"], lines))
    if not runs:
        fail("no out/*.jsonl in the capture")
    runs.sort(key=lambda run: run[0])
    return runs


def load_script(capture: Path, name: str) -> list:
    script = json.loads((capture / "scripts" / name).read_text(encoding="utf-8"))
    return script["steps"] if isinstance(script, dict) else script


def collect(capture: Path):
    replies = []
    tasks: dict[str, Task] = {}

    def task(task_id: str) -> Task:
        return tasks.setdefault(task_id, Task(task_id))

    for _, script_name, lines in read_runs(capture):
        steps = load_script(capture, script_name)
        prefix = Path(script_name).stem.split("-")[0]
        results: dict[str, dict] = {}
        by_index: dict[int, dict] = {}
        requests: dict[int, dict] = {}

        def result(index: int) -> dict:
            return by_index.setdefault(index, {"events": []})

        def started(index: int, op: str, response, kind: str, task_id: str) -> None:
            entry = task(task_id)
            if entry.start is not None:
                return
            step = steps[index]
            entry.kind = kind
            entry.name = f"{prefix}-{step.get('label') or op}"
            entry.source = f"{script_name} step {index}"
            entry.start = {"operation": op, "request": requests[index], "response": response}

        for line in lines:
            kind = line["type"]
            if kind == "step.start":
                index = line["index"]
                request = steps[index].get("request", {})
                requests[index] = substitute(request, results)
            elif kind == "step.event":
                event = line["event"]
                task(line["taskID"]).add_event(event, script_name)
                events = result(line["index"])["events"]
                if all(known["seq"] != event["seq"] for known in events):
                    events.append(event)
            elif kind == "step.task":
                response = line["response"]
                op = steps[line["index"]]["op"]
                if is_handle(task_handle(response)) or op == "logStream":
                    started(line["index"], op, response, line["kind"], line["taskID"])
            elif kind == "step.result":
                index, op = line["index"], line["op"]
                if op in ("wait", "expect"):
                    continue
                entry = result(index)
                response = line.get("response")
                handle = task_handle(response)
                if is_batch(response):
                    owner = task(response["taskID"])
                    for event in response["events"]:
                        owner.add_event(event, script_name)
                    owner.batch_state = response["state"]
                    merged = {event["seq"]: event for event in response["events"] + entry["events"]}
                    entry["events"] = [merged[seq] for seq in sorted(merged)]
                    if op == "logStream" and "filter" in requests[index]:
                        started(index, op, response, "logStream", response["taskID"])
                elif is_handle(handle):
                    started(index, op, response, handle["kind"], handle["taskID"])
                elif op not in ATTACH_OPERATIONS:
                    error = line.get("error")
                    if line.get("ok") and response is not None:
                        replies.append({"operation": op, "request": requests[index], "response": response,
                                        "source": f"{script_name} step {index}"})
                    elif error and error.get("code") in WIRE_ERRORS:
                        replies.append({"operation": op, "request": requests[index], "error": error,
                                        "source": f"{script_name} step {index}"})
                entry.update({key: line[key] for key in ("ok", "response", "error", "state") if key in line})
                if entry["events"]:
                    entry["lastEvent"] = entry["events"][-1]
                label = steps[index].get("label")
                if label:
                    results[label] = entry
    return replies, tasks


# MARK: - Shaping


def trim(task: Task, args) -> tuple[list, list]:
    """The events to keep, renumbered from 1, and their seqs before renumbering."""
    events = [copy.deepcopy(task.events[seq]) for seq in sorted(task.events)]
    seqs = [event["seq"] for event in events]
    if seqs != list(range(1, len(seqs) + 1)):
        fail(f"task {task.name} has a gap in its events: {seqs[:3]}…{seqs[-3:]}")
    if task.kind == "build":
        logs = [event for event in events if event["kind"] == "log"]
        if len(logs) > args.build_log_head + args.build_log_tail:
            dropped = {id(event) for event in logs[args.build_log_head:len(logs) - args.build_log_tail]}
            events = [event for event in events if id(event) not in dropped]
    elif task.kind == "logStream":
        logs = [event for event in events if event["kind"] == "log"]
        kept = logs[:args.log_stream_events]
        cut = len(kept) < len(logs)
        events = [event for event in events if event["kind"] != "log" or event in kept]
        for event in events:
            message = event.get("payload", {}).get("message")
            if event["kind"] == "log" and isinstance(message, str) and len(message) > args.message_chars:
                event["payload"]["message"] = message[:args.message_chars] + "…"
            if cut and event["kind"] == "truncated" and "limit" in event.get("payload", {}):
                # The kept stream is what one limited to its length reads.
                event["payload"]["limit"] = len(kept)
        if cut and isinstance(task.start["request"].get("filter"), dict) and "limit" in task.start["request"]["filter"]:
            task.start["request"]["filter"]["limit"] = len(kept)
    kept_seqs = [event["seq"] for event in events]
    for number, event in enumerate(events, start=1):
        event["seq"] = number
    return events, kept_seqs


def regenerate_terminal_output(event: dict) -> None:
    payload = event.get("payload") or {}
    if event["kind"] != "output" or "base64" not in payload:
        return
    if "text" in payload:
        payload["base64"] = base64.b64encode(payload["text"].encode("utf-8")).decode("ascii")
    else:
        raw = base64.b64decode(payload["base64"]).decode("latin-1")
        payload["base64"] = base64.b64encode(scrub_text(raw).encode("latin-1")).decode("ascii")


def base64_only_output(events: list) -> str:
    """The terminal output written only as base64 (the device leaves out
    `text` when a chunk is not UTF-8), decoded and spelled as in the written
    JSON, one event per line, so the search before writing sees it too."""
    return "\n".join(
        compact(base64.b64decode(event["payload"]["base64"]).decode("latin-1"))
        for event in events
        if event["kind"] == "output" and "base64" in (event.get("payload") or {}) and "text" not in event["payload"]
    )


def shape(task: Task, args) -> dict:
    if task.start is None:
        fail(f"task {task.task_id} was read but no step in the capture started it")
    events, kept_seqs = trim(task, args)
    events = scrub(events)
    for event in events:
        regenerate_terminal_output(event)
    final = events[-1] if events else None
    if final and final["kind"] == "state" and final.get("payload", {}).get("state") in TERMINAL_STATES:
        state = final["payload"]["state"]
    else:
        state = task.batch_state or "running"
    response = task.start["response"]
    if is_batch(response):
        # An opening batch (a log stream's): rebuilt from the kept events.
        shown = [event for old, event in zip(kept_seqs, events) if old <= response["lastSeq"]]
        response = {"taskID": task.task_id, "events": shown, "state": response["state"],
                    "lastSeq": shown[-1]["seq"] if shown else 0, "finished": False}
    return {
        "name": task.name,
        "source": task.source,
        "taskID": task.task_id,
        "kind": task.kind,
        "start": scrub({**task.start, "response": response}),
        "state": state,
        "events": events,
    }


def dedupe(replies: list) -> list:
    """Identical replies once, at the place of the last one."""
    seen = {}
    for position, reply in enumerate(replies):
        key = json.dumps({k: v for k, v in reply.items() if k != "source"}, sort_keys=True)
        seen[key] = position
    return [replies[position] for position in sorted(seen.values())]


def compact(value) -> str:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def dump_list(items: list) -> str:
    """One item per line: small, and a diff names the event that changed."""
    return "[\n" + ",\n".join(compact(item) for item in items) + "\n]"


def dump_task(task: dict) -> str:
    fields = [f"{compact(key)}:{compact(task[key])}" for key in sorted(task) if key != "events"]
    fields.append(f"{compact('events')}:{dump_list(task['events'])}")
    return "{\n" + ",\n".join(fields) + "\n}\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--build-log-head", type=int, default=40)
    parser.add_argument("--build-log-tail", type=int, default=20)
    parser.add_argument("--log-stream-events", type=int, default=20)
    parser.add_argument("--message-chars", type=int, default=200)
    args = parser.parse_args()

    replies, tasks = collect(args.capture)
    files = {"replies.json": dump_list(dedupe(scrub(replies))) + "\n"}
    hidden = {}
    names = set()
    for task in tasks.values():
        shaped = shape(task, args)
        if shaped["name"] in names:
            fail(f"two tasks are named {shaped['name']}; label the steps that start them")
        names.add(shaped["name"])
        name = f"tasks/{shaped['name']}.json"
        files[name] = dump_task(shaped)
        hidden[name] = base64_only_output(shaped["events"])

    for name, text in files.items():
        for what, pattern in FORBIDDEN.items():
            if pattern.search(text) or pattern.search(hidden.get(name, "")):
                fail(f"{name} still contains {what}; nothing was written")

    (args.out / "tasks").mkdir(parents=True, exist_ok=True)
    for stale in (args.out / "tasks").glob("*.json"):
        stale.unlink()
    for name, text in sorted(files.items()):
        (args.out / name).write_text(text, encoding="utf-8")
        print(f"{len(text.encode('utf-8')):>8}  {name}")


if __name__ == "__main__":
    main()
