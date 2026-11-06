// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
// 只用于测试：用一把临时生成的测试钥匙签名（RFC 8032 Ed25519），好让测试数据能过客户端的校验。秘书本身只验证、从不签名。
using System; using System.Numerics; using System.Security.Cryptography;
public static class TestSigner {
  static readonly BigInteger P = BigInteger.Pow(2, 255) - 19;
  static readonly BigInteger L = BigInteger.Pow(2, 252) + BigInteger.Parse("27742317777372353535851937790883648493");
  static readonly BigInteger D = Mod(-121665 * Inv(121666));
  static readonly BigInteger I = BigInteger.ModPow(2, (P - 1) / 4, P);
  static readonly BigInteger[] B;
  static TestSigner() { BigInteger by = Mod(4 * Inv(5)); BigInteger bx = RecoverX(by, 0); B = new[] { bx, by, BigInteger.One, Mod(bx * by) }; }
  static BigInteger Mod(BigInteger a) { a %= P; return a.Sign < 0 ? a + P : a; }
  static BigInteger Inv(BigInteger a) { return BigInteger.ModPow(Mod(a), P - 2, P); }
  static BigInteger RecoverX(BigInteger y, int sign) { BigInteger x2 = Mod((y * y - 1) * Inv(D * y * y + 1)); BigInteger x = BigInteger.ModPow(x2, (P + 3) / 8, P); if (Mod(x * x - x2) != 0) x = Mod(x * I); if ((int)(x & 1) != sign) x = P - x; return x; }
  static BigInteger[] Add(BigInteger[] p, BigInteger[] q) { BigInteger a = Mod((p[1] - p[0]) * (q[1] - q[0])), b = Mod((p[1] + p[0]) * (q[1] + q[0])), c = Mod(2 * p[3] * q[3] * D), d = Mod(2 * p[2] * q[2]); BigInteger e = b - a, f = d - c, g = d + c, h = b + a; return new[] { Mod(e * f), Mod(g * h), Mod(f * g), Mod(e * h) }; }
  static BigInteger[] Mul(BigInteger s, BigInteger[] p) { var q = new[] { BigInteger.Zero, BigInteger.One, BigInteger.One, BigInteger.Zero }; while (s > 0) { if (!s.IsEven) q = Add(q, p); p = Add(p, p); s >>= 1; } return q; }
  static BigInteger LE(byte[] b, int off, int len) { var t = new byte[len + 1]; Array.Copy(b, off, t, 0, len); return new BigInteger(t); }
  static byte[] Enc(BigInteger[] p) { BigInteger zi = Inv(p[2]), x = Mod(p[0] * zi), y = Mod(p[1] * zi); var r = new byte[32]; var yb = y.ToByteArray(); Array.Copy(yb, r, Math.Min(32, yb.Length)); if (!x.IsEven) r[31] |= 0x80; return r; }
  static byte[] Scalar32(BigInteger s) { var r = new byte[32]; var b = s.ToByteArray(); Array.Copy(b, r, Math.Min(32, b.Length)); return r; }
  static byte[] H(params byte[][] parts) { using (var sha = SHA512.Create()) { int n = 0; foreach (var p in parts) n += p.Length; var buf = new byte[n]; int o = 0; foreach (var p in parts) { Array.Copy(p, 0, buf, o, p.Length); o += p.Length; } return sha.ComputeHash(buf); } }
  static BigInteger Clamp(byte[] h) { var a = new byte[32]; Array.Copy(h, a, 32); a[0] &= 248; a[31] &= 127; a[31] |= 64; return LE(a, 0, 32); }
  public static byte[] Public(byte[] seed) { return Enc(Mul(Clamp(H(seed)), B)); }
  public static byte[] Sign(byte[] seed, byte[] msg) {
    var h = H(seed); var a = Clamp(h); var A = Enc(Mul(a, B)); var prefix = new byte[32]; Array.Copy(h, 32, prefix, 0, 32);
    BigInteger r = LE(H(prefix, msg), 0, 64) % L; var R = Enc(Mul(r, B));
    BigInteger k = LE(H(R, A, msg), 0, 64) % L; BigInteger s = (r + k * a) % L;
    var sig = new byte[64]; Array.Copy(R, sig, 32); Array.Copy(Scalar32(s), 0, sig, 32, 32); return sig; }
}
