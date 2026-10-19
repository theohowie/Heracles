package dev.heracles.agent

import dev.heracles.core.contract.Contract
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **重复 JSON 键扫描器**（F9c / 路线 B）—— 纯函数门禁，无 FS、无网络。
 *
 * ## 这个类为什么值得单独测
 *
 * `gson` 对重复键是 last-wins（静默覆盖）⇒ 拒绝只能自己扫。而"自己扫"这件事
 * **假绿风险极高**：只要扫描器永远返回"没重复"，`BuildProfileLoader` 的坏输入测试
 * 全都会绿（因为那些输入本来就没有重复键）。所以这里对**每一格**都钉：
 * 真重复要抓到（顶层/嵌套/三层/数组内/三次出现）、
 * **不许假阳性**（数组不同元素、不同对象里的同名键、值里的 JSON 文本）、
 * 以及**扫不动时绝不许说 Clean**（截断输入、lenient 扩展语法、超深）。
 */
class DuplicateKeysTest {

    // ---------------------------------------------------------------- 真重复：必须抓到

    @Test
    @DisplayName("★ 顶层重复键 ⇒ 抓到（路径 root.id，次数 2）")
    fun topLevelDuplicate() {
        val d = found("""{"id":"a","id":"b"}""")
        assertEquals(1, d.size, "只该报一处：$d")
        assertEquals("id", d[0].key)
        assertEquals("root.id", d[0].path, "路径要能照着找：$d")
        assertEquals(2, d[0].count)
    }

    @Test
    @DisplayName("★ 两次的值**完全相同**也拒绝（\"值一样所以无所谓\"会掩盖\"本想写两个对象\"）")
    fun identicalValuesStillRejected() {
        assertEquals(2, found("""{"k":1,"k":1}""")[0].count)
    }

    @Test
    @DisplayName("★ 三次出现 ⇒ 次数如实报 3")
    fun threeOccurrencesCounted() {
        assertEquals(3, found("""{"k":1,"k":2,"k":3}""")[0].count)
    }

    @Test
    @DisplayName("★ 嵌套对象里的重复 ⇒ 路径含父对象")
    fun duplicateInNestedObject() {
        assertEquals("root.a.k", found("""{"a":{"k":1,"k":2}}""")[0].path)
    }

    @Test
    @DisplayName("★★ 嵌套**三层**里的重复 ⇒ 路径 root.a.b.c.k（gson 只留最后一个，扫不出来就白做）")
    fun duplicateThreeLevelsDeep() {
        val d = found("""{"a":{"b":{"c":{"k":1,"k":2}}}}""")
        assertEquals("root.a.b.c.k", d[0].path)
        assertEquals("k", d[0].key)
    }

    @Test
    @DisplayName("★ 同一个数组元素**内**的重复 ⇒ 路径带下标 root.xs[0].k")
    fun duplicateInsideOneArrayElement() {
        assertEquals("root.xs[0].k", found("""{"xs":[{"k":1,"k":2}]}""")[0].path)
    }

    @Test
    @DisplayName("★ 数组套数组 ⇒ 路径 root.xs[0][0].k")
    fun nestedArrayIndicesInPath() {
        assertEquals("root.xs[0][0].k", found("""{"xs":[[{"k":1,"k":2}]]}""")[0].path)
    }

    @Test
    @DisplayName("★ 多处重复一次列全，按**首次出现顺序**")
    fun allDuplicatesInFirstAppearanceOrder() {
        val d = found("""{"b":1,"a":1,"b":2,"a":2}""")
        assertEquals(listOf("b", "a"), d.map { it.key }, "顺序要稳定（文案可复现）：$d")
        assertTrue(d.all { it.count == 2 }, "各自 2 次：$d")
    }

    @Test
    @DisplayName("★ 键里的转义引号 ⇒ 是键的一部分（不是字符串结束）")
    fun escapedQuoteInsideKey() {
        val d = found("""{"a\"b":1,"a\"b":2}""")
        assertEquals("""a"b""", d[0].key, "gson 已解码 ⇒ 我们拿到的是真键名")
        assertEquals("""root.a"b""", d[0].path)
    }

