/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * This file is part of Heracles-taixu-sandbox.
 *
 * Heracles-taixu-sandbox is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Heracles-taixu-sandbox is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Heracles-taixu-sandbox.  If not, see <https://www.gnu.org/licenses/>.
 *
 * 移植来源: taixu dc7fcddb88e565929379597bbd811b440d00e34f
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/OciRegistryClient.kt
 *           （上游用 kotlinx.serialization 的 JsonObject/jsonArray/jsonPrimitive；
 *             沙箱的依赖白名单不允许 kotlinx-serialization，因此这里手写一个
 *             只覆盖 OCI manifest / token 所需的极小子集）
 *
 * ============================================================================
 * 为什么手写而不是引 kotlinx.serialization
 * ============================================================================
 * task 的硬约束写死了依赖：sandbox-api、androidx.core.ktx、kotlinx-coroutines、
 * kotlin stdlib、java.io/nio/jar/zip。加一个 JSON 库会引入反射 + 序列化器
 * 生成，既超范围又给 AAR 增重（这个沙箱 AAR 是要嵌进宿主 APK 的）。
 *
 * OCI manifest、registry token 这两种 JSON 都是**极简结构**：
 *   - 只有 object / array / string / number / bool / null
 *   - 没有 NaN / Infinity / 大数精度要求（size 是 Long，digest 是字符串）
 *   - 没有需要保留顺序的语义
 * ⇒ 手写 200 行足够，而且**完全可控**：不会因为库的默认行为（比如忽略未知键、
 *    数字精度）在 OCI 这种边界场景里悄悄改语义。
 *
 * ============================================================================
 * 严格性
 * ============================================================================
 * 这是**安全边界上的解析器**（解析的是远程 registry 的响应），所以刻意严格：
 *   - 拒绝尾随逗号
 *   - 拒绝未加引号的键
 *   - 拒绝非法转义（只接受 \" \\ \/ \b \f \n \r \t \uXXXX）
 *   - 数字只接受 JSON 语法（不接受前导 +、.5、1.、0x10）
 *   - 解析完必须消费掉全部输入（尾随垃圾 = 错误）
 * 任何一项不满足都抛 [JsonException] —— 上层转成 CODE_ROOTFS_CORRUPT。
 */

package com.heracles.sandbox.runtime

/** JSON 解析失败。 */
class JsonException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * 极简 JSON 值。
 *
 * 用 sealed class 而不是 `Any`：强制调用方处理每种类型，而且
 * [asObject]/[asArray]/[asString]/[asLong] 能给出**准确的**错误信息
 * （「这不是个 object」比 ClassCastException 有用得多）。
 */
sealed class JsonValue {

    /** JSON object。**保留插入顺序**（诊断时有用；OCI 语义上不要求）。 */
    data class JsonObject(val entries: Map<String, JsonValue>) : JsonValue(), Iterable<Map.Entry<String, JsonValue>> {
        operator fun get(key: String): JsonValue? = entries[key]
        fun has(key: String): Boolean = entries.containsKey(key)
        /** 键值对迭代（保持插入顺序）。 */
        override fun iterator(): Iterator<Map.Entry<String, JsonValue>> = entries.entries.iterator()
        fun keys(): Set<String> = entries.keys
    }

    data class JsonArray(val items: List<JsonValue>) : JsonValue(), Iterable<JsonValue> {
        fun isEmpty(): Boolean = items.isEmpty()
        fun size(): Int = items.size
        override fun iterator(): Iterator<JsonValue> = items.iterator()
    }

    data class JsonString(val value: String) : JsonValue()

    /** 数字统一存成 String + Double：避免 Long/Double 的精度纠缠（OCI 里只需要 Long）。 */
    data class JsonNumber(val raw: String) : JsonValue() {
        fun asLongOrNull(): Long? = raw.toLongOrNull()
        fun asDoubleOrNull(): Double? = raw.toDoubleOrNull()
    }

    data class JsonBool(val value: Boolean) : JsonValue()

    object JsonNull : JsonValue() {
        override fun toString(): String = "null"
    }

    // ---- 便捷取用（失败时抛带路径信息的异常） ----

    fun asObject(): JsonObject = this as? JsonObject
        ?: throw JsonException("期望 JSON object，实际是 ${typeName()}")

