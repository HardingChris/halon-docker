import os
import re
import signal
import subprocess
import sys
import threading
import time

from prometheus_client import Counter, Gauge, start_http_server


def positive_int(name, default):
    value = int(os.environ.get(name, default))
    if value < 1:
        raise ValueError(f"{name} must be positive")
    return value


def source_command(domain):
    target = os.environ["TARGET_HOST"]
    if not target.endswith(".svc.cluster.local"):
        raise ValueError("TARGET_HOST must be an in-cluster service")
    if not re.fullmatch(r"[a-z0-9.-]+\.invalid", domain):
        raise ValueError("Recipient domains must end in .invalid")
    command = [
        "smtp-source", "-4", "-c",
        "-s", str(positive_int("SESSIONS", "1")),
        "-m", str(positive_int("MESSAGES_PER_BATCH", "1000")),
        "-l", str(positive_int("PAYLOAD_BYTES", "10240")),
        "-r", str(positive_int("RECIPIENTS_PER_MESSAGE", "1")),
        "-f", "sender@loadtest.invalid", "-t", f"recipient@{domain}",
        "-M", "source.loadtest.invalid", "-S", "Halon capacity test",
    ]
    delay = int(os.environ.get("DELAY_SECONDS", "0"))
    if delay < 0:
        raise ValueError("DELAY_SECONDS must be non-negative")
    if delay:
        command.extend(["-w", str(delay)])
    if os.environ.get("REUSE_CONNECTION", "false") == "true":
        command.append("-d")
    return command + [f"inet:{target}:25"]


def main():
    role = sys.argv[1]
    if role not in ("sink", "generator"):
        raise ValueError("Expected sink or generator")
    messages = Counter("loadtest_messages", "Completed DATA transactions", ["role"])
    failures = Counter("loadtest_process_failures", "Failed or timed out Postfix processes", ["role"])
    running = Gauge("loadtest_running", "Postfix process running", ["role"])
    completed = messages.labels(role)
    failed = failures.labels(role)
    active = running.labels(role)
    stop = threading.Event()
    shutdown = threading.Event()
    process = None

    def terminate(signum, frame):
        shutdown.set()
        stop.set()
        if process is not None and process.poll() is None:
            process.terminate()

    def expire():
        stop.set()
        if process is not None and process.poll() is None:
            process.terminate()

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    start_http_server(9090)
    domains = os.environ.get("DOMAINS", "loadtest.invalid").split(",")
    watchdog = None
    if role == "generator":
        watchdog = threading.Timer(positive_int("RUN_SECONDS", "600"), expire)
        watchdog.daemon = True
        watchdog.start()
    batch = 0
    while not stop.is_set():
        if role == "sink":
            command = ["smtp-sink", "-4", "-c", "-m", str(positive_int("MAX_CONNECTIONS", "4096")),
                       "inet:0.0.0.0:2525", str(positive_int("BACKLOG", "1024"))]
            timeout = None
        else:
            command = source_command(domains[batch % len(domains)])
            timeout = positive_int("BATCH_TIMEOUT_SECONDS", "300")
        started = time.monotonic()
        process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
        timer = threading.Timer(timeout, process.kill) if timeout else None
        if timer:
            timer.start()
        active.set(1)
        if stop.is_set():
            process.terminate()
        previous = 0
        try:
            for line in process.stdout:
                line = line.strip()
                match = re.fullmatch(r"\d+", line) if role == "generator" else re.search(r"(?:^|\s)mesg=(\d+)", line)
                if match:
                    current = int(match.group(0) if role == "generator" else match.group(1))
                    completed.inc(max(0, current - previous))
                    previous = current
        finally:
            if timer:
                timer.cancel()
            process.stdout.close()
            status = process.wait()
            active.set(0)
        print(f"role={role} batch={batch} messages={previous} elapsed_seconds={time.monotonic() - started:.3f} exit={status}")
        if stop.is_set():
            break
        if status != 0 or role == "sink":
            failed.inc()
            raise SystemExit(status or 1)
        batch += 1
    if watchdog:
        watchdog.cancel()
    if not shutdown.is_set():
        print("Run deadline reached; generator is idle until terminated")
        shutdown.wait()


if __name__ == "__main__":
    main()