    @Test
    @DisplayName("★ 键的 \\uXXXX 转义与字面量是**同一个键**（附带好处：gson 帮我们解码）")
    fun unicodeEscapeIsTheSameKey() {
        // 注意：这里必须用原样字符串，否则 Kotlin 自己先把 \u0061 解成 'a'
        val d = found("""{"\u0061":1,"a":2}""")
        assertEquals(1, d.size, "解码后同键 ⇒ 只报一处：$d")
        assertEquals("a", d[0].key)
        assertEquals("root.a", d[0].path)
    }

    @Test
    @DisplayName("★ 空键是合法键 ⇒ 照常查重")
    fun emptyKeyIsChecked() {
        val d = found("""{"":1,"":2}""")
        assertEquals("", d[0].key)
        assertEquals("root.", d[0].path)
    }

    @Test
    @DisplayName("★ 大小写敏感：Id 与 id 不算重复（该由\"未知字段\"纪律去管 Id）")
    fun caseSensitive() {
        clean("""{"Id":1,"id":2}""")
    }

    // ---------------------------------------------------------------- 假阳性：必须不报

    @Test
    @DisplayName("★★ 数组的不同元素**各自独立作用域** ⇒ 不报（元素是两次独立的值，不是同一个对象）")
    fun arrayElementsAreSeparateScopes() {
        clean("""{"xs":[{"k":1},{"k":2}]}""")
    }

    @Test
    @DisplayName("★★ 值里的 JSON 文本不是键 ⇒ 不报（状态机/分词没被值骗到）")
    fun jsonLookingStringsAreNotKeys() {
        clean("""{"k":"{\"x\":1,\"y\":2}","j":1}""")
        clean("""{"k":"a,b:c{}[]","j":1}""")
    }

    @Test
    @DisplayName("★ 不同对象里的同名键不报（真实 profile 到处都是：root.id 与 step.id）")
    fun sameKeyNameInDifferentObjects() {
        clean("""{"id":"root","steps":[{"id":"A"},{"id":"B"}]}""")
    }

    @Test
    @DisplayName("★ 顶层是标量 / 数组 ⇒ 没有键 ⇒ Clean（\"顶层必须是对象\"由加载器管）")
    fun noKeysAtTopLevel() {
        clean("42")
        clean("[1,2]")
    }

    @Test
    @DisplayName("★★ 空输入 ⇒ **Unusable**，不是 Clean（扫描压根没跑起来，就无权说\"没发现重复\"）")
    fun emptyInputIsNotClaimedClean() {
        // 加载器在这之前就会以"顶层必须是 JSON 对象"拒绝，所以这一格只关乎扫描器自身的语义诚实：
        // Clean 的含义必须是"我走完了一个完整的值、里面没有重复键"，而不是"我没做检查"。
        val scan = DuplicateKeys.scan("")
        assertTrue(scan is DuplicateKeys.Scan.Unusable, "实际：$scan")
        assertTrue(DuplicateKeys.scan("   ") is DuplicateKeys.Scan.Unusable, "纯空白同理")
    }

    // ---------------------------------------------------------------- 扫不动：绝不许说 Clean

    @Test
    @DisplayName("★★ 截断输入（gson 也认为是坏 JSON）⇒ **Unusable**，绝不许 Clean")
    fun truncatedInputIsNeverClean() {
        val scan = DuplicateKeys.scan("""{"a":1,"a""")
        assertTrue(
            scan is DuplicateKeys.Scan.Unusable,
            "扫不动必须明确失败 —— 说 Clean 就是\"没发现重复\"的谎：$scan",
        )
    }

    @Test
    @DisplayName("★★ lenient 扩展语法（单引号键）⇒ Unusable（我们**不**按 gson lenient 的宽容度走）")
    fun lenientExtensionInputIsUnusable() {
        val scan = DuplicateKeys.scan("{'a':1}")
        assertTrue(scan is DuplicateKeys.Scan.Unusable, "实际：$scan")
        assertTrue(
            (scan as DuplicateKeys.Scan.Unusable).reason.contains("遍历失败"),
            "文案要说明\"扫不动\"的原因：${scan.reason}",
        )
    }

