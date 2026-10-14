import base64
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import jsonschema
import yaml


ROOT = Path(__file__).resolve().parents[2]


def render(chart, *args, namespace="default"):
    result = subprocess.run(
        ["helm", "template", "halon" if chart == "main" else "halon-loadtest",
         str(ROOT / chart), "--namespace", namespace, *args],
        check=True, capture_output=True, text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents, kind, name):
    return next(document for document in documents
                if document["kind"] == kind and document["metadata"]["name"] == name)


class ChartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.normal = render("main", "-f", str(ROOT / "main/environments/aks-test.yaml"))
        cls.lab = render("main", "-f", str(ROOT / "main/environments/aks-test.yaml"),
                         "-f", str(ROOT / "main/environments/aks-loadtest.yaml"))
        cls.harness = render("loadtest", namespace="halon-loadtest")

    def test_routing_and_native_schema(self):
        for documents, test_mode in ((self.normal, False), (self.lab, True)):
            config = yaml.safe_load(resource(documents, "ConfigMap", "halon-smtpd-config")["data"]["smtpd-app.yaml"])
            transport = config["transportgroups"][0]["transports"][0]
            self.assertEqual(config["transportgroups"][0]["dsn"]["transport"], "mx")
            self.assertNotIn("cluster", config)
            self.assertEqual(transport["session"]["tls"]["mode"], "optional" if test_mode else "dane")
            if test_mode:
                self.assertEqual(transport["connection"], {"server": "halon-loadtest-sink.halon-loadtest.svc.cluster.local", "port": 25})
            else:
                self.assertNotIn("connection", transport)
            schema = Path("/opt/halon/share/json-schemas/6.10/smtpd-app.schema.json")
            if schema.exists():
                jsonschema.validate(config, json.loads(schema.read_text()))

    @unittest.skipUnless(shutil.which("halonconfig"), "Requires the smtpd image's native configuration packer")
    def test_native_configuration_packing(self):
        for mode, documents in (("normal", self.normal), ("loadtest", self.lab)):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                source_root = Path(directory) / "src"
                destination = Path(directory) / "dist"
                pod = resource(documents, "StatefulSet", "halon-smtpd")["spec"]["template"]["spec"]
                smtpd = next(container for container in pod["containers"] if container["name"] == "smtpd")
                volumes = {volume["name"]: volume for volume in pod["volumes"]}
                for mount in smtpd["volumeMounts"]:
                    if not mount["mountPath"].startswith("/src/"):
                        continue
                    target = source_root / mount["mountPath"].removeprefix("/src/")
                    volume = volumes[mount["name"]]
                    sources = volume["projected"]["sources"] if "projected" in volume else [volume]
                    for source in sources:
                        secret = "secret" in source
                        reference = source["secret" if secret else "configMap"]
                        document = resource(documents, "Secret" if secret else "ConfigMap", reference["name"])
                        contents = {key: value.encode() for key, value in document.get("data", {}).items()} if not secret else {}
                        contents.update({key: base64.b64decode(value) for key, value in document.get("data" if secret else "binaryData", {}).items()})
                        items = reference.get("items", [{"key": key, "path": key} for key in contents])
                        for item in items:
                            path = target / item["path"]
                            path.parent.mkdir(parents=True, exist_ok=True)
                            path.write_bytes(contents[item["key"]])
                result = subprocess.run(["halonconfig", "--src-dir", str(source_root), "--dist-dir", str(destination)],
                                        capture_output=True, text=True, timeout=60)
                diagnostics = "\n".join(line for line in (result.stdout + result.stderr).splitlines()
                                        if any(term in line.lower() for term in ("error", "failed", "not found", "undefined", "warning")))
                self.assertEqual(result.returncode, 0, f"Native configuration packing failed for {mode}: {diagnostics}")
                packed = yaml.safe_load((destination / "smtpd-app.yaml").read_text())
                self.assertEqual(packed["servers"][0]["phases"]["eod"]["hook"], "default")
                self.assertTrue(any(hook["id"] == "default" for hook in packed["scripting"]["hooks"]["eod"]))

    def test_hook_override_and_rollout(self):
        normal_hook = resource(self.normal, "ConfigMap", "halon-smtpd-hooks-eod")["data"]["default.hsl"]
        lab_hook = resource(self.lab, "ConfigMap", "halon-smtpd-hooks-eod")["data"]["default.hsl"]
        self.assertNotIn('$recipient["transportid"] = "mx";', normal_hook)
        self.assertIn('$recipient["transportid"] = "mx";', lab_hook)
        self.assertIn('dlp($mail->toFile())', lab_hook)
        normal = resource(self.normal, "StatefulSet", "halon-smtpd")["spec"]
        lab = resource(self.lab, "StatefulSet", "halon-smtpd")["spec"]
        self.assertNotEqual(normal["template"]["metadata"]["annotations"]["checksum/config"], lab["template"]["metadata"]["annotations"]["checksum/config"])
        self.assertEqual(normal["volumeClaimTemplates"], lab["volumeClaimTemplates"])

    def test_supporting_files_mounted_in_all_installs(self):
        expected = {str(path.relative_to(ROOT / "smtpd/src/files")): path.read_bytes()
                    for path in (ROOT / "smtpd/src/files").rglob("*") if path.is_file()}
        for documents in (self.normal, self.lab):
            pod = resource(documents, "StatefulSet", "halon-smtpd")["spec"]["template"]["spec"]
            smtpd = next(container for container in pod["containers"] if container["name"] == "smtpd")
            mount = next(mount for mount in smtpd["volumeMounts"] if mount["name"] == "src-files")
            self.assertEqual(mount["mountPath"], "/src/files")
            self.assertTrue(mount["readOnly"])
            volume = next(volume for volume in pod["volumes"] if volume["name"] == "src-files")
            actual = {}
            for source in volume["projected"]["sources"]:
                secret = "secret" in source
                reference = source["secret" if secret else "configMap"]
                data = resource(documents, "Secret" if secret else "ConfigMap", reference["name"])
                for item in reference["items"]:
                    self.assertEqual(item["path"].startswith("keys/"), secret)
                    self.assertNotIn(item["path"], actual)
                    actual[item["path"]] = base64.b64decode(data["data" if secret else "binaryData"][item["key"]])
            self.assertEqual(set(actual), set(expected))
            for path, content in expected.items():
                self.assertTrue(actual[path] == content, f"File contents differ: {path}")

    def test_hooks_share_one_mount_in_all_installs(self):
        for documents in (self.normal, self.lab):
            pod = resource(documents, "StatefulSet", "halon-smtpd")["spec"]["template"]["spec"]
            smtpd = next(container for container in pod["containers"] if container["name"] == "smtpd")
            mounts = [mount for mount in smtpd["volumeMounts"] if mount["mountPath"].startswith("/src/hooks")]
            self.assertEqual(mounts, [{"name": "src-hooks", "mountPath": "/src/hooks", "readOnly": True}])
            expected = {}
            for document in documents:
                name = document["metadata"]["name"]
                if document["kind"] == "ConfigMap" and name.startswith("halon-smtpd-hooks-"):
                    hook = name.removeprefix("halon-smtpd-hooks-")
                    for key, content in document.get("data", {}).items():
                        expected[f"{hook}/{key}"] = content
            volume = next(volume for volume in pod["volumes"] if volume["name"] == "src-hooks")
            actual = {}
            for source in volume["projected"]["sources"]:
                reference = source["configMap"]
                data = resource(documents, "ConfigMap", reference["name"])["data"]
                for item in reference["items"]:
                    self.assertNotIn(item["path"], actual)
                    actual[item["path"]] = data[item["key"]]
            self.assertEqual(actual, expected)
            self.assertIn("eod/default.hsl", actual)
            self.assertIn("connect/default.hsl", actual)

    def test_dlp_rules_preserved(self):
        normal = resource(self.normal, "ConfigMap", "halon-dlpd")["data"]
        lab = resource(self.lab, "ConfigMap", "halon-dlpd")["data"]
        self.assertEqual(normal, lab)
        self.assertIn("BLOCKPATTERNS", lab["dlpd-app.yaml"])
        for documents in (self.normal, self.lab):
            config = yaml.safe_load(resource(documents, "ConfigMap", "halon-smtpd-config")["data"]["smtpd-app.yaml"])
            self.assertEqual(config["servers"][0]["phases"]["eod"]["hook"], "default")

    def test_dlp_disabled_keeps_eod_hook_binding(self):
        documents = render("main", "--set", "global.dlpd.enabled=false")
        config = yaml.safe_load(resource(documents, "ConfigMap", "halon-smtpd-config")["data"]["smtpd-app.yaml"])
        self.assertEqual(config["servers"][0]["phases"]["eod"]["hook"], "default")

    def test_isolation_is_opt_in(self):
        self.assertFalse(any(item["kind"] == "NetworkPolicy" for item in self.normal))
        smtpd = resource(self.lab, "StatefulSet", "halon-smtpd")
        annotations = smtpd["spec"]["template"]["metadata"]["annotations"]
        self.assertEqual(annotations["traffic.sidecar.istio.io/excludeInboundPorts"], "25")
        policy = resource(self.lab, "NetworkPolicy", "halon-smtpd-loadtest-egress")["spec"]
        for rule in policy["egress"]:
            if any(port["port"] in (25, 2525) for port in rule["ports"]):
                peer = rule["to"][0]
                self.assertEqual(peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"], "halon-loadtest")
                self.assertEqual(peer["podSelector"]["matchLabels"]["app.kubernetes.io/component"], "sink")
        monitor = resource(self.lab, "PodMonitor", "halon-smtpd")
        self.assertEqual(monitor["apiVersion"], "azmonitoring.coreos.com/v1")
        self.assertEqual(monitor["spec"]["labelLimit"], 63)

    def test_harness_starts_stopped_and_private(self):
        generator = resource(self.harness, "Deployment", "halon-loadtest-generator")["spec"]
        self.assertEqual(generator["replicas"], 0)
        for name in ("generator", "sink"):
            pod = resource(self.harness, "Deployment", f"halon-loadtest-{name}")["spec"]["template"]
            self.assertEqual(pod["metadata"]["labels"]["sidecar.istio.io/inject"], "false")
            self.assertFalse(pod["spec"]["automountServiceAccountToken"])
            self.assertTrue(pod["spec"]["securityContext"]["runAsNonRoot"])
        service = resource(self.harness, "Service", "halon-loadtest-sink")["spec"]
        self.assertEqual(service["type"], "ClusterIP")
        self.assertEqual(service["ports"][0]["port"], 25)

    def test_unsafe_values_rejected(self):
        for args in (("--set", "generator.domains[0]=example.com"),
                     ("--set", "generator.sessions=0"),
                     ("--set", "sink.replicas=0"),
                     ("--set", "generator.replicas=-1"),
                     ("--set-json", "generator.domains=[]")):
            with self.subTest(args=args), self.assertRaises(subprocess.CalledProcessError):
                render("loadtest", *args, namespace="halon-loadtest")
        with self.assertRaises(subprocess.CalledProcessError):
            render("loadtest", namespace="default")


if __name__ == "__main__":
    unittest.main()