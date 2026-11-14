"""Loads a program as upgradeable on surfpool: writes the loader's two accounts
(programdata with the given upgrade authority, then the program) with surfnet_setAccount.
Usage: python3 upgradeable.py <rpc url> <program.so> <program id> <upgrade authority>"""
import json, struct, sys, urllib.request
from pda import b58d, b58e, find_pda

LOADER = "BPFLoaderUpgradeab1e11111111111111111111111"
rpc, so, program, authority = sys.argv[1], sys.argv[2], b58d(sys.argv[3]), b58d(sys.argv[4])
programdata, _ = find_pda([program], b58d(LOADER))
elf = open(so, "rb").read()
# ProgramData {slot, Some(authority)} + ELF; Program {programdata address}.
data = struct.pack("<IQ", 3, 0) + b"\x01" + authority + elf
for addr, body in (
    (programdata, {"lamports": 10_000_000_000, "data": data.hex(), "owner": LOADER, "executable": False}),
    (program, {"lamports": 1_141_440, "data": (struct.pack("<I", 2) + programdata).hex(), "owner": LOADER, "executable": True}),
):
    req = {"jsonrpc": "2.0", "id": 1, "method": "surfnet_setAccount", "params": [b58e(addr), body]}
    res = json.load(urllib.request.urlopen(urllib.request.Request(
        rpc, json.dumps(req).encode(), {"content-type": "application/json"})))
    if "error" in res:
        sys.exit(f"surfnet_setAccount {b58e(addr)}: {res['error']}")
