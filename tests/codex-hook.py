"""Real Codex hook integration against a loopback-only fake model (stdlib only).

Run: python tests/codex-hook.py
All files/config live under tests/.work. No authentication or remote model is used.
The fixed fake model asks for fixture patch edits and shell deletions while protection
is enabled, paused, then enabled again. The test uses
danger-full-access for that isolated synthetic request because nested CLI sandbox
startup can be unavailable on Windows; it does not bypass hook trust.
"""
import argparse
import datetime
import hashlib
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
    scenario_requests = []
    scenario = "initial"
    fixture = None
    delete_command = "Remove-Item -LiteralPath 'test.txt'"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        request = {"scenario": self.scenario, "path": self.path, "body": body}
        self.requests.append(request)
        self.scenario_requests.append(request)
        number = len(self.scenario_requests)
        suffix = self.scenario + "_" + str(number)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def event(name, payload):
            self.wfile.write(("event: " + name + "\ndata: " + json.dumps(payload) + "\n\n").encode())

        event("response.created", {"type": "response.created", "response": {
            "id": "fixture_" + suffix, "status": "in_progress", "output": []}})
        if self.scenario == "initial" and number in (1, 2):
            patch = ("*** Begin Patch\n*** Delete File: keep.txt\n*** End Patch\n" if number == 1 else
                     "*** Begin Patch\n*** Update File: edit.txt\n@@\n-before\n+after\n*** End Patch\n")
            item = {"type": "custom_tool_call", "id": "ctc_fixture_" + suffix,
                    "call_id": "patch_fixture_" + suffix, "name": "apply_patch", "input": patch}
            event("response.output_item.added", {"type": "response.output_item.added",
                  "output_index": 0, "item": dict(item, input="")})
        elif (self.scenario == "initial" and number == 3) or (self.scenario != "initial" and number == 1):
            item = {"type": "function_call", "id": "fc_fixture_" + suffix, "call_id": "delete_fixture_" + suffix,
                    "name": "exec_command", "arguments": json.dumps({"cmd": self.delete_command,
                    "workdir": str(self.fixture / "child"), "max_output_tokens": 1000})}
            event("response.output_item.added", {"type": "response.output_item.added",
                  "output_index": 0, "item": dict(item, arguments="")})
            event("response.function_call_arguments.delta", {
                "type": "response.function_call_arguments.delta", "item_id": item["id"],
                "output_index": 0, "delta": item["arguments"]})
        else:
            item = {"type": "message", "id": "msg_fixture_" + suffix, "role": "assistant",
                    "status": "completed", "content": [{"type": "output_text", "text": "Fixture complete."}]}
            event("response.output_item.added", {"type": "response.output_item.added",
                  "output_index": 0, "item": dict(item, content=[])})
            event("response.output_text.delta", {"type": "response.output_text.delta", "item_id": item["id"],
                  "output_index": 0, "content_index": 0, "delta": "Fixture complete."})
        event("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item})
        event("response.completed", {"type": "response.completed", "response": {
            "id": "fixture_" + suffix, "status": "completed", "output": [item],
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
    FixtureModel.scenario_requests = []
    FixtureModel.scenario = "initial"
    FixtureModel.delete_command = "Remove-Item -LiteralPath 'test.txt'"
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
    package_paths = [source / name for name in ("install.ps1", "uninstall.ps1", "README.md", "SKILL.md", "LICENSE")]
    package_paths.extend((source / "src").glob("*.ps1"))
    package_paths.extend((source / "hooks").glob("*.ps1"))
    package_hashes = {str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in package_paths}
    report = {"status": "FAIL", "fixture": str(fixture), "evidence": str(run), "remote_model": False,
              "powershell_executable": args.shell, "path_updates_disabled": True,
              "test_source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}

    def action(name, label, expected_state=None):
        arguments = [args.shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                     "-File", str(installed / "src/safedelete.ps1"), name]
        if name not in ("off", "on", "status"):
            arguments.extend(["-ProjectRoot", str(fixture)])
        completed = subprocess.run(arguments, cwd=fixture, env=env,
                                   capture_output=True, timeout=90)
        (run / (label + "-stdout.log")).write_bytes(completed.stdout)
        (run / (label + "-stderr.log")).write_bytes(completed.stderr)
        require(completed.returncode == 0, label + " failed; see its stderr log.")
        output = completed.stdout.decode("utf-8-sig")
        if expected_state:
            require("SafeDelete: " + expected_state in output, label + " did not report " + expected_state + ".")
        report.setdefault("actions", {})[label] = {"exit_code": completed.returncode, "status": "PASS"}
        return output

    def cli_scenario(name, command):
        FixtureModel.scenario = name
        FixtureModel.scenario_requests = []
        FixtureModel.delete_command = command
        events_path = run / ("codex-events.jsonl" if name == "initial" else name + "-events.jsonl")
        stderr_path = run / ("codex-stderr.log" if name == "initial" else name + "-stderr.log")
        with events_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            completed = subprocess.run([args.codex, "exec", "--json", "--ephemeral", "--skip-git-repo-check",
                "-s", "danger-full-access", "-C", str(fixture),
                "Use tools only for the synthetic fixtures. Do not read files."],
                cwd=fixture, env=env, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, timeout=90)
        require(completed.returncode == 0, name + " Codex exec failed; see its stderr log.")
        events = []
        for line_number, line in enumerate(events_path.read_text(encoding="utf-8-sig").splitlines(), 1):
            if line.strip():
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError as error:
                    raise AssertionError(name + " event JSONL parse failed at line " + str(line_number)) from error
        feedback = [item.get("output", "") for request in FixtureModel.scenario_requests
                    for item in request["body"].get("input", [])
                    if item.get("type") in ("function_call_output", "custom_tool_call_output")]
        expected_requests = 4 if name == "initial" else 2
        require(len(FixtureModel.scenario_requests) == expected_requests,
                name + " produced an unexpected number of model requests.")
        report.setdefault("scenarios", {})[name] = {"exit_code": completed.returncode,
            "model_requests": len(FixtureModel.scenario_requests), "event_count": len(events),
            "event_parse_errors": 0, "tool_feedback": feedback,
            "command_execution_events": sum(event.get("item", {}).get("type") == "command_execution" for event in events)}
        return feedback

    try:
        version = subprocess.run([args.codex, "--version"], cwd=fixture, env=env,
                                 capture_output=True, timeout=15)
        require(version.returncode == 0, "Cannot read the actual local Codex CLI version.")
        report["codex_version"] = version.stdout.decode("utf-8-sig").strip()
        shell_version = subprocess.run([args.shell, "-NoProfile", "-NonInteractive", "-Command",
                                       "$PSVersionTable.PSVersion.ToString()"], cwd=fixture, env=env,
                                       capture_output=True, timeout=15)
        require(shell_version.returncode == 0, "Cannot read the actual PowerShell version.")
        report["powershell_version"] = shell_version.stdout.decode("utf-8-sig").strip()
        install = subprocess.run([args.shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                  "-File", str(source / "install.ps1"), "-CodexHome", str(home),
                                  "-InstallDir", str(installed), "-NoPathUpdate"], cwd=fixture, env=env,
                                  capture_output=True, timeout=45)
        (run / "install-stdout.log").write_bytes(install.stdout)
        (run / "install-stderr.log").write_bytes(install.stderr)
        require(install.returncode == 0, "Real installer failed; see install-stderr.log.")
        state = json.loads((installed / "install-state.json").read_text(encoding="utf-8-sig"))
        require(state["phase"] == "complete", "Installer did not complete.")
        report["source_hashes"] = {"install.ps1": package_hashes["install.ps1"]}
        report["installed_hashes"] = {}
        for name in state["files"]:
            if (source / name).is_file():
                tested_hash = hashlib.sha256((installed / name).read_bytes()).hexdigest()
                report["installed_hashes"][name] = tested_hash
                if Path(name).suffix.lower() == ".ps1":
                    require(name in package_hashes, "Installed source was not snapshotted before installation: " + name)
                    require(tested_hash == package_hashes[name], "Installed bytes differ from the pre-install source: " + name)
                    require(hashlib.sha256((source / name).read_bytes()).hexdigest() == package_hashes[name],
                            "Source changed during installation: " + name)
                    report["source_hashes"][name] = package_hashes[name]
        report["install_exit_code"] = install.returncode
        protection_path = installed / "protection-state.json"
        require(json.loads(protection_path.read_text(encoding="utf-8-sig"))["enabled"] is True,
                "Installed protection state is not enabled.")
        action("status", "installed-status", "ON")
        corrupt_target = fixture / "child/corrupt-state-test.txt"
        corrupt_bytes = b"invalid protection state must block this synthetic delete\r\n"
        corrupt_target.write_bytes(corrupt_bytes)
        valid_protection_bytes = protection_path.read_bytes()
        try:
            protection_path.write_bytes(b'{"enabled":')
            corrupt_feedback = cli_scenario("corrupt-state-delete",
                "Remove-Item -LiteralPath 'corrupt-state-test.txt'; Write-Output 'CORRUPT_STATE_DELETE_EXECUTED'")
            require(corrupt_target.exists() and corrupt_target.read_bytes() == corrupt_bytes,
                    "P0: native Codex executed deletion with malformed protection state.")
            require(any("DENY" in str(item) or "blocked" in str(item).lower() for item in corrupt_feedback),
                    "Malformed-state deletion was not explicitly blocked by native Codex.")
            require(report["scenarios"]["corrupt-state-delete"]["command_execution_events"] == 0,
                    "Native Codex started the original malformed-state shell command.")
            report["malformed_state_native_delete_blocked"] = True
        finally:
            protection_path.write_bytes(valid_protection_bytes)
        # Control commands must leave all existing installation/configuration files
        # alone; only the local enabled flag is allowed to change.
        unchanged_paths = [home / "config.toml", home / "hooks.json"]
        unchanged_paths.extend(path for path in installed.rglob("*") if path.is_file() and path != protection_path)
        before_controls = {path: path.read_bytes() for path in unchanged_paths}
        helper.write_text("$ErrorActionPreference = 'Stop'\n"
                          "[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)\n"
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
        feedback = cli_scenario("initial", "Remove-Item -LiteralPath 'test.txt'")
        report["codex_exit_code"] = report["scenarios"]["initial"]["exit_code"]
        report["tool_feedback"] = feedback
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
        history_before_pause = history_path.read_bytes()
        off_target = fixture / "child/off-test.txt"
        off_target.write_bytes(b"synthetic unprotected delete only\r\n")
        action("off", "pause")
        action("status", "paused-status", "OFF")
        action("off", "pause-again")
        action("status", "paused-again-status", "OFF")
        require(json.loads(protection_path.read_text(encoding="utf-8-sig"))["enabled"] is False,
                "Pause did not persist the disabled flag.")
        require(record["id"] in action("list", "paused-list"), "Paused recovery history is not accessible.")
        off_command = "Remove-Item -LiteralPath 'off-test.txt'; Write-Output 'SAFEDELETE_OFF_COMMAND_EXECUTED'"
        off_feedback = cli_scenario("paused-delete", off_command)
        require(not off_target.exists(), "A fresh Codex CLI did not execute the paused delete.")
        require(any("SAFEDELETE_OFF_COMMAND_EXECUTED" in str(item) for item in off_feedback),
                "The original paused shell command did not complete.")
        require(not any("Moved to recoverable trash" in str(item) for item in off_feedback),
                "Paused delete was unexpectedly rewritten to safe deletion.")
        require(history_path.read_bytes() == history_before_pause, "Pause or unprotected delete changed old history.")
        require(payload.read_bytes() == target_bytes, "Pause changed the existing recoverable payload.")
        for path, original in before_controls.items():
            require(path.read_bytes() == original, "Pause changed unrelated configuration/installation file: " + path.name)
        action("on", "resume")
        action("status", "resumed-status", "ON")
        action("on", "resume-again")
        action("status", "resumed-again-status", "ON")
        require(json.loads(protection_path.read_text(encoding="utf-8-sig"))["enabled"] is True,
                "Resume did not persist the enabled flag.")
        require(history_path.read_bytes() == history_before_pause and payload.read_bytes() == target_bytes,
                "Resume changed existing history or payload.")
        for path, original in before_controls.items():
            require(path.read_bytes() == original, "Resume changed unrelated configuration/installation file: " + path.name)
        resumed_target = fixture / "child/resumed-test.txt"
        resumed_bytes = b"resumed deletion must remain recoverable\r\n"
        resumed_target.write_bytes(resumed_bytes)
        resumed_command = "Remove-Item -LiteralPath 'resumed-test.txt'"
        resumed_feedback = cli_scenario("resumed-delete", resumed_command)
        require(any("Moved to recoverable trash" in str(item) for item in resumed_feedback),
                "A fresh Codex CLI did not protect the resumed delete.")
        require(not resumed_target.exists(), "Resumed target was not moved.")
        records = json.loads(history_path.read_text(encoding="utf-8-sig"))
        require(len(records) == 2 and all(entry["status"] == "active" for entry in records),
                "Expected exactly two active records, without a record for the OFF delete.")
        resumed_record = next(entry for entry in records if entry["id"] != record["id"])
        require(resumed_record["command"] == resumed_command, "Resumed trigger command was not recorded.")
        require(Path(resumed_record["items"][0]["original_path"]) == resumed_target,
                "Resumed deletion saved the wrong original path.")
        resumed_payload = Path(resumed_record["items"][0]["trash_path"])
        require(resumed_payload.read_bytes() == resumed_bytes, "Resumed content is not present in trash.")
        action("undo", "resumed-undo")
        require(resumed_target.read_bytes() == resumed_bytes and not resumed_payload.exists(),
                "Undo did not restore the resumed target bytes.")
        require(payload.read_bytes() == target_bytes, "Undo of new record changed the pre-pause payload.")
        action("undo", "undo")
        require(target.read_bytes() == target_bytes, "Undo did not restore original bytes.")
        require(control.read_bytes() == control_bytes and not payload.exists(), "Undo altered control or left payload.")
        restored_records = json.loads(history_path.read_text(encoding="utf-8-sig"))
        require(len(restored_records) == 2 and {entry["id"] for entry in restored_records} ==
                {record["id"], resumed_record["id"]} and
                all(entry["status"] == "restored" for entry in restored_records),
                "The two original recovery records were not preserved as restored.")
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
        for name, tested_hash in report["source_hashes"].items():
            if Path(name).suffix.lower() == ".ps1":
                require(hashlib.sha256((source / name).read_bytes()).hexdigest() == tested_hash,
                        "Tested production source changed before completion: " + name)
        require(hashlib.sha256(Path(__file__).read_bytes()).hexdigest() == report["test_source_sha256"],
                "The integration test source changed before completion.")
        report["uninstall_exit_code"] = uninstall.returncode
        report.update(status="PASS", actual_workdir_preserved=True, control_untouched=True,
                      recoverable_payload_verified=True, undo_bytes_verified=True,
                      original_config_bytes_restored=True, real_installer_used=True,
                      apply_patch_delete_denied=True, apply_patch_update_allowed=True,
                      off_on_status_verified=True, repeated_controls_idempotent=True,
                      fresh_cli_pause_persistence_verified=True, fresh_cli_resume_protection_verified=True,
                      paused_delete_original_command_executed=True, paused_delete_added_no_record=True,
                      control_config_and_installed_files_unchanged=True, previous_history_preserved=True,
                      pre_pause_record_undo_bytes_verified=True, tested_source_bytes_verified=True)
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
