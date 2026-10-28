"""Probe the compiled Mouse helper without an event tap, TCC prompt, GUI, or live Nook data."""
import json
import os
import subprocess
import sys

helper, temporary = sys.argv[1:]
env = {**os.environ, "NOOK_PLUGIN_ID": "mouse", "NOOK_PLUGIN_DIR": os.path.dirname(helper), "NOOK_DATA_DIR": os.path.join(temporary, "mouse-data")}
probe = subprocess.run([helper, "--probe"], capture_output=True, check=True, text=True, env=env)
metadata = json.loads(probe.stdout)["params"]
assert metadata["eventTapStarted"] is False
assert metadata["engine"]["name"] == "Nook Mouse"
assert metadata["engine"]["version"] == "2.1.1"
assert metadata["engine"]["sourceVersion"] == "3.1.0"
assert metadata["engine"]["revision"] == "603646cdb5200eb9d0db0afdb5967c7ec41c5de0"
os.makedirs(env["NOOK_DATA_DIR"], exist_ok=True)
with open(os.path.join(env["NOOK_DATA_DIR"], "mouse.json"), "w") as settings:
    json.dump({"enabled": False, "buttons": {}}, settings)
requests = [{"jsonrpc": "2.0", "id": 1, "method": "mouse.state", "params": {"args": []}}, {"jsonrpc": "2.0", "id": 2, "method": "missing", "params": {}}]
# Keep stdin open while awaiting replies so EOF doesn't intentionally shut down pending main-queue work.
process = subprocess.Popen([helper, "--protocol-test"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
for request in requests:
    process.stdin.write(json.dumps(request) + "\n")
process.stdin.flush()
responses = [json.loads(process.stdout.readline()) for _ in requests]
assert responses[0]["id"] == 1 and responses[0]["result"]["running"] is False
assert responses[1]["error"]["code"] == -32601
for request_id, method, args in [(3, "mouse.set", [{"speedMode": "custom", "speed": 2}]), (4, "mouse.applyPreset", ["defaults"])]:
    process.stdin.write(json.dumps({"jsonrpc":"2.0", "id":request_id, "method":method, "params":{"args":args}}) + "\n")
    process.stdin.flush()
    response = json.loads(process.stdout.readline())
    assert response["id"] == request_id
    assert response["result"]["running"] is False
config = response["result"]["config"]
assert config["speedMode"] == "medium" and config["speed"] == 1 and config["smoothness"] == "high"
assert config["reverse"] is True and config["preciseModifier"] == "option" and config["quickModifier"] == "control"
assert config["zoomModifier"] == "command" and config["buttons"]["4"]["scroll"] == "zoom"
assert config["enabled"] is False
process.stdin.close()
assert process.wait(timeout=5) == 0
with open(os.path.join(env["NOOK_DATA_DIR"], "mouse.json")) as settings:
    assert json.load(settings) == config
print("PASS: Universal Mouse helper probe, state RPC, unknown-method error and stdin-EOF shutdown; no event tap launched.")
