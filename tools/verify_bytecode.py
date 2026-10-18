#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
"""Read-only BSC runtime comparison. Requires a fresh `forge build --offline --ast`.

No signing, broadcasting, environment-file loading, or account credentials.
Library targets are discovered from compiler-described link slots and verified
recursively. Immutable slots must match getters and known deployment bindings;
unknown immutable kinds fail closed. Nothing is silently masked or truncated.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "contracts/out"
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617
TARGETS = {
    "Entrypoint (proxy)": "ERC1967Proxy", "BNB privacy pool": "PrivacyPoolSimple",
    "USDT privacy pool": "PrivacyPoolComplex", "HushSendAdapter": "HushSendAdapter",
    "GiftAdapter": "GiftAdapter", "LaunchFactory": "LaunchFactory",
    "LaunchAdapter": "LaunchAdapter", "SealedBook": "SealedBook",
    "BookAdapter": "BookAdapter", "GiveRegistry": "GiveRegistry",
    "GiveEscrow": "GiveEscrow", "GiveAdapter": "GiveAdapter",
}
EXTERNAL = {
    "wbnb": "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c",
    "usdt": "0x55d398326f99059ff775485246999027b3197955",
    "pancakeFactory": "0x0bfbcf9fa4f9c56b0f40a671ad40e0805a091865",
    "positionManager": "0x46a15b0b27311cedf172ab29e4f4766fbe7f4364",
    "ANNOUNCER": "0x55649e01b5df198d18d95b5cc5051630cfd45564",
}


def need(condition, message):
    if not condition:
        raise ValueError(message)


def walk(value, variables):
    if isinstance(value, dict):
        if value.get("nodeType") == "VariableDeclaration" and value.get("mutability") == "immutable":
            variables[str(value["id"])] = value
        for item in value.values():
            walk(item, variables)
    elif isinstance(value, list):
        for item in value:
            walk(item, variables)


class Check:
    def __init__(self, rpc, block=None):
        self.url, self.seq, self.cache, self.rows = rpc, 0, {}, []
        self.variables, self.artifacts, self.seen, self.queue = {}, {}, set(), []
        for path in sorted(ARTIFACTS.glob("*/*.json")):
            if path.parent.name == "build-info":
                continue
            obj = json.loads(path.read_text())
            if "deployedBytecode" not in obj:
                continue
            need(path.stem not in self.artifacts, "Ambiguous artifact name: " + path.stem)
            self.artifacts[path.stem] = obj
            walk(obj.get("ast", {}), self.variables)
        need(self.variables, "AST missing: rebuild with --ast")
        readme = (ROOT / "README.md").read_text()
        pairs = re.findall(r"^\| ([^|]+?) \| \[`(0x[0-9a-fA-F]{40})`\]", readme, re.M)
        self.addresses = {name.strip(): address.lower() for name, address in pairs if name.strip() in TARGETS}
        need(set(self.addresses) == set(TARGETS), "README mainnet address table is incomplete")
        need(self.call("eth_chainId", []) == "0x38", "RPC is not BSC chain 56")
        self.header = self.call("eth_getBlockByNumber", [hex(block) if block else "latest", False])
        need(isinstance(self.header, dict), "Snapshot block is unavailable")
        self.block = self.header["number"]
        self.bindings = {**EXTERNAL, "entrypoint": self.addresses["Entrypoint (proxy)"],
                         "ENTRYPOINT": self.addresses["Entrypoint (proxy)"],
                         "book": self.addresses["SealedBook"], "factory": self.addresses["LaunchFactory"],
                         "registry": self.addresses["GiveRegistry"], "escrow": self.addresses["GiveEscrow"]}
        for label, artifact in TARGETS.items():
            self.enqueue(label, artifact, self.addresses[label])
        self.prefetch(self.queue)
        impl = self.call("eth_getStorageAt", [self.bindings["entrypoint"], IMPL_SLOT, self.block])
        need(re.fullmatch(r"0x[0-9a-fA-F]{64}", impl), "Invalid proxy implementation slot")
        self.enqueue("Entrypoint implementation", "Entrypoint", "0x" + impl[-40:])
        for getter, artifact in [("WITHDRAWAL_VERIFIER", "WithdrawalVerifier"), ("RAGEQUIT_VERIFIER", "CommitmentVerifier")]:
            word = self.getter("PrivacyPoolSimple", self.addresses["BNB privacy pool"], getter)
            self.bindings[getter] = "0x" + word[-40:]
            self.enqueue(artifact, artifact, self.bindings[getter])
        word = self.getter("LaunchFactory", self.addresses["LaunchFactory"], "saleDeployer")
        self.bindings["saleDeployer"] = "0x" + word[-40:]
        self.enqueue("SaleDeployer", "SaleDeployer", self.bindings["saleDeployer"])

    def prefetch(self, targets):
        """Small read-only batches keep all reads inside a public node's state window."""
        requests = []
        for _, name, address in targets:
            requests.append(("eth_getCode", [address, self.block]))
            artifact = self.artifacts[name]
            for ast_id in (artifact["deployedBytecode"].get("immutableReferences") or {}):
                var = self.variables[ast_id]
                if var.get("visibility") == "public":
                    selector = artifact.get("methodIdentifiers", {}).get(var["name"] + "()")
                    need(selector is not None, "Missing immutable getter")
                    requests.append(("eth_call", [{"to": address, "data": "0x" + selector}, self.block]))
        pending = {json.dumps([m, p]): (m, p) for m, p in requests if json.dumps([m, p]) not in self.cache}
        items = list(pending.items())
        for offset in range(0, len(items), 8):
            chunk = items[offset:offset + 8]
            payload, keys = [], {}
            for key, (method, params) in chunk:
                self.seq += 1
                keys[self.seq] = key
                payload.append({"jsonrpc": "2.0", "id": self.seq, "method": method, "params": params})
            request = urllib.request.Request(self.url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=30) as response:
                answers = json.load(response)
            need(isinstance(answers, list) and len(answers) == len(keys), "RPC batch response incomplete")
            returned = set()
            for answer in answers:
                request_id = answer.get("id")
                need(request_id in keys and request_id not in returned, "RPC batch id mismatch")
                returned.add(request_id)
                need("error" not in answer and "result" in answer, "RPC batch read failed; retry at a fresh snapshot")
                self.cache[keys[request_id]] = answer["result"]

    def call(self, method, params):
        need(method in {"eth_chainId", "eth_getBlockByNumber", "eth_getStorageAt", "eth_getCode", "eth_call"}, "Non-read method forbidden")
        key = json.dumps([method, params])
        if key in self.cache:
            return self.cache[key]
        self.seq += 1
        req = urllib.request.Request(self.url, data=json.dumps({"jsonrpc": "2.0", "id": self.seq, "method": method, "params": params}).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as response:
            data = json.load(response)
        need(data.get("id") == self.seq and "error" not in data and "result" in data, "RPC failed for " + method)
        self.cache[key] = data["result"]
        return data["result"]

    def getter(self, artifact, address, name):
        selector = self.artifacts[artifact].get("methodIdentifiers", {}).get(name + "()")
        need(selector is not None, "Missing getter: " + artifact + "." + name)
        value = self.call("eth_call", [{"to": address, "data": "0x" + selector}, self.block])
        need(isinstance(value, str) and re.fullmatch(r"0x[0-9a-fA-F]{64}", value), "Invalid immutable getter result")
        return value[2:].lower()

    def enqueue(self, label, artifact, address):
        address = address.lower()
        need(re.fullmatch(r"0x[0-9a-f]{40}", address) and int(address, 16) != 0, "Invalid target address")
        key = (artifact, address)
        if key not in self.seen:
            self.seen.add(key)
            self.queue.append((label, artifact, address))

    def scope(self, address, asset):
        packed = "0x" + address[2:] + format(56, "064x") + asset[2:]
        result = subprocess.run(["cast", "keccak", packed], check=True, capture_output=True, text=True)
        return int(result.stdout.strip(), 16) % FIELD

    def verify(self, label, artifact_name, address):
        artifact = self.artifacts[artifact_name]
        metadata = artifact.get("metadata", {})
        settings = metadata.get("settings", {})
        need(metadata.get("compiler", {}).get("version") == "0.8.28+commit.7893614a", "Unexpected compiler")
        need(settings.get("optimizer") == {"enabled": True, "runs": 200}, "Unexpected optimizer settings")
        need(settings.get("evmVersion") == "cancun" and not settings.get("viaIR", False), "Unexpected code generation settings")
        need(settings.get("metadata", {}).get("bytecodeHash") == "none" and settings.get("metadata", {}).get("appendCBOR") is False, "Unexpected metadata settings")
        bytecode = artifact["deployedBytecode"]
        template = bytecode["object"].removeprefix("0x").lower()
        live = self.call("eth_getCode", [address, self.block]).removeprefix("0x").lower()
        need(live and len(live) == len(template), "Runtime length differs: " + label)
        chars = list(template)
        checks, linked = [], []

        def replace(start, length, value):
            need(len(value) == length * 2, "Replacement width mismatch")
            chars[start * 2:(start + length) * 2] = value

        for source, libs in (bytecode.get("linkReferences") or {}).items():
            for name, ranges in libs.items():
                values = {live[r["start"] * 2:(r["start"] + r["length"]) * 2] for r in ranges}
                need(len(values) == 1 and all(r["length"] == 20 for r in ranges), "Inconsistent library bindings: " + name)
                target = "0x" + next(iter(values))
                for r in ranges:
                    replace(r["start"], r["length"], target[2:])
                self.enqueue(name, name, target)
                linked.append(name)

        for ast_id, ranges in (bytecode.get("immutableReferences") or {}).items():
            var = self.variables.get(ast_id)
            need(var is not None, "Unknown immutable AST id")
            name = var["name"]
            if name == "__self" and artifact_name == "Entrypoint":
                expected = address[2:].zfill(64)
            else:
                need(var.get("visibility") == "public", "Unverified private immutable: " + name)
                expected = self.getter(artifact_name, address, name)
                if name in self.bindings:
                    need(expected == self.bindings[name][2:].zfill(64), "Deployment binding mismatch: " + name)
                elif name == "ASSET":
                    asset = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" if artifact_name == "PrivacyPoolSimple" else EXTERNAL["usdt"]
                    need(expected == asset[2:].zfill(64), "Pool asset differs")
                elif name == "SCOPE":
                    asset = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" if artifact_name == "PrivacyPoolSimple" else EXTERNAL["usdt"]
                    need(int(expected, 16) == self.scope(address, asset), "Pool scope differs from constructor formula")
                else:
                    raise ValueError("No independent expected binding for immutable: " + name)
            for r in ranges:
                need(r["length"] == 32, "Unsupported immutable width")
                need(live[r["start"] * 2:(r["start"] + 32) * 2] == expected, "Immutable value differs: " + name)
                replace(r["start"], 32, expected)
            checks.append(name)

        definitions = [n for n in artifact.get("ast", {}).get("nodes", []) if n.get("nodeType") == "ContractDefinition" and n.get("name") == artifact_name]
        if definitions and definitions[0].get("contractKind") == "library" and template.startswith("73" + "00" * 20):
            need(live[2:42] == address[2:], "Library self-address guard mismatch")
            replace(1, 20, address[2:])
            checks.append("library-self-address")
        expected = "".join(chars)
        need(re.fullmatch(r"[0-9a-f]+", expected), "Unresolved runtime placeholder")
        if expected != live:
            different = [i // 2 for i in range(0, len(live), 2) if live[i:i + 2] != expected[i:i + 2]]
            raise ValueError(f"Runtime bytes differ: {label}; first offsets {different[:8]}")
        self.rows.append({"name": label, "artifact": artifact_name, "address": address, "runtimeBytes": len(live) // 2,
                          "result": "MATCH", "immutableChecks": checks, "linkedLibraries": linked,
                          "runtimeSha256": hashlib.sha256(bytes.fromhex(live)).hexdigest()})
        print(f"MATCH {label}: {len(live) // 2} runtime bytes", flush=True)

    def run(self):
        while self.queue:
            wave, self.queue = self.queue, []
            self.prefetch(wave)
            for target in wave:
                self.verify(*target)
        self.cache.pop(json.dumps(["eth_getBlockByNumber", [self.block, False]]), None)
        need(self.call("eth_getBlockByNumber", [self.block, False])["hash"] == self.header["hash"], "Snapshot block changed; rerun")
        return {"chainId": 56, "blockNumber": int(self.block, 16), "blockHash": self.header["hash"],
                "blockTimeUtc": datetime.datetime.fromtimestamp(int(self.header["timestamp"], 16), datetime.timezone.utc).isoformat(),
                "solc": "0.8.28", "optimizerRuns": 200, "evmVersion": "cancun", "cborMetadata": False,
                "rows": self.rows, "rpcRequests": self.seq,
                "scope": "Full runtime equality after explicit checked immutable/library substitution; no arbitrary masking. Proxy implementation checked separately.",
                "limitations": ["Does not reconstruct creation transactions or certify source text published by an explorer.",
                                "Does not prove security, custody, service operation, or future upgrade behavior.",
                                "No individual dynamically created sale/token instance or external oracle/router/standard singleton is included."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc", default="https://bsc-dataseed.bnbchain.org")
    parser.add_argument("--block", type=int)
    parser.add_argument("--json", type=pathlib.Path, required=True, help="Write a comparison receipt, preferably outside the repository")
    args = parser.parse_args()
    result = Check(args.rpc, args.block).run()
    args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Verified {len(result['rows'])} contracts at BSC block {result['blockNumber']}.")


if __name__ == "__main__":
    main()
