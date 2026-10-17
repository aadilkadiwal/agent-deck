#!/usr/bin/env python3
"""Agent Deck's bridge to Claude Code, Codex and Gemini CLI.

    hook.py permission [--agent claude|codex]   PermissionRequest: answer from Agent Deck
    hook.py question                            Claude PreToolUse for AskUserQuestion|ExitPlanMode
    hook.py event <Event> [--agent ...]         activity for the session list (fire and forget)
    hook.py install | uninstall | check         manage these hooks in each agent's settings

Every agent keeps its own prompt on screen while a hook waits, so if Agent Deck isn't running or
there's no answer, this prints nothing and the prompt in the terminal works as usual.
Python 3.9 standard library only (what ships with macOS).
"""
import json
import os
import re
import shutil
import socket
import subprocess
import sys

HOME = os.path.expanduser("~")
DATA = os.path.join(HOME, ".claude", "agent-deck")
SOCKET = os.path.join(DATA, "approvals.sock")
HOOK = os.path.join(DATA, "hook.py")
# Must stay under the hook timeout (600) written below.
WAIT = 590

CLAUDE_SETTINGS = os.path.join(HOME, ".claude", "settings.json")
CODEX_HOOKS = os.path.join(HOME, ".codex", "hooks.json")
GEMINI_SETTINGS = os.path.join(HOME, ".gemini", "settings.json")

GEMINI_EVENTS = {"SessionStart": "SessionStart", "SessionEnd": "SessionEnd", "BeforeAgent": "UserPromptSubmit",
                 "AfterAgent": "Stop", "BeforeTool": "PreToolUse", "AfterTool": "PostToolUse", "Notification": "Notification"}


def send(message, wait):
    try:
        if os.stat(SOCKET).st_uid != os.getuid():
            return None
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(WAIT if wait else 1)
        s.connect(SOCKET)
        # One line. While waiting our side stays open: Agent Deck takes end-of-file to mean we've gone away.
        s.sendall(json.dumps(message).encode() + b"\n")
        if not wait:
            s.close()
            return None
        chunks = []
        while True:
            c = s.recv(65536)
            if not c:
                break
            chunks.append(c)
        s.close()
        reply = json.loads(b"".join(chunks).decode() or "{}")
        return reply if isinstance(reply, dict) and reply else None
    except Exception:
        return None


def ask(kind, agent, payload):
    return send({"kind": kind, "agent": agent, "pid": os.getppid(), "payload": payload}, wait=True)


def out(event, body):
    print(json.dumps({"hookSpecificOutput": dict(hookEventName=event, **body)}))


def permission(agent, payload):
    if payload.get("tool_name") in ("AskUserQuestion", "ExitPlanMode"):
        return
    reply = ask("permission", agent, payload)
    if not reply:
        return
    if reply.get("decision") == "allow":
        decision = {"behavior": "allow"}
        updates = []
        # Codex fails closed on updatedPermissions, so only Claude gets rules or modes.
        if agent == "claude":
            if reply.get("always"):
                # Exactly the rule Claude Code itself suggested for this prompt.
                updates += [s for s in payload.get("permission_suggestions") or []
                            if isinstance(s, dict) and s.get("type") == "addRules" and s.get("behavior") == "allow"]
            if reply.get("mode") == "acceptEdits":
                updates.append({"type": "setMode", "mode": "acceptEdits", "destination": "session"})
        if updates:
            decision["updatedPermissions"] = updates
        out("PermissionRequest", {"decision": decision})
    elif reply.get("decision") == "deny":
        message = reply.get("message")
        if not isinstance(message, str) or not message.strip():
            message = "Denied from Agent Deck"
        out("PermissionRequest", {"decision": {"behavior": "deny", "message": message}})


def question(payload):
    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return
    # Both tools need updatedInput along with the allow, or the terminal dialog shows anyway.
    if tool == "ExitPlanMode":
        reply = ask("plan", "claude", payload)
        if reply and reply.get("decision") == "allow":
            out("PreToolUse", {"permissionDecision": "allow", "updatedInput": tool_input})
    elif tool == "AskUserQuestion":
        reply = ask("question", "claude", payload)
        answers = (reply or {}).get("answers")
        asked = [q.get("question") for q in tool_input.get("questions") or [] if isinstance(q, dict)]
        if isinstance(answers, dict) and asked and all(isinstance(answers.get(q), str) and answers.get(q) for q in asked):
            out("PreToolUse", {"permissionDecision": "allow",
                               "updatedInput": dict(tool_input, answers={q: answers[q] for q in asked})})


def event(name, agent, payload):
    if agent == "gemini":
        if name == "Notification" and payload.get("notification_type") != "ToolPermission":
            return
        name = GEMINI_EVENTS.get(name)
        if not name:
            return
    keep = ("session_id", "cwd", "tool_name", "tool_input", "agent_id")
    send({"kind": "event", "agent": agent, "event": name, "pid": os.getppid(),
          "payload": {k: payload[k] for k in keep if k in payload}}, wait=False)


