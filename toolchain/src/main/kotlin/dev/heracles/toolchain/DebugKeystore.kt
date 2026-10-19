package dev.heracles.toolchain

import java.util.Base64

/**
 * **调试签名密钥**（内嵌）—— `26-编码层工具链与逆向引擎.md` §6.3。
 *
 * ## 为什么必须内嵌一份密钥
 *
 * 没有密钥就**签不出可安装的 APK**，而设备上**没有 `keytool`**（JDK 只有 PC 有）。
 * 若无内嵌密钥，"从零构建 Hello World 并安装"这条验收路径在真机上
 * **第一步就断**（`26` §6.3）。
 *
 * 这与 Android SDK 自带的 `debug.keystore`（口令就是公开的 `android`）
 * 是同一个思路：**它是调试密钥，不是身份**。
 *
 * ## ⚠️ 三条不可越过的边界
 *
 * | 事项 | 结论 |
 * |---|---|
 * | 用于**本地安装调试** | ✅ 本密钥存在的全部意义 |
 * | 用于**分发/上架** | ❌ 绝不。任何人都能用它签出"同一开发者"的包 |
 * | 承载用户真实身份 | ❌ 用户在设置里指定自己的 `.jks` 后，本密钥不该再被使用 |
 *
 * ## 内容
 *
 * RSA 2048 / 有效期 30 年 / 别名 `heracles` / 口令 `android`。
 * 属性与 `Contract.Toolchain.KEY_ALIAS` / `KEYSTORE_PASS` 一致 ——
 * 两边不一致会表现为"签名失败但原因看不懂"。
 */
object DebugKeystore {

