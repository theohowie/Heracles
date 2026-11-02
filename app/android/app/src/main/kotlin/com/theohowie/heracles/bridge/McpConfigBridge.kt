package com.theohowie.heracles.bridge

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * **MCP 配置宿主桥**（V0.4 F3，2026-11-02）—— 契约见 `docs/INTERFACE.md` §N16.2。
 *
 * ## 为什么持久化在宿主而不是 backend
 *
 * backend 是纯函数式编排层（无 IO、`dart test` 毫秒级）。配置要活过重启，
 * 落在 `SharedPreferences`；backend 只提供**形状与校验**（`McpServerConfig` /
 * `validateMcpServer`），组装与落盘由宿主做。
 *
 * ## 密钥纪律（三道）
 *
 * 1. Dart 保存前调 backend `validateMcpServer`（第一道闸，给出人话原因）；
 * 2. **这里再拦一次**：env 的键名含 `KEY`/`TOKEN`/`SECRET`/`PASSWORD` 一律拒绝
 *    （`E_MCP_SECRET_IN_ENV`）—— 防的是"绕过 UI 直接调通道"；
 * 3. **日志只出现 `name` 与状态码**：`env` 的值、URL 的 query 段都不打。
 *
 * ## 连接测试不在这里
 *
 * 宿主没有 MCP 客户端。真连接测试由 Dart 侧用框架 `McpManager` 做（见
 * `docs/接口.md` §11.3 的偏离登记）—— 在 Kotlin 里手搓一个 HTTP 握手只能
 * 得到一个**看起来像连上了**的结果，那是假信息。
 */
class McpConfigBridge(private val context: Context) {

    private companion object {
        const val PREFS = "heracles_mcp"
        const val KEY_SERVERS = "servers"

        const val ERR_SECRET_IN_ENV = "E_MCP_SECRET_IN_ENV"
        const val ERR_INVALID_CONFIG = "E_MCP_CONFIG_INVALID"

        /** 键名里出现这些片段 ⇒ 判定为"想塞密钥"（大小写无关）。 */
        val SECRET_HINTS = listOf("KEY", "TOKEN", "SECRET", "PASSWORD")
    }

    /** 全部服务器配置（**原样回传** —— env 已保证不含密钥，见类注释）。 */
    fun list(): Map<String, Any?> = mapOf("ok" to true, "servers" to readArray())

    /**
     * 新增/更新（按 `name` 覆盖）。
     *
     * 入参用 `Map<*, *>` 而不是 `Map<String, Any?>`：MethodChannel 过来的是
     * 平台 `Map<Object,Object>`，泛型在 JVM 上被擦除 —— 写成强类型只会在
     * 取值时炸 `ClassCastException`，且炸在运行期而不是编译期。
     *
     * 校验失败 ⇒ `{ok:false, error, code}`，**不写入**（非法配置宁可存不进去，
     * 也不要在连接时给用户一个看不懂的超时）。
     */
    fun save(server: Map<*, *>?): Map<String, Any?> {
        if (server == null) return failure(ERR_INVALID_CONFIG, "server 不能为空")

        val name = (server["name"] as? String)?.trim().orEmpty()
        if (name.isEmpty()) return failure(ERR_INVALID_CONFIG, "name 不能为空")

        val transport = (server["transport"] as? String)?.trim().orEmpty()
        if (transport != "stdio" && transport != "http") {
            return failure(ERR_INVALID_CONFIG, "transport 只能是 stdio 或 http（收到 $transport）")
        }

        val command = (server["command"] as? String).orEmpty()
        val url = (server["url"] as? String).orEmpty()
        if (transport == "stdio" && command.isBlank()) {
            return failure(ERR_INVALID_CONFIG, "stdio 模式必须给 command")
        }
        if (transport == "http" && !url.startsWith("http://") && !url.startsWith("https://")) {
            return failure(ERR_INVALID_CONFIG, "http 模式 url 必须以 http:// 或 https:// 开头")
        }

        val env = server["env"]
        val envObj = when (env) {
            is Map<*, *> -> JSONObject()
            is JSONObject -> JSONObject(env.toString())
            else -> JSONObject()
        }
        if (env is Map<*, *>) {
            for ((k, v) in env) {
                val key = k?.toString().orEmpty()
                envObj.put(key, v?.toString().orEmpty())
            }
        }
        // ★ 第二道闸：密钥不许进 env
        val keys = envObj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            if (SECRET_HINTS.any { k.uppercase().contains(it) }) {
                return failure(
                    ERR_SECRET_IN_ENV,
                    "不要把密钥写进 MCP 环境变量（$k）—— 应使用宿主的安全存储",
                )
            }
        }

        val args = JSONArray()
        (server["args"] as? List<*>)?.forEach { args.put(it?.toString().orEmpty()) }

        val obj = JSONObject()
            .put("name", name)
            .put("transport", transport)
            .put("command", command)
            .put("url", url)
            .put("args", args)
            .put("env", envObj)
            .put("enabled", server["enabled"] as? Boolean ?: true)

        val arr = readArray()
        var replaced = false
        for (i in 0 until arr.length()) {
            if (arr.optJSONObject(i)?.optString("name") == name) {
                arr.put(i, obj)
                replaced = true
                break
            }
        }
        if (!replaced) arr.put(obj)

        if (!writeArray(arr)) return failure(ERR_INVALID_CONFIG, "保存失败（写入 prefs 出错）")
        return mapOf("ok" to true)
    }

    /** 删除（未知 ⇒ `deleted:false`，**不报错** —— 幂等删除）。 */
    fun delete(name: String): Map<String, Any?> {
        if (name.isBlank()) return failure(ERR_INVALID_CONFIG, "name 不能为空")
        val arr = readArray()
        val kept = JSONArray()
        var deleted = false
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (o.optString("name") == name) {
                deleted = true
            } else {
                kept.put(o)
            }
        }
        if (!deleted) return mapOf("ok" to true, "deleted" to false)
        if (!writeArray(kept)) return failure(ERR_INVALID_CONFIG, "删除失败（写入 prefs 出错）")
        return mapOf("ok" to true, "deleted" to true)
    }

    // ---------------------------------------------------------------- 存储

    private fun readArray(): JSONArray =
        runCatching {
            JSONArray(
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .getString(KEY_SERVERS, "[]") ?: "[]",
            )
        }.getOrElse { JSONArray() }

    /** 落盘（用 `commit()` 而不是 `apply()`：调用方要**当场**知道成没成）。 */
    private fun writeArray(arr: JSONArray): Boolean = runCatching {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_SERVERS, arr.toString()).commit()
    }.getOrDefault(false)

    private fun failure(code: String, message: String): Map<String, Any?> =
        mapOf("ok" to false, "error" to message, "code" to code)
}