def load(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except FileNotFoundError:
        return {}
    except Exception:
        return None


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path) and not os.path.exists(path + ".agent-deck-backup"):
        shutil.copy2(path, path + ".agent-deck-backup")
    with open(path + ".tmp", "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(path + ".tmp", path)


def ours(handler):
    return isinstance(handler, dict) and "agent-deck/" in str(handler.get("command", ""))


def without_ours(hooks):
    out = {}
    for event, groups in (hooks or {}).items():
        kept = []
        for g in groups if isinstance(groups, list) else []:
            inner = [h for h in g.get("hooks", [])] if isinstance(g, dict) else []
            mine = [h for h in inner if ours(h)]
            if not mine:
                kept.append(g)
            elif len(mine) < len(inner):
                kept.append(dict(g, hooks=[h for h in inner if not ours(h)]))
        if kept:
            out[event] = kept
    return out


def cmd(*args):
    return '/usr/bin/python3 "%s" %s' % (HOOK, " ".join(args))


def claude_hooks():
    def group(command, matcher=None, timeout=600, run_async=False):
        h = {"type": "command", "command": command, "timeout": timeout}
        if run_async:
            h["async"] = True
        return dict({"matcher": matcher} if matcher else {}, hooks=[h])
    # Activity runs in the background, so it never delays a tool call.
    activity = {e: [group(cmd("event", e), timeout=10, run_async=True)]
                for e in ("PostToolUse", "SubagentStart", "SubagentStop", "Stop")}
    return dict(activity,
                PermissionRequest=[group(cmd("permission"))],
                PreToolUse=[group(cmd("question"), matcher="AskUserQuestion|ExitPlanMode"),
                            group(cmd("event", "PreToolUse"), timeout=10, run_async=True)])


def codex_hooks():
    h = {"PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": cmd("permission", "--agent", "codex"), "timeout": 600}]}]}
    for e in ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"):
        # SessionEnd hooks may run for at most 3 s in Codex.
        h[e] = [{"matcher": "", "hooks": [{"type": "command", "command": cmd("event", e, "--agent", "codex"), "timeout": 3}]}]
    return h


def gemini_hooks():
    return {e: [{"matcher": ".*" if e in ("BeforeTool", "AfterTool") else "",
                 "hooks": [{"type": "command", "name": "agent-deck-%s" % e.lower(),
                            "command": cmd("event", e, "--agent", "gemini"), "timeout": 5000}]}]
            for e in GEMINI_EVENTS}


def find(tool):
    return shutil.which(tool) or next((p for p in ("/opt/homebrew/bin/" + tool, "/usr/local/bin/" + tool,
                                                   os.path.join(HOME, ".local/bin", tool)) if os.access(p, os.X_OK)), None)


def gemini_version():
    try:
        m = re.search(r"(\d+)\.(\d+)\.(\d+)", subprocess.run([find("gemini") or "gemini", "--version"],
                                                            capture_output=True, text=True, timeout=15).stdout)
        return tuple(int(p) for p in m.groups()) if m else None
    except Exception:
        return None


def targets():
    """(name, settings file, our hooks) for every agent installed here."""
    t = [("claude", CLAUDE_SETTINGS, claude_hooks())]
    if find("codex") or os.path.isdir(os.path.join(HOME, ".codex")):
        t.append(("codex", CODEX_HOOKS, codex_hooks()))
    if find("gemini") and (gemini_version() or (0,)) >= (0, 26, 0):   # hooks arrived in Gemini CLI 0.26
        t.append(("gemini", GEMINI_SETTINGS, gemini_hooks()))
    return t


def install():
    os.makedirs(DATA, exist_ok=True)
    if os.path.abspath(__file__) != HOOK:
        shutil.copy2(__file__, HOOK)
    os.chmod(HOOK, 0o755)
    found = targets()
    for name, path, mine in found:
        data = load(path)
        if data is None:
            print("  %s: %s isn't valid JSON; fix it and try again" % (name, path))
            continue
        hooks = without_ours(data.get("hooks"))
        for event, groups in mine.items():
            hooks[event] = hooks.get(event, []) + groups
        data["hooks"] = hooks
        save(path, data)
        print("  %s: hooks installed" % name)
    if any(n == "codex" for n, _, _ in found):
        print("  codex: open Codex once and approve Agent Deck's hooks in /hooks (Codex asks for every new hook)")


def uninstall():
    for path in (CLAUDE_SETTINGS, CODEX_HOOKS, GEMINI_SETTINGS):
        data = load(path)
        if not data or "hooks" not in data:
            continue
        hooks = without_ours(data["hooks"])
        if hooks == data["hooks"]:
            continue
        if hooks:
            data["hooks"] = hooks
        else:
            data.pop("hooks")
        if data:
            save(path, data)
        else:
            os.remove(path)


def check():
    report = {"hookScript": os.path.exists(HOOK)}
    installed = {name: (path, mine) for name, path, mine in targets()}
    for name in ("claude", "codex", "gemini"):
        if name not in installed:
            report[name] = "absent"
            continue
        path, mine = installed[name]
        have = (load(path) or {}).get("hooks") or {}
        ok = all(sum(1 for g in have.get(e, []) for h in (g.get("hooks", []) if isinstance(g, dict) else []) if ours(h)) == len(groups)
                 for e, groups in mine.items())
        report[name] = "ok" if ok else "missing"
    line = (load(CLAUDE_SETTINGS) or {}).get("statusLine") or {}
    report["statusLine"] = "ok" if line.get("command") == os.path.join(DATA, "statusline-tap.sh") else "missing"
    print(json.dumps(report))


def main():
    args = sys.argv[1:]
    agent = "claude"
    if "--agent" in args:
        i = args.index("--agent")
        agent = args[i + 1] if i + 1 < len(args) else agent
        del args[i:i + 2]
    kind = args[0] if args else ""
    if kind in ("install", "uninstall", "check"):
        {"install": install, "uninstall": uninstall, "check": check}[kind]()
        return
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    if not isinstance(payload, dict):
        return
    if kind == "permission":
        permission(agent, payload)
    elif kind == "question":
        question(payload)
    elif kind == "event" and len(args) > 1:
        event(args[1], agent, payload)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        if len(sys.argv) > 1 and sys.argv[1] in ("install", "uninstall", "check"):
            raise
    sys.exit(0)
