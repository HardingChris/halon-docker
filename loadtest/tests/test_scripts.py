import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
name = os.path.basename(sys.argv[0])
args = sys.argv[1:]
with open(os.environ["CALL_LOG"], "a") as output:
    output.write(json.dumps([name] + args) + "\n")
if name == "az" and args[:4] == ["network", "vnet", "subnet", "show"]:
    print(json.dumps({"networkSecurityGroup": {"id": "/test/nsg"}} if os.environ.get("NO_NSG") != "true" else {}))
elif name == "az" and args[:3] == ["network", "nsg", "show"]:
    print(json.dumps({"securityRules": [{"priority": int(os.environ.get("NSG_PRIORITY", "100")),
        "direction": "Outbound", "access": os.environ.get("NSG_ACCESS", "Deny"), "protocol": "*",
        "sourceAddressPrefix": "*", "sourcePortRange": "*", "destinationAddressPrefix": "Internet", "destinationPortRange": "25"}]}))
elif name == "az":
    print(json.dumps({"fqdn": "lab.test", "networkProfile": {"networkPolicy": os.environ.get("NETWORK_POLICY", "calico"),
        "networkPlugin": "azure", "networkPluginMode": "overlay"}, "agentPoolProfiles": [{"vnetSubnetId": "/test/subnet"}]}))
elif name == "helm" and args[:2] == ["get", "values"]:
    if "halon-loadtest" in args:
        print(json.dumps({"generator": {"replicas": 0}, "halon": {"namespace": "default", "release": "halon", "service": "halon-smtpd"}}))
    else:
        print(json.dumps({"global": {"dlpd": {"enabled": True}}, "smtpd": {"relayOverride": {
            "enabled": os.environ.get("BAD_ROUTE") != "true", "host": "halon-loadtest-sink.halon-loadtest.svc.cluster.local", "port": 25,
            "networkPolicy": {"enabled": True, "sinkNamespace": "halon-loadtest", "sinkRelease": "halon-loadtest"}}}}))
elif name == "helm" and "generator.sessions=4" in args and os.environ.get("FAIL_STAGE") == "true":
    sys.exit(1)
elif name == "kubectl":
    if "config" in args:
        print(json.dumps({"clusters": [{"cluster": {"server": os.environ.get("KUBE_SERVER", "https://lab.test")}}]}))
    elif "statefulset" in args and "get" in args:
        print(json.dumps({"metadata": {"name": "halon-smtpd"}, "spec": {"replicas": 2, "template": {}}}))
    elif "pods" in args and "get" in args:
        print(json.dumps({"items": [{"status": {"containerStatuses": [{"restartCount": 0, "ready": True}]}}]}))
'''


class ScriptTests(unittest.TestCase):
    def run_script(self, overrides=None):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            mock = temporary / "mock"
            mock.write_text(MOCK)
            mock.chmod(0o755)
            for command in ("az", "helm", "kubectl", "sleep"):
                (temporary / command).symlink_to(mock)
            log = temporary / "calls.jsonl"
            environment = dict(os.environ, PATH=f"{temporary}:{os.environ['PATH']}",
                               CALL_LOG=str(log), OUTPUT_DIR=str(temporary / "results"),
                               CONFIRM_LOADTEST="true", ISOLATION_VERIFIED="true",
                               ISOLATION_MODE="networkpolicy",
                               STAGES="1 4", STAGE_SECONDS="1", GENERATOR_REPLICAS="1",
                               HALON_RELEASE="halon", HALON_NAMESPACE="default",
                               LOADTEST_RELEASE="halon-loadtest", LOADTEST_NAMESPACE="halon-loadtest")
            environment.update(overrides or {})
            result = subprocess.run(["bash", str(ROOT / "deployscripts/run-loadtest.sh")],
                                    env=environment, capture_output=True, text=True, timeout=30)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_success_stops_after_each_stage(self):
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        upgrades = [call for call in calls if call[:2] == ["helm", "upgrade"]]
        self.assertEqual(len(upgrades), 4)
        self.assertIn("generator.replicas=0", upgrades[-1])
        self.assertIn("generator.runSeconds=301", upgrades[0])

    def test_failed_stage_stops_generator(self):
        result, calls = self.run_script({"FAIL_STAGE": "true"})
        self.assertNotEqual(result.returncode, 0)
        upgrades = [call for call in calls if call[:2] == ["helm", "upgrade"]]
        self.assertIn("generator.replicas=0", upgrades[-1])

    def test_subnet_nsg_isolation(self):
        result, calls = self.run_script({"ISOLATION_MODE": "subnet-nsg", "NETWORK_POLICY": "none"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[:4] == ["az", "network", "nsg", "show"] for call in calls))
        for override in ({"NO_NSG": "true"}, {"NSG_ACCESS": "Allow"}, {"NSG_PRIORITY": "200"}):
            with self.subTest(override=override):
                result, calls = self.run_script(dict(override, ISOLATION_MODE="subnet-nsg", NETWORK_POLICY="none"))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[:2] == ["helm", "upgrade"] for call in calls))

    def test_preflight_refuses_unsafe_runs(self):
        for override in ({"CONFIRM_LOADTEST": "false"}, {"ISOLATION_VERIFIED": "false"},
                         {"NETWORK_POLICY": "none"}, {"BAD_ROUTE": "true"},
                         {"KUBE_SERVER": "https://other.test"}, {"STAGES": "0"}):
            with self.subTest(override=override):
                result, calls = self.run_script(override)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[:2] == ["helm", "upgrade"] for call in calls))


if __name__ == "__main__":
    unittest.main()