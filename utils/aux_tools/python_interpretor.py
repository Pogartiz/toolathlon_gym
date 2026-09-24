"""python_execute local tool for CAMEL."""
import asyncio
import os
import sys
import time
import uuid


def make_python_execute(agent_workspace: str):
    """Return a python_execute callable bound to agent_workspace."""

    async def python_execute(code: str, filename: str = "", timeout: int = 30) -> str:
        """Execute Python code in the agent workspace and return stdout/stderr.

        Args:
            code: Python source code to execute.
            filename: Optional filename (with .py). A random UUID name is used if omitted.
            timeout: Max execution time in seconds (capped at 120).
        """
        timeout = max(1, min(int(timeout), 120))
        if not filename:
            filename = f"{uuid.uuid4()}.py"
        if filename != os.path.basename(filename) or filename in {".", ".."}:
            raise ValueError("filename must be a plain file name without a path")
        if not filename.endswith(".py"):
            filename += ".py"

        workspace = os.path.abspath(agent_workspace)
        tmp_dir = os.path.join(workspace, ".python_tmp")
        os.makedirs(tmp_dir, exist_ok=True)

        file_path = os.path.join(tmp_dir, filename)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(code)

        python_bin = os.environ.get("PYTHON_BIN", sys.executable)
        start = time.time()
        process = await asyncio.create_subprocess_exec(
            python_bin,
            file_path,
            cwd=workspace,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout_bytes, stderr_bytes = await asyncio.wait_for(process.communicate(), timeout=timeout)
        except TimeoutError:
            process.kill()
            await process.communicate()
            return f"=== TIMEOUT ===\nExceeded {timeout}s limit."

        elapsed = time.time() - start
        stdout = stdout_bytes.decode("utf-8", errors="replace")
        stderr = stderr_bytes.decode("utf-8", errors="replace")
        parts = []
        if stdout:
            parts += ["=== STDOUT ===", stdout.rstrip()]
        if stderr:
            parts += ["=== STDERR ===", stderr.rstrip()]
        parts += [
            "=== INFO ===",
            f"Return code: {process.returncode}",
            f"Time: {elapsed:.2f}s / {timeout}s limit",
        ]
        return "\n".join(parts) if parts else "No output."

    return python_execute
