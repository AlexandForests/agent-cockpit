import importlib.util, os
from importlib.machinery import SourceFileLoader
# bin/cockpit-fanout has no .py extension; on Python 3.12+ spec_from_file_location returns None
# for extensionless files, so load it via an explicit SourceFileLoader.
_path = os.path.join(os.path.dirname(__file__), "..", "bin", "cockpit-fanout")
_loader = SourceFileLoader("cockpit_fanout", _path)
cf = importlib.util.module_from_spec(importlib.util.spec_from_loader("cockpit_fanout", _loader))
_loader.exec_module(cf)


def test_parse_result_ok():
    out = "noise\nRESULT status=ok branch=cockpit/123 model=opencode/big-pickle verify=ok changed=2\nmore"
    f = cf.parse_result(out)
    assert f["status"] == "ok"
    assert f["branch"] == "cockpit/123"
    assert f["model"] == "opencode/big-pickle"
    assert f["verify"] == "ok"
    assert f["changed"] == "2"


def test_parse_result_missing_defaults_to_nochanges():
    f = cf.parse_result("no result line here")
    assert f["status"] == "nochanges"
    assert f["branch"] == "-"


def test_build_summary_has_rows_and_status():
    results = [
        (1, "Add zod Album schema", {"status": "ok", "branch": "cockpit/a", "model": "opencode/big-pickle", "verify": "ok", "changed": "1"}),
        (2, "Add Leaflet wrapper",  {"status": "nochanges", "branch": "-", "model": "-", "verify": "none", "changed": "-"}),
    ]
    s = cf.build_summary("batch-1", 3, results)
    assert "batch batch-1" in s
    assert "Add zod Album schema" in s
    assert "cockpit/a" in s
    assert "ok" in s
    assert "nochanges" in s
    assert "merge --no-ff" in s  # merge guidance present


def test_parse_args_headless():
    assert cf.parse_args(["batch.json"]) == (False, "batch.json")


def test_parse_args_panes_before_path():
    assert cf.parse_args(["--panes", "batch.json"]) == (True, "batch.json")


def test_parse_args_panes_after_path():
    assert cf.parse_args(["batch.json", "--panes"]) == (True, "batch.json")


def test_agent_cmd_minimal():
    assert cf.agent_cmd({"repo": "/tmp/r", "task": "do x"}) == ["cockpit-agent", "/tmp/r", "do x"]


def test_agent_cmd_with_model_and_verify():
    cmd = cf.agent_cmd({"repo": "/tmp/r", "task": "t", "model": "opencode/big-pickle", "verify": "pytest -q"})
    assert cmd == ["cockpit-agent", "--model", "opencode/big-pickle", "--verify", "pytest -q", "/tmp/r", "t"]


def test_visible_mode_requires_flag_env_and_binary(monkeypatch):
    monkeypatch.setattr(cf.shutil, "which", lambda n: "/usr/bin/zellij")
    monkeypatch.setenv("ZELLIJ", "0")
    assert cf.visible_mode(True) is True
    assert cf.visible_mode(False) is False           # flag off
    monkeypatch.delenv("ZELLIJ", raising=False)
    assert cf.visible_mode(True) is False             # not in a session
    monkeypatch.setenv("ZELLIJ", "0")
    monkeypatch.setattr(cf.shutil, "which", lambda n: None)
    assert cf.visible_mode(True) is False             # zellij not on PATH


def test_build_wrapper_quotes_and_streams():
    w = cf.build_wrapper(1, {"repo": "/tmp/r", "task": "add x"}, "/b")
    assert w.startswith("#!/usr/bin/env bash\n")
    assert "cockpit-agent /tmp/r 'add x'" in w        # task safely quoted
    assert "tee /b/task-1.out" in w                    # live + saved output
    assert 'echo "${PIPESTATUS[0]}" > /b/task-1.done' in w  # sentinel = agent's exit code


def test_build_wrapper_includes_model_and_verify():
    w = cf.build_wrapper(2, {"repo": "/r", "task": "t", "model": "opencode/big-pickle", "verify": "pytest -q"}, "/b")
    assert "--model opencode/big-pickle" in w
    assert "--verify 'pytest -q'" in w


def test_write_wrapper_creates_executable(tmp_path):
    import os, stat
    path = cf.write_wrapper(3, {"repo": "/r", "task": "t"}, str(tmp_path))
    assert path == os.path.join(str(tmp_path), "task-3.sh")
    assert os.path.exists(path)
    assert os.stat(path).st_mode & stat.S_IXUSR    # is executable


def test_await_sentinel_present(tmp_path):
    d = tmp_path / "task-1.done"
    d.write_text("0")
    assert cf.await_sentinel(str(d), timeout=1.0, poll=0.01) is True


def test_await_sentinel_timeout(tmp_path):
    d = tmp_path / "task-1.done"   # never created
    assert cf.await_sentinel(str(d), timeout=0.05, poll=0.01) is False


def test_run_task_visible_parses_out(tmp_path, monkeypatch):
    bd = str(tmp_path)
    with open(os.path.join(bd, "task-1.out"), "w") as f:
        f.write("RESULT status=ok branch=cockpit/x model=stub verify=ok changed=1")
    with open(os.path.join(bd, "task-1.done"), "w") as f:
        f.write("0")
    monkeypatch.setattr(cf, "spawn_pane", lambda *a, **k: 0)
    idx, task, fields = cf.run_task_visible(1, {"repo": "/r", "task": "t"}, bd, "fanout-x", timeout=1.0, poll=0.01)
    assert idx == 1 and fields["status"] == "ok" and fields["branch"] == "cockpit/x"


def test_run_task_visible_timeout(tmp_path, monkeypatch):
    monkeypatch.setattr(cf, "spawn_pane", lambda *a, **k: 0)   # spawns, but .done never appears
    _, _, fields = cf.run_task_visible(1, {"repo": "/r", "task": "t"}, str(tmp_path), "fanout-x", timeout=0.05, poll=0.01)
    assert fields["status"] == "timeout"


def test_run_task_visible_spawn_failed(tmp_path, monkeypatch):
    monkeypatch.setattr(cf, "spawn_pane", lambda *a, **k: 1)   # zellij run returned nonzero
    _, _, fields = cf.run_task_visible(1, {"repo": "/r", "task": "t"}, str(tmp_path), "fanout-x", timeout=0.05, poll=0.01)
    assert fields["status"] == "spawn-failed"
