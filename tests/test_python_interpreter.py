import asyncio
import sys

import pytest

from utils.aux_tools.python_interpretor import make_python_execute


def test_python_execute_uses_configured_interpreter_without_uv(tmp_path, monkeypatch):
    monkeypatch.setenv("PYTHON_BIN", sys.executable)

    output = asyncio.run(make_python_execute(str(tmp_path))("print('ready')", "probe.py"))

    assert "ready" in output
    assert "Return code: 0" in output


def test_python_execute_rejects_path_traversal(tmp_path):
    with pytest.raises(ValueError, match="plain file name"):
        asyncio.run(make_python_execute(str(tmp_path))("print('no')", "../escape.py"))


def test_python_execute_kills_timed_out_process(tmp_path, monkeypatch):
    monkeypatch.setenv("PYTHON_BIN", sys.executable)

    output = asyncio.run(
        make_python_execute(str(tmp_path))("import time; time.sleep(10)", "timeout.py", timeout=1)
    )

    assert output == "=== TIMEOUT ===\nExceeded 1s limit."
