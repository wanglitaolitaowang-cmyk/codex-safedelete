"""Real Codex hook integration against a loopback-only fake model (stdlib only).

Run: python tests/codex-hook.py
All files/config live under tests/.work. No authentication or remote model is used.
The fixed fake model asks for fixture patch edits and one shell deletion. The test uses
danger-full-access for that isolated synthetic request because nested CLI sandbox
startup can be unavailable on Windows; it does not bypass hook trust.
"""
import argparse
import datetime
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import uuid


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class FixtureModel(http.server.BaseHTTPRequestHandler):
    requests = []
    fixture = None
    delete_command = "Remove-Item -LiteralPath 'test.txt'"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        self.requests.append({"path": self.path, "body": body})
        number = len(self.requests)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def event(name, payload):
            self.wfile.write(("event: " + name + "\ndata: " + json.dumps(payload) + "\n\n").encode())

        event("response.created", {"type": "response.created", "response": {
            "id": "fixture_" + str(number), "status": "in_progress", "output": []}})
        if number in (1, 2):
            patch = ("*** Begin Patch\n*** Delete File: keep.txt\n*** End Patch\n" if number == 1 else
                     "*** Begin Patch\n*** Update File: edit.txt\n@@\n-before\n+after\n*** End Patch\n")
            item = {"type": "custom_tool_call", "id": "ctc_fixture_" + str(number),
                    "call_id": "patch_fixture_" + str(number), "name": "apply_patch", "input": patch}
            event("response.output_item.added", {"type": "response.output_item.added",
                  "output_index": 0, "item": dict(item, input="")})
        elif number == 3:
            item = {"type": "function_call", "id": "fc_fixture", "call_id": "delete_fixture",
                    "name": "exec_command", "arguments": json.dumps({"cmd": self.delete_command,
                    "workdir": str(self.fixture / "child"), "max_output_tokens": 1000})}
            event("response.output_item.added", {"type": "response.output_item.added",
                  "output_index": 0, "item": dict(item, arguments="")})
            event("response.function_call_arguments.delta", {
                "type": "response.function_call_arguments.delta", "item_id": item["id"],
                "output_index": 0, "delta": item["arguments"]})
        else:
            item = {"type": "message", "id": "msg_fixture", "role": "assistant",
                    "status": "completed", "content": [{"type": "output_text", "text": "Fixture complete."}]}
            event("response.output_item.added", {"type": "response.output_item.added",
                  "output_index": 0, "item": dict(item, content=[])})
            event("response.output_text.delta", {"type": "response.output_text.delta", "item_id": item["id"],
                  "output_index": 0, "content_index": 0, "delta": "Fixture complete."})
        event("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item})
        event("response.completed", {"type": "response.completed", "response": {
            "id": "fixture_" + str(number), "status": "completed", "output": [item],
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}})
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=shutil.which("codex"))
    parser.add_argument("--shell", default=str(Path(os.environ.get("SystemRoot", "C:\\Windows")) /
                                                "System32/WindowsPowerShell/v1.0/powershell.exe"))
    args = parser.parse_args()
    require(args.codex and Path(args.codex).suffix.lower() == ".exe", "A local codex.exe is required.")
    source = Path(__file__).resolve().parent.parent
    run = source / "tests" / ".work" / ("codex-hook-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") +
                                         "-" + uuid.uuid4().hex[:8])
    home, fixture, installed = run / "codex-home", run / "fixture", run / "installed $literal's"
    home.mkdir(parents=True)
    (fixture / "child").mkdir(parents=True)
    (fixture / ".codex-safedelete").mkdir()
    target, control = fixture / "child/test.txt", fixture / "test.txt"
    target_bytes, control_bytes = b"child target must survive\r\n", b"root control must remain\r\n"
    target.write_bytes(target_bytes)
    control.write_bytes(control_bytes)
    keep, edit = fixture / "keep.txt", fixture / "edit.txt"
    keep_bytes = b"patch delete must be denied\n"
    keep.write_bytes(keep_bytes)
    edit.write_bytes(b"before\n")
    # Seed unrelated configuration so uninstall must restore it byte for byte.
    write_json(home / "hooks.json", {"description": "Existing fixture hooks", "hooks": {"PreToolUse": [{
        "matcher": "^NeverMatchFixture$", "hooks": [{"type": "command", "command": "exit 0"}]}]}})
    env = dict(os.environ, CODEX_HOME=str(home))
    env.pop("CODEX_API_KEY", None)
    env.pop("OPENAI_API_KEY", None)
    # Codex may synchronize plugin metadata at startup; keep those attempts local.
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        env[name] = "http://127.0.0.1:1"
    env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1,localhost"
    # Windows treats environment names case-insensitively. Duplicate proxy
    # casing in this test otherwise breaks .NET ProcessStartInfo in PowerShell.
    if os.name == "nt":
        env = {name.upper(): value for name, value in env.items()}
    FixtureModel.requests = []
    FixtureModel.fixture = fixture
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureModel)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    config = (f'model = "gpt-6.1-sol"\nmodel_provider = "safedelete_fixture"\n'
              '[model_providers.safedelete_fixture]\nname = "Local fixture"\n'
              f'base_url = "http://127.0.0.1:{server.server_port}/v1"\n'
              'wire_api = "responses"\nrequires_openai_auth = false\nsupports_websockets = false\n'
              '[features]\nhooks = false\nplugins = false\n')
    # Codex exec persists project trust. Seed that state before the snapshot so
    # our uninstaller can correctly reject later edits without this known change.
    git_root = next((parent for parent in (fixture, *fixture.parents) if (parent / ".git").exists()), fixture)
    config += ("[projects." + json.dumps(str(git_root).lower(), ensure_ascii=False) +
               ']\ntrust_level = "trusted"\n')
    (home / "config.toml").write_text(config, encoding="utf-8")
    originals = {name: (home / name).read_bytes() for name in ("config.toml", "hooks.json")}
    helper = run / "trust-fixture.ps1"
    report = {"status": "FAIL", "fixture": str(fixture), "evidence": str(run), "remote_model": False}
    try:
        install = subprocess.run([args.shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                  "-File", str(source / "install.ps1"), "-CodexHome", str(home),
                                  "-InstallDir", str(installed), "-NoPathUpdate"], cwd=fixture, env=env,
                                  capture_output=True, timeout=45)
        (run / "install-stdout.log").write_bytes(install.stdout)
        (run / "install-stderr.log").write_bytes(install.stderr)
        require(install.returncode == 0, "Real installer failed; see install-stderr.log.")
        state = json.loads((installed / "install-state.json").read_text(encoding="utf-8-sig"))
        require(state["phase"] == "complete", "Installer did not complete.")
        report["install_exit_code"] = install.returncode
        helper.write_text("$ErrorActionPreference = 'Stop'\n"
                          "[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)\n. " +
                          ps_quote(installed / "hooks/Trust.ps1") + "\n"
                          "Get-SafeDeleteHookRegistration -CodexHome " + ps_quote(home) +
                          " -WorkingDirectory " + ps_quote(fixture) + " -HookPath " +
                          ps_quote(home / "hooks.json") + " -ExpectedCommand " + ps_quote(state["hook_command"]) +
                          " | ConvertTo-Json -Compress\n", encoding="utf-8-sig")
        trusted = subprocess.run([args.shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                  "-File", str(helper)], cwd=fixture, env=env, capture_output=True, timeout=45)
        (run / "trust-stdout.log").write_bytes(trusted.stdout)
        (run / "trust-stderr.log").write_bytes(trusted.stderr)
        require(trusted.returncode == 0, "Local hook registration/trust failed; see trust-stderr.log.")
        registration = json.loads(trusted.stdout.decode("utf-8-sig"))
        require(registration["TrustStatus"] == "trusted" and registration["Enabled"], "Hook is not trusted/enabled.")
        report["registration"] = registration
        with (run / "codex-events.jsonl").open("wb") as stdout, (run / "codex-stderr.log").open("wb") as stderr:
            completed = subprocess.run([args.codex, "exec", "--json", "--ephemeral", "--skip-git-repo-check",
                "-s", "danger-full-access", "-C", str(fixture),
                "Use tools only for the synthetic fixtures. Do not read files."],
                cwd=fixture, env=env, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, timeout=45)
        report["codex_exit_code"] = completed.returncode
        require(completed.returncode == 0, "Codex exec failed; see codex-stderr.log.")
        feedback = [item.get("output", "") for request in FixtureModel.requests
                    for item in request["body"].get("input", [])
                    if item.get("type") in ("function_call_output", "custom_tool_call_output")]
        report["tool_feedback"] = feedback
        require(len(FixtureModel.requests) == 4, "Expected two patch calls, one shell call and final response.")
        require(any("DENY: apply_patch file deletion" in str(item) for item in feedback), "Patch deletion was not denied.")
        require(keep.read_bytes() == keep_bytes, "apply_patch permanently deleted its target.")
        require(edit.read_bytes() == b"after\n", "Normal apply_patch source editing did not work.")
        require(any("Moved to recoverable trash" in str(item) for item in feedback), "Real SafeDelete CLI did not run.")
        require(not target.exists(), "Child target was not moved.")
        require(control.read_bytes() == control_bytes, "Hook changed the wrong file at session cwd.")
        history_path = fixture / ".codex-safedelete/history.json"
        records = json.loads(history_path.read_text(encoding="utf-8-sig"))
        require(len(records) == 1 and records[0]["status"] == "active", "Expected one active recoverable record.")
        record = records[0]
        require(record["command"] == FixtureModel.delete_command, "Original trigger command was not recorded.")
        require(Path(record["items"][0]["original_path"]) == target, "Saved original path is not actual tool cwd.")
        payload = Path(record["items"][0]["trash_path"])
        require(payload.read_bytes() == target_bytes, "Original content is not present in trash.")
        report["record_id"] = record["id"]
        undone = subprocess.run([args.shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                "-File", str(installed / "src/safedelete.ps1"), "undo", "-ProjectRoot", str(fixture)],
                                cwd=fixture, env=env, capture_output=True, timeout=45)
        (run / "undo-stdout.log").write_bytes(undone.stdout)
        (run / "undo-stderr.log").write_bytes(undone.stderr)
        require(undone.returncode == 0, "Undo failed; see undo-stderr.log.")
        require(target.read_bytes() == target_bytes, "Undo did not restore original bytes.")
        require(control.read_bytes() == control_bytes and not payload.exists(), "Undo altered control or left payload.")
        require(json.loads(history_path.read_text(encoding="utf-8-sig"))[0]["status"] == "restored", "Restore not recorded.")
        uninstall = subprocess.run([args.shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                    "-File", str(installed / "uninstall.ps1"), "-CodexHome", str(home),
                                    "-InstallDir", str(installed), "-NoPathUpdate"], cwd=fixture, env=env,
                                    capture_output=True, timeout=45)
        (run / "uninstall-stdout.log").write_bytes(uninstall.stdout)
        (run / "uninstall-stderr.log").write_bytes(uninstall.stderr)
        require(uninstall.returncode == 0, "Real uninstaller failed; see uninstall-stderr.log.")
        require(not installed.exists(), "Installed files were not removed.")
        for name, original in originals.items():
            require((home / name).read_bytes() == original, "Uninstall did not restore original " + name + " bytes.")
        report["uninstall_exit_code"] = uninstall.returncode
        report.update(status="PASS", actual_workdir_preserved=True, control_untouched=True,
                      recoverable_payload_verified=True, undo_bytes_verified=True,
                      original_config_bytes_restored=True, real_installer_used=True,
                      apply_patch_delete_denied=True, apply_patch_update_allowed=True)
    except Exception as error:
        report["error"] = str(error)
    finally:
        server.shutdown()
        server.server_close()
        write_json(run / "mock-requests.json", FixtureModel.requests)
        write_json(run / "results.json", report)
    print(json.dumps({key: report[key] for key in ("status", "evidence")}, ensure_ascii=False))
    if report["status"] != "PASS":
        print(report["error"])
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