    fun asArray(): JsonArray = this as? JsonArray
        ?: throw JsonException("期望 JSON array，实际是 ${typeName()}")

    fun asString(): String = (this as? JsonString)?.value
        ?: throw JsonException("期望 JSON string，实际是 ${typeName()}")

    fun asLong(): Long? = (this as? JsonNumber)?.asLongOrNull()

    fun asBoolean(): Boolean = (this as? JsonBool)?.value
        ?: throw JsonException("期望 JSON boolean，实际是 ${typeName()}")

    private fun typeName(): String = when (this) {
        is JsonObject -> "object"
        is JsonArray -> "array"
        is JsonString -> "string"
        is JsonNumber -> "number"
        is JsonBool -> "boolean"
        JsonNull -> "null"
    }
}

/**
 * 极简 JSON 解析器（递归下降，无递归深度保护 → 有显式深度上限）。
 *
 * 用法：`MiniJson.parse(text)`。失败抛 [JsonException]。
 */
object MiniJson {

    /** 嵌套深度上限：防止恶意深嵌套把栈打爆。 */
    private const val MAX_DEPTH = 64

    /** 输入长度上限：manifest 正常 < 1MB，token < 4KB。 */
    private const val MAX_LENGTH = 8 * 1024 * 1024

    fun parse(text: String): JsonValue {
        if (text.isEmpty()) throw JsonException("JSON 输入为空")
        if (text.length > MAX_LENGTH) {
            throw JsonException("JSON 输入过长（${text.length} > $MAX_LENGTH）")
        }
        val parser = Parser(text)
        val value = parser.parseValue(depth = 0)
        parser.skipWhitespace()
        if (!parser.atEnd()) {
            throw JsonException("JSON 尾部有多余内容（位置 ${parser.position()}）")
        }
        return value
    }

    private class Parser(private val text: String) {
        private var index = 0

        fun position(): Int = index

        fun atEnd(): Boolean = index >= text.length

        fun skipWhitespace() {
            while (index < text.length) {
                when (text[index]) {
                    ' ', '\t', '\n', '\r' -> index++
                    else -> return
                }
            }
        }

        fun parseValue(depth: Int): JsonValue {
            if (depth > MAX_DEPTH) {
                throw JsonException("JSON 嵌套过深（>$MAX_DEPTH）")
            }
            skipWhitespace()
            if (atEnd()) throw JsonException("JSON 意外结束（位置 $index）")
            return when (val ch = text[index]) {
                '{' -> parseObject(depth)
                '[' -> parseArray(depth)
                '"' -> JsonValue.JsonString(parseString())
                't' -> {
                    expectLiteral("true")
                    JsonValue.JsonBool(true)
                }
                'f' -> {
                    expectLiteral("false")
                    JsonValue.JsonBool(false)
                }
                'n' -> {
                    expectLiteral("null")
                    JsonValue.JsonNull
                }
                else -> {
                    if (ch == '-' || ch.isDigit()) {
                        JsonValue.JsonNumber(parseNumber())
                    } else {
                        throw JsonException("非法 JSON 字符 '$ch'（位置 $index）")
                    }
                }
            }
        }

        private fun parseObject(depth: Int): JsonValue.JsonObject {
            expect('{')
            val entries = LinkedHashMap<String, JsonValue>()
            skipWhitespace()
            if (!atEnd() && text[index] == '}') {
                index++
                return JsonValue.JsonObject(entries)
            }
            while (true) {
                skipWhitespace()
                if (atEnd() || text[index] != '"') {
                    throw JsonException("JSON object 的键必须是字符串（位置 $index）")
                }
                val key = parseString()
                if (entries.containsKey(key)) {
                    throw JsonException("JSON object 有重复键 '$key'（位置 $index）")
                }
                skipWhitespace()
                expect(':')
                val value = parseValue(depth + 1)
                entries[key] = value
                skipWhitespace()
                if (atEnd()) throw JsonException("JSON object 未闭合（位置 $index）")
                when (text[index]) {
                    ',' -> {
                        index++
                        skipWhitespace()
                        // ★ 拒绝尾随逗号 {"a":1,}
                        if (!atEnd() && text[index] == '}') {
                            throw JsonException("JSON object 不允许尾随逗号（位置 $index）")
                        }
                    }
                    '}' -> {
                        index++
                        return JsonValue.JsonObject(entries)
                    }
                    else -> throw JsonException("JSON object 里期望 ',' 或 '}'（位置 $index）")
                }
            }
        }