    @Test
    @DisplayName("★★ 深度 64 层（上限内）⇒ 仍能扫到最里层的重复；第 65 层 ⇒ Unusable")
    fun depthBoundaryIsHonest() {
        // 64 个对象帧（最外层 1 + 63 个包装）恰好等于 MAX_DEPTH ⇒ 放行
        assertEquals(
            "k",
            found(nestedObjects(Contract.Json.MAX_DEPTH, """"k":1,"k":2"""))[0].key,
            "上限内不许误报\"超深\"，否则合法的深配置会被拒",
        )
        val tooDeep = DuplicateKeys.scan(nestedObjects(Contract.Json.MAX_DEPTH + 1, """"k":1"""))
        assertTrue(tooDeep is DuplicateKeys.Scan.Unusable, "超深必须明确失败：$tooDeep")
        assertTrue(
            (tooDeep as DuplicateKeys.Scan.Unusable).reason.contains(Contract.Json.MAX_DEPTH.toString()),
            "文案要点名上限：${tooDeep.reason}",
        )
    }

    @Test
    @DisplayName("★ 深度 2000 层不崩（显式帧栈、不递归）—— 依然是\"明确失败\"，不是 StackOverflow")
    fun absurdDepthDoesNotBlowTheStack() {
        val scan = DuplicateKeys.scan(nestedObjects(2000, """"k":1"""))
        assertTrue(scan is DuplicateKeys.Scan.Unusable, "实际：$scan")
    }

    // ---------------------------------------------------------------- 文案

    @Test
    @DisplayName("★ 失败文案转义键名与路径：带换行/引号的键不能让文案碎成好几行")
    fun describeEscapesKeyAndPath() {
        val d = found("""{"a\nb":1,"a\nb":2}""")
        assertEquals(
            "有重复键 \"a\\nb\"（出现 2 次，位置 root.a\\nb）",
            DuplicateKeys.describe(d),
        )
        val q = found("""{"q\"x":1,"q\"x":2}""")
        assertTrue(
            DuplicateKeys.describe(q).contains("""q\"x"""),
            "引号要转义：${DuplicateKeys.describe(q)}",
        )
    }

    @Test
    @DisplayName("★ 真实剖面形状的合法 JSON ⇒ Clean（这条是加载器零回退的纯函数版对照）")
    fun realisticProfileIsClean() {
        clean(
            """
            {
              "schemaVersion": 1,
              "id": "my-variant",
              "displayName": "我的变体",
              "probe": { "manifestFile": "AndroidManifest.xml" },
              "steps": [
                { "id": "PREPARE", "title": "prepare", "fixedDetail": "（aapt2）" },
                { "id": "INSERT_DEX", "title": "插入 classes.dex", "inProcess": true }
              ],
              "artifact": { "defaultName": "app-debug.apk" }
            }
            """.trimIndent(),
        )
    }

    // ---------------------------------------------------------------- 夹具

    private fun found(json: String): List<DuplicateKeys.Duplicate> {
        val scan = DuplicateKeys.scan(json)
        assertTrue(scan is DuplicateKeys.Scan.Found, "期望发现重复键，实际：$scan（输入：$json）")
        return (scan as DuplicateKeys.Scan.Found).duplicates
    }

    private fun clean(json: String) {
        assertEquals(DuplicateKeys.Scan.Clean, DuplicateKeys.scan(json), "不许假阳性（输入：$json）")
    }

    /** `depth` 个嵌套对象，最里层放 [payload]（`depth = 1` ⇒ 就是 `{payload}`）。 */
    private fun nestedObjects(depth: Int, payload: String): String {
        val open = (1 until depth).joinToString("") { """{"a":""" }
        val close = "}".repeat(depth - 1)
        return open + "{" + payload + "}" + close
    }
}
