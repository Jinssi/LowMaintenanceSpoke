import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from log_analyzer_tool import main


class LogAnalyzerTests(unittest.TestCase):
    def test_groups_repeated_failures_and_preserves_success_evidence(self):
        sample = Path(__file__).resolve().parents[1] / "examples" / "sample.log"
        result = main(log_text=sample.read_text(encoding="utf-8"))
        self.assertEqual(result["counts"]["error"], 2)
        self.assertEqual(result["counts"]["success"], 2)
        self.assertEqual(result["observed_windows"]["24h"]["errors"], 2)
        self.assertEqual(result["error_groups"][0]["count"], 2)
        self.assertEqual(result["error_groups"][0]["party"], "partner-a")
        self.assertEqual(result["error_groups"][0]["status_codes"], {404: 2})
        self.assertEqual([r["line"] for r in result["error_groups"][0]["recent_examples"]], [2, 3])
        self.assertEqual(result["error_groups"][0]["same_party_latest_success"]["line"], 1)

    def test_redacts_credentials_and_email_in_output(self):
        result = main(log_text="2026-10-02T09:00:00Z ERROR status=500 "
                      "Authorization=Bearer abc123 password=hunter2 user=alice@example.org")
        rendered = str(result)
        self.assertNotIn("abc123", rendered)
        self.assertNotIn("hunter2", rendered)
        self.assertNotIn("alice@example.org", rendered)

    def test_no_timestamp_does_not_invent_window(self):
        result = main(log_text="ERROR status=503 party=partner-a")
        self.assertEqual(result["observed_windows"], {})
        self.assertIsNone(result["observed_first_utc"])

    def test_http_error_wins_over_info_level(self):
        result = main(log_text='{"level":"INFO","message":"response","statusCode":429}')
        self.assertEqual(result["counts"]["error"], 1)

    def test_rejects_invalid_or_oversize_input(self):
        with self.assertRaises(ValueError):
            main()
        with self.assertRaises(ValueError):
            main(log_text="x" * 1_000_001)
        with self.assertRaises(ValueError):
            main(storage_account="bad.example", container="logs", blob_name="test")
        with self.assertRaises(ValueError):
            main(log_text="x", storage_account="account", container="logs", blob_name="test")

    def test_blob_coordinates_use_bounded_reader(self):
        with patch("log_analyzer_tool._read_blob", return_value="2026-10-02T09:00:00Z ERROR status=503") as read:
            result = main(storage_account="account", container="logs", blob_name="incident.log")
        read.assert_called_once_with("account", "logs", "incident.log")
        self.assertEqual(result["source"], "blob")
        self.assertEqual(result["counts"]["error"], 1)

    def test_timestamp_windows_are_anchored_to_latest_observation(self):
        text = ("2026-09-29T09:00:00Z ERROR status=500\n"
                "2026-10-02T09:00:00Z ERROR status=503")
        result = main(log_text=text)
        self.assertEqual(result["observed_windows"]["24h"]["errors"], 1)
        self.assertEqual(result["observed_windows"]["7d"]["errors"], 2)


if __name__ == "__main__":
    unittest.main()
