import json
from pathlib import Path

from fixture import Fixture


class EvaluationChecks(Fixture):
    def result(self):
        return {"scope": "user", "provider": "codex", "modelRequested": "fixture-model", "modelActual": None,
                "effort": None, "caseHash": "a" * 64, "oracleHash": "b" * 64, "sourceHash": "c" * 64,
                "variant": "fixture", "quality": {"passed": 3, "failed": 0}, "durationMs": 23, "costUSD": None}

    def test_unknown_model_effort_and_cost_remain_unknown(self):
        file = self.root / "result.json"
        self.write(file, self.result())
        result = self.run_cli("harness", "record", "--file", file, "--state-root", self.state)
        record = json.loads(Path(result["path"]).read_text())
        self.assertIsNone(record["modelActual"])
        self.assertIsNone(record["effort"])
        self.assertIsNone(record["costUSD"])
        self.assertEqual(record["evidence"], "caller-reported")

    def test_invalid_metrics_and_missing_oracle_are_rejected(self):
        for key, value in [("caseHash", "unknown"), ("quality", {}), ("durationMs", True), ("costUSD", -1)]:
            with self.subTest(key=key):
                result = self.result()
                result[key] = value
                file = self.root / "result.json"
                self.write(file, result)
                self.run_cli("harness", "record", "--file", file, "--state-root", self.state, code=2)

    def test_irrelevant_and_duplicate_options_are_rejected(self):
        self.run_cli("harness", "status", *self.options, "--file", "/tmp/result", code=2)
        self.run_cli("harness", "status", *self.options, "--scope", "user", code=2)
