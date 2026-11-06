// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
// Ed25519.cs — 插件签名校验（只验证，不签名）：按 RFC 8032 第 5.1 节自己实现，只用 .NET 自带的 BigInteger 和 SHA-512，不用任何第三方代码。
// 另外带一个「规范 JSON」：等同于 Python 的 json.dumps(x, ensure_ascii=False, sort_keys=True, separators=(',',':'))，用来还原服务端签名的原文。
// 编译：见同目录 编译.ps1（Windows 自带的 .NET Framework csc.exe）
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

public static class Ed25519 {
  static readonly BigInteger P = BigInteger.Pow(2, 255) - 19;
  static readonly BigInteger L = BigInteger.Pow(2, 252) + BigInteger.Parse("27742317777372353535851937790883648493");
  static readonly BigInteger D = Mod(-121665 * Inv(121666));
  static readonly BigInteger I = BigInteger.ModPow(2, (P - 1) / 4, P);   // sqrt(-1)
  static readonly BigInteger[] B;   // 基点（扩展坐标）

  static Ed25519() {
    BigInteger by = Mod(4 * Inv(5)); BigInteger bx = RecoverX(by, 0);
    B = new[] { bx, by, BigInteger.One, Mod(bx * by) };
  }
  static BigInteger Mod(BigInteger a) { a %= P; return a.Sign < 0 ? a + P : a; }
  static BigInteger Inv(BigInteger a) { return BigInteger.ModPow(Mod(a), P - 2, P); }
  // 由 y 和 x 的符号位还原 x；不存在时返回 -1
  static BigInteger RecoverX(BigInteger y, int sign) {
    if (y >= P) return -1;
    BigInteger x2 = Mod((y * y - 1) * Inv(D * y * y + 1));
    if (x2.IsZero) return sign == 1 ? -1 : BigInteger.Zero;
    BigInteger x = BigInteger.ModPow(x2, (P + 3) / 8, P);
    if (Mod(x * x - x2) != 0) x = Mod(x * I);
    if (Mod(x * x - x2) != 0) return -1;
    if ((int)(x & 1) != sign) x = P - x;
    return x;
  }
  static BigInteger[] Add(BigInteger[] p, BigInteger[] q) {
    BigInteger a = Mod((p[1] - p[0]) * (q[1] - q[0])), b = Mod((p[1] + p[0]) * (q[1] + q[0]));
    BigInteger c = Mod(2 * p[3] * q[3] * D), d = Mod(2 * p[2] * q[2]);
    BigInteger e = b - a, f = d - c, g = d + c, h = b + a;
    return new[] { Mod(e * f), Mod(g * h), Mod(f * g), Mod(e * h) };
  }
  static BigInteger[] Mul(BigInteger s, BigInteger[] p) {
    var q = new[] { BigInteger.Zero, BigInteger.One, BigInteger.One, BigInteger.Zero };
    while (s > 0) { if (!s.IsEven) q = Add(q, p); p = Add(p, p); s >>= 1; }
    return q;
  }
  static bool Equal(BigInteger[] p, BigInteger[] q) {
    return Mod(p[0] * q[2] - q[0] * p[2]) == 0 && Mod(p[1] * q[2] - q[1] * p[2]) == 0;
  }
  static BigInteger LE(byte[] b, int off, int len) { var t = new byte[len + 1]; Array.Copy(b, off, t, 0, len); return new BigInteger(t); }
  static BigInteger[] Decompress(byte[] s, int off) {
    var t = new byte[32]; Array.Copy(s, off, t, 0, 32); int sign = t[31] >> 7; t[31] &= 0x7f;
    BigInteger y = LE(t, 0, 32); BigInteger x = RecoverX(y, sign); if (x < 0) return null;
    return new[] { x, y, BigInteger.One, Mod(x * y) };
  }
  // 验证：公钥 32 字节、签名 64 字节；任何格式不对都算失败（不抛异常）
  public static bool Verify(byte[] publicKey, byte[] message, byte[] signature) {
    try {
      if (publicKey == null || publicKey.Length != 32 || signature == null || signature.Length != 64 || message == null) return false;
      var A = Decompress(publicKey, 0); if (A == null) return false;
      var R = Decompress(signature, 0); if (R == null) return false;
      BigInteger s = LE(signature, 32, 32); if (s >= L) return false;
      byte[] h; using (var sha = SHA512.Create()) { var buf = new byte[64 + message.Length]; Array.Copy(signature, 0, buf, 0, 32); Array.Copy(publicKey, 0, buf, 32, 32); Array.Copy(message, 0, buf, 64, message.Length); h = sha.ComputeHash(buf); }
      BigInteger k = LE(h, 0, 64) % L;
      return Equal(Mul(s, B), Add(R, Mul(k, A)));
    } catch { return false; }
  }
  public static byte[] Hex(string h) { h = h.Trim(); var r = new byte[h.Length / 2]; for (int i = 0; i < r.Length; i++) r[i] = Convert.ToByte(h.Substring(i * 2, 2), 16); return r; }
}