        private fun parseArray(depth: Int): JsonValue.JsonArray {
            expect('[')
            val items = mutableListOf<JsonValue>()
            skipWhitespace()
            if (!atEnd() && text[index] == ']') {
                index++
                return JsonValue.JsonArray(items)
            }
            while (true) {
                val value = parseValue(depth + 1)
                items += value
                skipWhitespace()
                if (atEnd()) throw JsonException("JSON array 未闭合（位置 $index）")
                when (text[index]) {
                    ',' -> {
                        index++
                        skipWhitespace()
                        // ★ 拒绝尾随逗号 [1,2,]
                        if (!atEnd() && text[index] == ']') {
                            throw JsonException("JSON array 不允许尾随逗号（位置 $index）")
                        }
                    }
                    ']' -> {
                        index++
                        return JsonValue.JsonArray(items)
                    }
                    else -> throw JsonException("JSON array 里期望 ',' 或 ']'（位置 $index）")
                }
            }
        }

        private fun parseString(): String {
            expect('"')
            val builder = StringBuilder()
            while (true) {
                if (atEnd()) throw JsonException("JSON 字符串未闭合（位置 $index）")
                val ch = text[index++]
                when {
                    ch == '"' -> return builder.toString()
                    ch == '\\' -> builder.append(parseEscape())
                    // 裸控制字符（< 0x20）在 JSON 里必须转义
                    ch.code < 0x20 -> throw JsonException(
                        "JSON 字符串里有未转义的控制字符 U+${ch.code.toString(16)}（位置 ${index - 1}）",
                    )
                    else -> builder.append(ch)
                }
            }
        }

        private fun parseEscape(): Char {
            if (atEnd()) throw JsonException("JSON 转义序列未完成（位置 $index）")
            return when (val escape = text[index++]) {
                '"' -> '"'
                '\\' -> '\\'
                '/' -> '/'
                'b' -> '\b'
                'f' -> '\u000C'
                'n' -> '\n'
                'r' -> '\r'
                't' -> '\t'
                'u' -> {
                    if (index + 4 > text.length) {
                        throw JsonException("\\u 转义缺少 4 位 hex（位置 $index）")
                    }
                    val hex = text.substring(index, index + 4)
                    index += 4
                    hex.toIntOrNull(16)?.toChar()
                        ?: throw JsonException("\\u 转义不是合法 hex：$hex")
                }
                else -> throw JsonException("非法 JSON 转义 \\$escape（位置 ${index - 1}）")
            }
        }

        private fun parseNumber(): String {
            val start = index
            if (!atEnd() && text[index] == '-') index++
            if (atEnd()) throw JsonException("JSON 数字不完整（位置 $index）")
            // 整数部分：0 或 [1-9][0-9]*
            when {
                text[index] == '0' -> index++
                text[index].isDigit() -> while (!atEnd() && text[index].isDigit()) index++
                else -> throw JsonException("JSON 数字格式非法（位置 $index）")
            }
            // 小数部分
            if (!atEnd() && text[index] == '.') {
                index++
                val fractionStart = index
                while (!atEnd() && text[index].isDigit()) index++
                if (index == fractionStart) {
                    throw JsonException("JSON 数字小数点后没有数字（位置 $index）")
                }
            }
            // 指数部分
            if (!atEnd() && (text[index] == 'e' || text[index] == 'E')) {
                index++
                if (!atEnd() && (text[index] == '+' || text[index] == '-')) index++
                val exponentStart = index
                while (!atEnd() && text[index].isDigit()) index++
                if (index == exponentStart) {
                    throw JsonException("JSON 数字指数部分没有数字（位置 $index）")
                }
            }
            return text.substring(start, index)
        }

        private fun expectLiteral(literal: String) {
            if (index + literal.length > text.length ||
                !text.regionMatches(index, literal, 0, literal.length)
            ) {
                throw JsonException("期望字面量 '$literal'（位置 $index）")
            }
            index += literal.length
        }

        private fun expect(ch: Char) {
            if (atEnd() || text[index] != ch) {
                val actual = if (atEnd()) "<EOF>" else "'${text[index]}'"
                throw JsonException("期望 '$ch'，实际 $actual（位置 $index）")
            }
            index++
        }
    }
}
