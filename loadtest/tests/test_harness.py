import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import unittest
from unittest.mock import patch
import urllib.request


HARNESS = Path(__file__).resolve().parents[1] / "images/harness.py"
SPEC = importlib.util.spec_from_file_location("harness", HARNESS)
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


def wait_for_port(port):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except ConnectionRefusedError:
            pass
    raise AssertionError(f"Port {port} did not become ready")


def wait_for_counter(role, minimum):
    deadline = time.monotonic() + 5
    prefix = f'loadtest_messages_total{{role="{role}"}} '
    while time.monotonic() < deadline:
        metrics = urllib.request.urlopen("http://127.0.0.1:9090/metrics", timeout=2).read().decode()
        for line in metrics.splitlines():
            if line.startswith(prefix) and float(line[len(prefix):]) >= minimum:
                return
    raise AssertionError(f"Missing {role} counter >= {minimum}")


class HarnessTests(unittest.TestCase):
    def test_source_arguments(self):
        with patch.dict(os.environ, {"TARGET_HOST": "halon-smtpd.default.svc.cluster.local"}, clear=True):
            command = harness.source_command("loadtest.invalid")
            self.assertNotIn("-d", command)
            self.assertNotIn("-A", command)
            self.assertEqual(command[-1], "inet:halon-smtpd.default.svc.cluster.local:25")
            with self.assertRaises(ValueError):
                harness.source_command("example.com")
            os.environ["TARGET_HOST"] = "smtp.example.com"
            with self.assertRaises(ValueError):
                harness.source_command("loadtest.invalid")

    def test_connection_reuse_and_delay(self):
        with patch.dict(os.environ, {"TARGET_HOST": "halon-smtpd.default.svc.cluster.local", "REUSE_CONNECTION": "true", "DELAY_SECONDS": "2"}, clear=True):
            command = harness.source_command("loadtest.invalid")
            self.assertIn("-d", command)
            self.assertEqual(command[command.index("-w") + 1], "2")
            os.environ["SESSIONS"] = "0"
            with self.assertRaises(ValueError):
                harness.source_command("loadtest.invalid")

    def test_sink_discards_and_counts(self):
        process = subprocess.Popen([sys.executable, "-u", str(HARNESS), "sink"])
        try:
            wait_for_port(2525)
            subprocess.run(["smtp-source", "-4", "-m", "3", "-f", "sender@loadtest.invalid",
                            "-t", "recipient@loadtest.invalid", "127.0.0.1:2525"], check=True, timeout=10)
            wait_for_counter("sink", 3)
        finally:
            process.terminate()
            process.wait(timeout=10)
        self.assertEqual(process.returncode, 0)

    def test_generator_counts_and_stops(self):
        sink = subprocess.Popen(["smtp-sink", "-4", "127.0.0.1:25", "100"])
        generator = None
        try:
            wait_for_port(25)
            environment = dict(os.environ, TARGET_HOST="sink.test.svc.cluster.local",
                               MESSAGES_PER_BATCH="3", DELAY_SECONDS="1")
            generator = subprocess.Popen([sys.executable, "-u", str(HARNESS), "generator"], env=environment)
            wait_for_port(9090)
            wait_for_counter("generator", 1)
        finally:
            if generator:
                generator.terminate()
                generator.wait(timeout=10)
            sink.terminate()
            sink.wait(timeout=10)
        self.assertEqual(generator.returncode, 0)

    def test_generator_deadline_stays_idle(self):
        sink = subprocess.Popen(["smtp-sink", "-4", "127.0.0.1:25", "100"])
        generator = None
        try:
            wait_for_port(25)
            environment = dict(os.environ, TARGET_HOST="sink.test.svc.cluster.local",
                               RUN_SECONDS="1", MESSAGES_PER_BATCH="100", DELAY_SECONDS="1")
            generator = subprocess.Popen([sys.executable, "-u", str(HARNESS), "generator"], env=environment)
            wait_for_port(9090)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                metrics = urllib.request.urlopen("http://127.0.0.1:9090/metrics", timeout=2).read().decode()
                if 'loadtest_running{role="generator"} 0.0' in metrics and 'loadtest_messages_total{role="generator"}' in metrics:
                    break
            self.assertIn('loadtest_running{role="generator"} 0.0', metrics)
            self.assertIsNone(generator.poll())
        finally:
            if generator:
                generator.terminate()
                generator.wait(timeout=10)
            sink.terminate()
            sink.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()