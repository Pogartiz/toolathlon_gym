from typing import Dict, Any, List
from utils.roles.task_agent import TaskStatus
from utils.data_structures.task_config import TaskConfig
from utils.general.helper import run_command, read_json, write_json
import logging
import os


def _measured_result(pass_value: bool, **extra: Any) -> Dict[str, Any]:
    """Model outcome is scored (pass true/false)."""
    out: Dict[str, Any] = {"pass": bool(pass_value), "measured": True}
    out.update(extra)
    return out


def _unmeasured_result(failure: str, **extra: Any) -> Dict[str, Any]:
    """Infrastructure / missing verdict — must not score as model fail."""
    out: Dict[str, Any] = {"pass": None, "measured": False, "failure": failure}
    out.update(extra)
    return out


# Agent statuses that count as measured model failure (score 0), not infra.
_MEASURED_AGENT_FAIL = frozenset(
    {
        TaskStatus.FAILED.value,
        TaskStatus.MAX_TURNS_REACHED.value,
    }
)

_UNMEASURED_AGENT = frozenset(
    {
        TaskStatus.INTERRUPTED.value,
        TaskStatus.ERROR.value,
    }
)


class TaskEvaluator:
    """Task evaluator with explicit measured vs unmeasured contract."""

    @staticmethod
    async def evaluate_one(dump_line: Dict[str, Any]) -> Dict[str, Any]:
        task_config = TaskConfig.from_dict(dump_line["config"])
        task_status = dump_line["status"]
        res_log_file = task_config.log_file
        agent_workspace = task_config.agent_workspace
        groundtruth_workspace = task_config.evaluation.groundtruth_workspace
        eval_command = task_config.evaluation.evaluation_command
        launch_time = task_config.launch_time
        print(f"launch time in eval is {launch_time}")

        if task_status in _UNMEASURED_AGENT:
            return _unmeasured_result(
                f"agent_{task_status}",
                details=f"Task status: {task_status}",
            )

        if task_status in _MEASURED_AGENT_FAIL:
            return _measured_result(
                False,
                failure=f"agent_{task_status}",
                details=f"Task status: {task_status}; measured model failure",
            )

        if task_status != TaskStatus.SUCCESS.value:
            return _unmeasured_result(
                "agent_unknown_status",
                details=f"Task status: {task_status}",
            )

        if eval_command is not None:
            args = (
                f"--res_log_file {res_log_file} --agent_workspace {agent_workspace} "
                f"--groundtruth_workspace {groundtruth_workspace} --launch_time \"{launch_time}\""
            )
            command = f"{eval_command} {args}"
            output, error, returncode = await run_command(command, debug=True)
            print("== Evaluation STDOUT ==")
            print(output)
            print("== Evaluation STDERR ==")
            print(error)
            if returncode != 0:
                return _measured_result(False, failure="verifier_reject", details=(error or output)[:2000])

        return _measured_result(True, details="All evaluation checks passed, and task status is success")

    @staticmethod
    async def evaluate_from_log_file(log_file_path: str, allow_resume: bool = False) -> Dict[str, Any]:
        try:
            if not os.path.exists(log_file_path):
                return _unmeasured_result(
                    "log_file_not_found",
                    details=f"Log file not found: {log_file_path}",
                )
            eval_file_path = os.path.join(os.path.dirname(log_file_path), "eval_res.json")
            if allow_resume and os.path.exists(eval_file_path):
                return read_json(eval_file_path)
            dump_line = read_json(log_file_path)
            eval_res = await TaskEvaluator.evaluate_one(dump_line)
            write_json(eval_res, eval_file_path)
            return eval_res
        except Exception as e:
            logging.error(f"Error evaluating from log file {log_file_path}: {e}")
            return _unmeasured_result("evaluation_error", details=str(e))

    @staticmethod
    async def batch_evaluate(run_results: List[Dict[str, Any]], allow_resume: bool = False) -> List[Dict[str, Any]]:
        eval_results = []
        for run_result in run_results:
            eval_result: Dict[str, Any] = {
                "task_config_path": run_result["task_config_path"],
                "task_id": run_result.get("task_id", "unknown"),
            }
            if not run_result.get("success", False):
                eval_result["evaluation"] = _unmeasured_result(
                    "task_execution_failed",
                    details=run_result.get("error", "Unknown error"),
                )
            else:
                log_file = run_result.get("log_file")
                if log_file:
                    eval_result["evaluation"] = await TaskEvaluator.evaluate_from_log_file(
                        log_file, allow_resume=allow_resume
                    )
                else:
                    eval_result["evaluation"] = _unmeasured_result(
                        "no_log_file",
                        details="No log file generated",
                    )
            eval_result["pass"] = eval_result["evaluation"]["pass"]
            eval_result["measured"] = eval_result["evaluation"].get("measured")
            eval_results.append(eval_result)
        return eval_results