// 规范 JSON：键按 Unicode 码位（序数）排序、没有空格、非 ASCII 原样输出；转义和 Python 一致
public static class CanonJson {
  public static string Of(object o) { var sb = new StringBuilder(); Write(sb, o); return sb.ToString(); }
  static void Write(StringBuilder sb, object o) {
    if (o == null) { sb.Append("null"); return; }
    if (o is bool) { sb.Append((bool)o ? "true" : "false"); return; }
    if (o is string) { Str(sb, (string)o); return; }
    if (o is int || o is long || o is short || o is byte || o is uint || o is ulong || o is BigInteger) { sb.Append(Convert.ToString(o, CultureInfo.InvariantCulture)); return; }
    if (o is decimal) { var d = (decimal)o; if (d == Math.Floor(d) && Math.Abs(d) < 1e15m) sb.Append(((long)d).ToString(CultureInfo.InvariantCulture)); else sb.Append(PyFloat((double)d)); return; }
    if (o is double || o is float) { sb.Append(PyFloat(Convert.ToDouble(o, CultureInfo.InvariantCulture))); return; }
    var dict = o as IDictionary;
    if (dict != null) {
      var keys = dict.Keys.Cast<object>().Select(k => k.ToString()).ToList(); keys.Sort(StringComparer.Ordinal);
      sb.Append('{'); bool first = true;
      foreach (var k in keys) { if (!first) sb.Append(','); first = false; Str(sb, k); sb.Append(':'); Write(sb, dict[k]); }
      sb.Append('}'); return;
    }
    var list = o as IEnumerable;
    if (list != null) { sb.Append('['); bool first = true; foreach (var x in list) { if (!first) sb.Append(','); first = false; Write(sb, x); } sb.Append(']'); return; }
    Str(sb, o.ToString());
  }
  // Python 的浮点数写法（repr）：最短能还原的写法，整数值带 .0
  static string PyFloat(double d) {
    if (double.IsNaN(d)) return "NaN"; if (double.IsInfinity(d)) return d > 0 ? "Infinity" : "-Infinity";
    string r = d.ToString("R", CultureInfo.InvariantCulture);
    if (r.Contains("E")) { var parts = r.Split('E'); int e = int.Parse(parts[1], CultureInfo.InvariantCulture); string m = parts[0];
      if (e >= -4 && e < 16) r = d.ToString("0.################", CultureInfo.InvariantCulture); else r = m + "e" + (e < 0 ? "-" : "+") + Math.Abs(e).ToString("00"); }
    if (!r.Contains(".") && !r.Contains("e") && !r.Contains("N") && !r.Contains("I")) r += ".0";
    return r;
  }
  static void Str(StringBuilder sb, string s) {
    sb.Append('"');
    foreach (char c in s) {
      switch (c) {
        case '"': sb.Append("\\\""); break; case '\\': sb.Append("\\\\"); break;
        case '\n': sb.Append("\\n"); break; case '\r': sb.Append("\\r"); break; case '\t': sb.Append("\\t"); break;
        case '\b': sb.Append("\\b"); break; case '\f': sb.Append("\\f"); break;
        default: if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4")); else sb.Append(c); break;
      }
    }
    sb.Append('"');
  }
}
