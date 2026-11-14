"""Solana find_program_address for the badge test (stand-in for the badge's solana.pda).
Usage: python3 pda.py <program b58> <seed hex>... -> "<address b58> <bump>"."""
import hashlib, sys

B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
P = 2**255 - 19
D = (-121665 * pow(121666, P - 2, P)) % P

def b58d(s):
    n = 0
    for c in s: n = n * 58 + B58.index(c)
    b = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    return b"\0" * (len(s) - len(s.lstrip("1"))) + b

def b58e(b):
    n = int.from_bytes(b, "big"); s = ""
    while n: n, r = divmod(n, 58); s = B58[r] + s
    return "1" * (len(b) - len(b.lstrip(b"\0"))) + s

def on_curve(b):
    y = int.from_bytes(b, "little") & ((1 << 255) - 1)
    if y >= P: return False
    u = (y * y - 1) % P; v = (D * y * y + 1) % P
    x2 = u * pow(v, P - 2, P) % P
    if x2 == 0: return True
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P == 0: return True
    x = x * pow(2, (P - 1) // 4, P) % P
    return (x * x - x2) % P == 0

def find_pda(seeds, prog):
    for bump in range(255, -1, -1):
        h = hashlib.sha256(b"".join(seeds) + bytes([bump]) + prog + b"ProgramDerivedAddress").digest()
        if not on_curve(h):
            return h, bump

if __name__ == "__main__":
    addr, bump = find_pda([bytes.fromhex(h) for h in sys.argv[2:]], b58d(sys.argv[1]))
    print(b58e(addr), bump)