    /**
     * 密钥库字节（Base64）。
     *
     * ## ⚠️ 实际容器是 **PKCS#12**，不是 JKS（2026-10-16 `keytool` 实测）
     *
     * ```
     * 密钥库类型: PKCS12          ← keytool -list -keystore heracles.jks
     * 前 16 字节: 30 82 0A 78 ... ← DER SEQUENCE，不是 JKS 魔数 FE ED FE ED
     * ```
     *
     * 既然实测与注释矛盾，**以实测为准**。不改重做成 JKS，因为三条路都自动兼容：
     *
     * | 使用方 | 行为 |
     * |---|---|
     * | `KeyStore.getInstance("JKS")` | 载入时**自动降级**按 PKCS12 探测（`DebugKeystoreTest` 就是这么验的）|
     * | `apksigner sign --ks` | 自动识别（2026-10-16 用 build-tools 36.1.0 实测 exit=0）|
     * | 文件名 `.jks` | 无功能影响；`ToolchainPaths` 按 `heracles.jks` 找，保持一致 |
     *
     * 生成命令见 `docs/实测-03-复现手册.md`。
     */
    private const val B64: String =
        "MIIKeAIBAzCCCiIGCSqGSIb3DQEHAaCCChMEggoPMIIKCzCCBbIGCSqGSIb3DQEHAaCCBaMEggWfMIIFmzCCBZcGCyqG" +
            "SIb3DQEMCgECoIIFQDCCBTwwZgYJKoZIhvcNAQUNMFkwOAYJKoZIhvcNAQUMMCsEFB+v6qKRf0tC8sMXie+c1sFGIIv4" +
            "AgInEAIBIDAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQAZb9jmBg1WMy/RHJfdZ10wSCBNAbcHm0yBDmdF1kQ+BE" +
            "AwwuHKEHYPas6yTRQkuoibBAn3totGsROd780hkRKqY0k8XEfbhjV5MYnVDwHcDqkcOMaGN1mDwEZ5QaoWG/ge8t3yjh" +
            "QKcQZMyo8KGa7U8xuR8KcImjSIxYcWjaq+OAB1+DRe7vm+LareyncFT2y+cxNqNh/No1lwZ9Ooq3NyY+SAFljl1MMfU" +
            "tawTOiui0e6z8Ubwc+psEEjIk97pQsUynL1sZiP8FDeSjlItiMgJtdv8SaltwqopsuwNz8R1PN4vZAfJZG5VWGuOxqaA" +
            "f0e8TuHDLGU3pXC4vHrmMOFldw1p6tXXxb15jFhXCXVXhNDm5RkGQK6ul098BNApgHMBDgVRrwVloF8gVIO7AAO//od2" +
            "beM5QNelmT8cc5+aVl6qx6tEoohvjMgWBPTqsUreYX6+h4dlCqBn0grhVC1DUAIQfP3e/f1Tz/yWjJ2tkBgr9YxrnwsY" +
            "LdlaYpV4kMSwCWjMOQob3+6q0eKBI3ltf8JNSbAGN61v3Dh2jKgNwOdUW9O9wAGYTcovdPl2+wQmheohaRUdDsymkLUa" +
            "GWddi8SCphbw57phS0DKxQYd06fX3/WYwXZi5EGBJmN3be70hdiIcUlRxDNzO9eADHYSEcRLvB4nJ+pI/8Emm7eLyLUb" +
            "TyGjMd3nsEIOgJfPK2d5KPpNjh5SY45U/39dSmIjhhF1tjsBI9iE1pcq8hZoWkAknmWFZ9bMw4sbVcWjV/9xJ0akpZnj" +
            "S8pzkyqvc4+VMPNa/Rj7Nfi8Iwe3CtWEGcoFmuGFHzPmsNm+tzv4w4tKJ6cp/asslYU1LF/keuLqogHg8TXpmAo+6f9Z" +
            "RfI6PyX+jz8und3A0y/g8NMrC3dqZD/bNjj8E9eyD0DdFuNnEtnPOKO4rk8b2eLwIRxJE6n3xv07qEe7b1kIX4sE5AlkZ" +
            "3Zxi5ECuoxRB0GqhNhYYv7t3s+ERXZdyFqoUp/YuCXInXuhlMyxnnnJJRO8QuzxJk7QWQjyE2PYB4QSeyv5iw5QjqPTu" +
            "hSbf3ZmoH1ILTMXZeK46SvNVE/+I2ha2Ey7Er/LhsJNGQNvFouJSWOvm8UNGb2lwetYVettvMP4u+Ym1wqR9PljVEkO4" +
            "XRG5BhAs5IOvhmJOuZlluvlg6viFUwhGpe67gIkFTOjM5+UydPZzxtzmhHjtz0I9X7wZnCxaZDIKg842w3AVCXiZzWsfU" +
            "N6VTVQ3ThjIzNfnR0hKWGdtthLPpjNaLN7LtPdNNc1NMvzek2Ab+bNt/tQKIY9d+mlUjgDYFeMxLTV2qHkiZkXtUJzoK" +
            "BrVhnAov9+MM34HukX35uBWoneVPAMXtduUWZ1Y8Gx5bqcGWPSwkrTHH3RIesVzzc+mSIzKjdKK2M0ipbGt4L4gBAsux" +
            "xXN1iqpOuZ3lyhRIEck0cVonoCMM/0vLv3AqUGZCOF2nmvgX6bSjrLQlKTYrDXnW1u29DZEZLHaFCvlBG5cPsL1cuSJU" +
            "c6IANHTG8n29CAXrO8qeiV08Sq/mxZ7CISMSZzSEKTwiDF8+jrMYQvRiVRWP+nOHHbNQBgv/nyUv2OdqOCM+BmyXPCb8" +
            "PThGwCTuWO90xLiA6QVELqb++fZj1zc95gJZcJ6e0bdu1/nfxEDwCvxl+ZYhDFEMB8GCSqGSIb3DQEJFDESHhAAaABlAH" +
            "IAYQBjAGwAZQBzMCEGCSqGSIb3DQEJFTEUBBJUaW1lIDE3OTIxMzE0Mzk5OTIwggRRBgkqhkiG9w0BBwagggRCMIIEPg" +
            "IBADCCBDcGCSqGSIb3DQEHATBmBgkqhkiG9w0BBQ0wWTA4BgkqhkiG9w0BBQwwKwQUhnBkkRo31Gwh1FMKjgSVCBX3jH" +
            "QCAicQAgEgMAwGCCqGSIb3DQIJBQAwHQYJYIZIAWUDBAEqBBBDiiyUxEcdPqWqvxSObUpkgIIDwP9yRtFNYwEZi6YLmN" +
            "D8ELdTGHaJpqNgxC8RE5mmz2EC8gsBxQKupByTpK3MUGoxdfl0px+PpaA/lXwYVTHFUKZrqwSJWY0OPiUqwSN6dX19MH" +
            "kU8YKl9viUl86RkLn8sxxwOfddtLSOGXX2RAm6kMQRkP52t9BJI+kv4OWVaWMdmfNpk+WXqm4lMx9yoPAPyNj8sgnLXi" +
            "ozgwo2velAfXcHjBg5/mtxfInYmNc3akOEpo/7ugy7YzbGT4U9UoYpIifI6J31mo9DIEjHdjr2CGsClYGVwsl7zhoIFH" +
            "RUOZiDIwJNGaktJ63Wbjz+JkeNY5RxTw7XSi7bGgh63uYreKkwWQJUsew+qDhYo1gNBU7PDh5K6o3sEG29DqpsfLtjut" +
            "sQ2p/Hs0WGNnkR2+XhH/XB3fGYDZF3fDzwyV4N/310PT2eWO+EUwfd1+Pz46I1utyBa0FFsCRzGAlRm/We6sW1ymzcGS" +
            "ZF+qABE8/IvlR+JF6qno9N11cCkTXufjPcCxSUPzU5LOS3onIb5vBFfCp24LpRbNqeAZVSR8LyIVJjIeyOed+6GjRLAl" +
            "hQWansiLKsQnqVUIGNppaFLgIapxy23qomAFiSeuMslwq8U0HqCWaQbVpnODqBba7N6C+kp2RqpVKPF6sjQoLk7vcGXA" +
            "67OnA0HSszfayyW3aHydpl53aYftzD+tS0z9YRSnc5awNsGe3Mv4BIxa/91TiOtKdP2Ubk7zO+1UcHbMgyqaEyo0AGFBs" +
            "AKaJrmGBNkxbdf3ILkfJGmBInj9aFiEnXNM1vz+EYwuy8SuDetwTqS1Reml+iGDt8lJnTl5EUJVjLqARO/ZXFDXeBne//" +
            "GvvBEGCci1Hf3vr7eseoAF0IWokbQsRagbZysrnty7xr9XYB29aKI2hxaV3guyGfWII9E1JOm+JYuy+cgzvbvRyC65gKF" +
            "l8nJ339h5F0lVSN4x6nIgRM8y/WZubeYp2TJOFQ9O7zJDVSE0bUi3RS11kRPwJiUB+AIESXNhJVHZMnL7y/PMG43lAvnO" +
            "EClh/WPxonUEJ1L4hmYP8RFn40QwOlOL/7pdSq1AqToFm2MBzNXkINFnf1/ECKJxxMgE9ALOqNz6XyYjukeHaZDWYT/2h" +
            "B11QJBKE0ZA+FJ5d3N1GV+FjNpHGx/XyVrEs8BIph4ChdxJ8v5aBxEOHQ1kzJvKqgrMCEEeG1XgFyXBv7GjLn7t2xZXZ" +
            "rCC7YnGryKyWaRx29Pr0oEdFID5uuj82ttjZuSjwzYPTRgI+u2phM8Ih0urkovzBNMDEwDQYJYIZIAWUDBAIBBQAEIDoq" +
            "Tm0ZuwkjDT9rYzQ7Ej+shgMF1s4pCEws747zazA6BBQNY7PRg95iTjCP4m8qXiiQ48iPXAICJxA="

    /** 解码后的 JKS 字节。 */
    fun bytes(): ByteArray = Base64.getDecoder().decode(B64)

    /** 密钥口令 —— 与 [dev.heracles.core.contract.Contract.Toolchain.KEYSTORE_PASS] 一致。 */
    const val PASS = "android"
}
