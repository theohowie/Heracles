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
 * 移植来源: taixu dc7fcddb88e565929379597bbd811b440d00e34f app/src/main/cpp/pty_native.c
 *
 * ============================================================================
 * 这是什么
 * ============================================================================
 * 真 PTY（forkpty 语义）后端。App 进程 openpty 出 master/slave 一对，
 * fork 出的子进程把 slave 作为**控制终端**（setsid + TIOCSCTTY + dup2 到 0/1/2），
 * 然后 execve。父进程保留 master fd，通过 JNI 驱动。
 *
 * 只有真 TTY 才有：行缓冲、Ctrl+C 产生的 SIGINT、SIGWINCH 尺寸变更、raw mode。
 * 用管道（ProcessBuilder）在跑 gradle / apt / 交互式编辑器时全部失配，
 * 这也是本文件存在的唯一理由。
 *
 * ============================================================================
 * ★ JNI 绑定方式：JNI_OnLoad + RegisterNatives（**不是**短名静态绑定）
 * ============================================================================
 * 上游用的是短名静态绑定（`Java_top_wkbin_taixu_runtime_pty_NativePty_*`）。
 * 本项目改用 RegisterNatives，原因是一个真实的结构性冲突：
 *
 *   - 短名绑定要求 Kotlin 的 external fun 是**外层类**的直接成员；
 *   - 但 `nativeOpenAndExec` 必须在「还没有 PtySession 实例」时被调用（它负责
 *     造出 fd/pid），也就是必须从 companion object 里调；
 *   - Kotlin 的 companion object 编译成独立类 `PtySession$Companion`，其成员的
 *     短名符号会变成 `Java_..._PtySession_00024Companion_nativeXxx`，对不上；
 *   - 反过来把 external fun 声明成 PtySession 的实例成员，静态工厂又调不到。
 *
 * RegisterNatives 一次解决：本文件显式按**类名 + 方法名 + 签名**注册，
 * 于是「这些函数放在 Kotlin 的哪个类里」不再影响 C 側符号名。
 *
 * ⇒ 注册目标是 `com/heracles/sandbox/runtime/PtySession$Companion`
 *   （Kotlin 侧：`class PtySession` 的 `companion object` 里的 private external fun）。
 * ⇒ 对应的 Kotlin 声明见 PtySession.kt 末尾 `companion object { external fun ... }`。
 * ⇒ **签名串必须与 Kotlin 声明逐字一致**；改 Kotlin 签名时这里必须同步改，
 *   否则 RegisterNatives 会失败 → JNI_OnLoad 返回错误 → System.loadLibrary 抛
 *   UnsatisfiedLinkError（这是刻意的：宁可加载失败也不要跑起来后在第一次调用
 *   时莫名其妙地崩）。
 *
 * ============================================================================
 * 与上游 taixu pty_native.c 的差异（都是"补漏"，不是重写）
 * ============================================================================
 * 1. C -> C++，但**不依赖任何 C++ 运行库**：无 std::、无异常、无 RTTI、无全局
 *    构造，全部函数 `static`。原因：build.gradle.kts 定稿为
 *    `-DANDROID_STL=none`，一旦生成 __cxa_* 引用就会 dlopen 失败。
 * 2. 绑定方式改为 RegisterNatives（见上）。
 * 3. 子进程 exec 失败时**把原因写到 fd 2**（上游只 `_exit(127)`，用户只看到
 *    终端静默退出）。格式化只用 write() + 手写整数，不用 snprintf ——
 *    fork 之后只允许 async-signal-safe 调用。
 * 4. 子进程 exec 之前把 SIGPIPE / SIGINT / SIGQUIT / SIGTERM / SIGHUP 等
 *    显式复位成 SIG_DFL，并清空信号屏蔽字。Zygote 起家的 JVM 进程里 SIGPIPE
 *    通常是 SIG_IGN，被忽略的信号**跨 execve 存活**；不清的话沙箱里
 *    `yes | head -1` 之类的管道拿不到正常终止。（上游没有这一步。）
 * 5. `nativeWaitNoHang` 返回**原始 wait status**（上游 pollExit 只返回 boolean，
 *    丢掉了退出码，ExecutionResult.exitCode 就拿不到真值）。
 * 6. `close_range` 同时检查 `SYS_close_range` 与 `__NR_close_range` 两套宏
 *    （不同 NDK 头版本暴露的名字不一样），都取不到就退化为逐个 close。
 * 7. 增加 logcat 诊断（liblog）：fork 之后主进程侧的关键失败打一行日志，
 *    否则 Kotlin 侧只能拿到 UnsatisfiedLinkError / IOException，无从定位。
 *
 * ============================================================================
 * 线程模型
 * ============================================================================
 * 本文件的函数都**不做无界阻塞**：read/write 内部 poll 上限 100ms，
 * `nativeWaitNoHang` 是 WNOHANG 的（Kotlin 侧自己 10ms 轮询）。
 * 于是任何一次 JNI 调用都是有界的，取消 / 关闭 / 超时都不会卡住调用线程。
 */

#include <jni.h>

#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define LOG_TAG "HeraclesPty"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/*
 * nativeWaitNoHang 的哨兵值。必须与 PtySession.kt 的 PTY_RUNNING / PTY_ERROR 一致。
 * 用 jlong 而不是 jint，是为了把「哨兵」和「原始 wait status」放进同一返回值
 * 而不混淆：合法 status 范围是 0..0xFFFF，负数区间全让给哨兵。
 */
static const jlong kWaitRunning = -1;
static const jlong kWaitError = -2;

/* PTY master 非阻塞读写的 poll 上限（毫秒）。见文件头「线程模型」。 */
static const int kPollTimeoutMs = 100;

/* -------------------------------------------------------------------------*/
/* 小工具                                                                    */
/* -------------------------------------------------------------------------*/

static void throw_io(JNIEnv *env, const char *what) {
    jclass cls = env->FindClass("java/io/IOException");
    if (cls != nullptr) {
        env->ThrowNew(cls, what);
        env->DeleteLocalRef(cls);
    }
}

static void throw_ise(JNIEnv *env, const char *what) {
    jclass cls = env->FindClass("java/lang/IllegalStateException");
    if (cls != nullptr) {
        env->ThrowNew(cls, what);
        env->DeleteLocalRef(cls);
    }
}

/*
 * 关掉 [first, ~0) 的全部 fd。
 *
 * fork() 会复制宿主 App 进程的全部文件描述符：SQLite 数据库、含 API key 密文的
 * DataStore、下载临时文件、网络 socket 都会被 exec 后的 shell 继承 —— PRoot
 * 沙箱内以 root 运行的进程可以直接通过 /proc/self/fd/N 读写宿主私有数据，
 * 同时泄漏的 fd 也会逐渐耗尽进程配额。优先用 close_range（Linux 5.9+）原子收口，
 * 老内核回退为逐个 close。
 */
static void close_from(int first) {
#if defined(SYS_close_range)
    if (syscall(SYS_close_range, (unsigned int)first, ~0U, 0u) == 0) return;
#elif defined(__NR_close_range)
    if (syscall(__NR_close_range, (unsigned int)first, ~0U, 0u) == 0) return;
#endif
    long max_fd = sysconf(_SC_OPEN_MAX);
    int limit = (max_fd > 0 && max_fd <= (1 << 20)) ? (int)max_fd : 1024;
    for (int fd = first; fd < limit; fd++) close(fd);
}

static void free_strings(char **array) {
    if (array == nullptr) return;
    for (int i = 0; array[i] != nullptr; i++) free(array[i]);
    free(array);
}

/*
 * Java String[] -> NULL 结尾的 char*[]。
 *
 * 失败时已分配部分全部释放并返回 nullptr。注意：nullptr 可能伴随已挂起的 OOM
 * 异常（GetStringUTFChars / calloc 失败），此时调用方**不得**再 ThrowNew，
 * 否则会覆盖掉真正的 OOM 信息。
 */
static char **strings_array(JNIEnv *env, jobjectArray array) {
    if (array == nullptr) return nullptr;
    const jsize n = env->GetArrayLength(array);
    /* 防御异常输入：理论上非负，但给个上界，避免超大数组 calloc 巨量内存。 */
    if (n < 0 || n > 100000) {
        throw_ise(env, "exec 参数数组长度非法");
        return nullptr;
    }
    char **result = (char **)calloc((size_t)n + 1, sizeof(char *));
    if (result == nullptr) {
        throw_ise(env, "内存不足：无法分配 exec 参数数组");
        return nullptr;
    }
    for (jsize i = 0; i < n; i++) {
        jstring s = static_cast<jstring>(env->GetObjectArrayElement(array, i));
        if (s == nullptr) continue; /* 允许 null 元素：跳过后由末尾 NULL 提前截断 */
        const char *cs = env->GetStringUTFChars(s, nullptr);
        if (cs == nullptr) {
            free_strings(result);
            env->DeleteLocalRef(s);
            return nullptr; /* 已挂起 OOM，异常原样交给 Java 侧 */
        }
        result[i] = strdup(cs);
        env->ReleaseStringUTFChars(s, cs);
        env->DeleteLocalRef(s);
        if (result[i] == nullptr) {
            free_strings(result);
            throw_ise(env, "内存不足：无法复制 exec 参数字符串");
            return nullptr;
        }
    }
    return result;
}

/*
 * 子进程里 exec/chdir 失败时，把「哪个程序 + errno」写到 fd 2。
 *
 * fork 之后只允许 async-signal-safe 调用，所以不用 snprintf / strerror：
 * 只用 write()，整数自己转十进制。消息格式固定，便于人工与测试比对：
 *   "exec failed: <program>: errno=<n>\n"
 */
static void child_report_failure(const char *what, const char *program, int err) {
    char buf[512];
    size_t pos = 0;
    auto append = [&](const char *text) {
        for (size_t i = 0; text[i] != '\0' && pos < sizeof(buf) - 1; i++) {
            buf[pos++] = text[i];
        }
    };
    append(what);
    append(": ");
    if (program != nullptr) append(program);
    append(": errno=");

    char digits[12];
    int count = 0;
    int value = err < 0 ? -err : err;
    if (value == 0) {
        digits[count++] = '0';
    } else {
        while (value > 0 && count < (int)sizeof(digits)) {
            digits[count++] = (char)('0' + (value % 10));
            value /= 10;
        }
    }
    if (err < 0 && pos < sizeof(buf) - 1) buf[pos++] = '-';
    while (count > 0 && pos < sizeof(buf) - 1) buf[pos++] = digits[--count];
    if (pos < sizeof(buf) - 1) buf[pos++] = '\n';

    /* 写失败也无可奈何：子进程马上就要 _exit。 */
    ssize_t ignored = write(STDERR_FILENO, buf, pos);
    (void)ignored;
}

/*
 * 子进程 exec 之前的信号复位。
 *
 * 被**忽略**的信号跨 execve 存活；Zygote/JVM 把 SIGPIPE 设成 SIG_IGN，
 * 不复位的话沙箱里的管道语义就是坏的。只复位「有明确意见」的那几个，
 * 不碰 realtime signal（ART 自己在用）。
 */
static void child_reset_signals(void) {
    static const int kSignals[] = {SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD,
                                   SIGTTIN, SIGTTOU, SIGWINCH};
    for (size_t i = 0; i < sizeof(kSignals) / sizeof(kSignals[0]); i++) {
        signal(kSignals[i], SIG_DFL);
    }
    /* 清空屏蔽字：JVM 可能屏蔽了某些信号，子进程不该继承。 */
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, nullptr);
}

/* -------------------------------------------------------------------------*/
/* native 实现                                                               */
/* -------------------------------------------------------------------------*/

/*
 * argv/envp/cwd/columns/rows -> int[]{masterFd, childPid}
 *
 * 子进程成为 session leader，slave 为其控制终端。
 * 返回 null 表示失败（此时已挂起 IOException / IllegalStateException）。
 */
static jintArray pty_open_and_exec(JNIEnv *env, jobject thiz, jobjectArray argv,
                                   jobjectArray envp, jstring cwd, jint columns, jint rows) {
    (void)thiz;

    int master = -1;
    int slave = -1;
    if (openpty(&master, &slave, nullptr, nullptr, nullptr) == -1) {
        LOGE("openpty failed: errno=%d", errno);
        throw_io(env, "openpty 失败：无法创建 PTY 对");
        return nullptr;
    }

    /* 只有 master 非阻塞：子进程侧要保持正常终端语义（阻塞读）。 */
    const int flags = fcntl(master, F_GETFL);
    if (flags < 0 || fcntl(master, F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(master, F_SETFD, FD_CLOEXEC) < 0) {
        const int saved = errno;
        close(master);
        close(slave);
        LOGE("configure pty master failed: errno=%d", saved);
        throw_io(env, "PTY master 配置失败（O_NONBLOCK/FD_CLOEXEC）");
        return nullptr;
    }
    /* slave 设 FD_CLOEXEC：dup2 到 0/1/2 会自动清掉，其它继承者不该拿着它。 */
    (void)fcntl(slave, F_SETFD, FD_CLOEXEC);

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)(columns > 0 ? columns : 80);
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    if (ioctl(master, TIOCSWINSZ, &ws) != 0) {
        LOGW("initial TIOCSWINSZ failed: errno=%d", errno); /* 非致命：resize 还能补 */
    }

    char **cargv = strings_array(env, argv);
    char **cenvp = strings_array(env, envp);
    const char *ccwd = nullptr;
    if (cwd != nullptr) ccwd = env->GetStringUTFChars(cwd, nullptr);

    /*
     * 参数构造失败必须在这里处理干净：fork 后的子进程拿不到 JVM 的 pending
     * exception，而带着 pending exception 返回 jintArray 属于未定义行为。
     */
    if (cargv == nullptr || cargv[0] == nullptr || (cwd != nullptr && ccwd == nullptr)) {
        close(master);
        close(slave);
        free_strings(cargv);
        free_strings(cenvp);
        if (ccwd != nullptr) env->ReleaseStringUTFChars(cwd, ccwd);
        if (!env->ExceptionCheck()) throw_io(env, "构造 exec 参数失败");
        return nullptr;
    }

    const pid_t pid = fork();
    if (pid < 0) {
        const int saved = errno;
        close(master);
        close(slave);
        free_strings(cargv);
        free_strings(cenvp);
        if (ccwd != nullptr) env->ReleaseStringUTFChars(cwd, ccwd);
        LOGE("fork failed: errno=%d", saved);
        throw_io(env, "fork 失败：无法创建沙箱子进程");
        return nullptr;
    }

    if (pid == 0) {
        /* ===== 子进程：只允许 async-signal-safe 调用 ===== */
        setsid();
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO) close(slave);
        if (master >= 0) close(master);
        /* stdio 已接管 slave；关掉全部继承 fd（见 close_from 注释）。 */
        close_from(STDERR_FILENO + 1);
        child_reset_signals();
        if (ccwd != nullptr && chdir(ccwd) != 0) {
            /* 工作目录不存在：报告后继续 exec，让 shell 也报一次，但不静默留在 "/"。 */
            child_report_failure("chdir failed", ccwd, errno);
        }
        execve(cargv[0], cargv, cenvp);
        child_report_failure("exec failed", cargv[0], errno);
        _exit(127);
    }

    /* ===== 父进程 ===== */
    close(slave);
    if (ccwd != nullptr) env->ReleaseStringUTFChars(cwd, ccwd);
    free_strings(cargv);
    free_strings(cenvp);

    const jint pair[2] = {(jint)master, (jint)pid};
    jintArray result = env->NewIntArray(2);
    if (result != nullptr) env->SetIntArrayRegion(result, 0, 2, pair);
    if (result == nullptr || env->ExceptionCheck()) {
        /* fork 之后分配失败：Java 侧拿不到任何句柄，只能在这里收拾干净。 */
        LOGE("NewIntArray failed after fork; reaping pid=%d", (int)pid);
        kill(-pid, SIGKILL);
        kill(pid, SIGKILL);
        close(master);
        while (waitpid(pid, nullptr, 0) < 0 && errno == EINTR) {
        }
        return nullptr;
    }
    return result;
}

/*
 * 从 master 读最多 buffer.length 字节。
 *   > 0  读到的字节数
 *   0    暂时没有数据（EAGAIN / 超时 / EINTR）
 *  -1    流结束（对端关闭 / EIO）或真错误（已挂 IOException）
 */
static jint pty_read(JNIEnv *env, jobject thiz, jint fd, jbyteArray buffer) {
    (void)thiz;
    if (buffer == nullptr) return -1;
    const jsize len = env->GetArrayLength(buffer);
    if (len <= 0) return 0;

    struct pollfd ready;
    ready.fd = (int)fd;
    ready.events = POLLIN;
    ready.revents = 0;
    const int polled = poll(&ready, 1, kPollTimeoutMs);
    if (polled == 0 || (polled < 0 && errno == EINTR)) return 0;
    if (polled < 0) {
        LOGE("pty read poll failed: errno=%d", errno);
        throw_io(env, "PTY 读轮询失败");
        return -1;
    }

    jbyte *tmp = (jbyte *)malloc((size_t)len);
    if (tmp == nullptr) {
        throw_io(env, "内存不足：PTY 读缓冲分配失败");
        return -1;
    }
    const ssize_t n = read((int)fd, tmp, (size_t)len);
    const int read_errno = errno;
    if (n > 0) env->SetByteArrayRegion(buffer, 0, (jsize)n, tmp);
    free(tmp);

    /* n==0 / EIO：PTY 对端已关闭且数据排空 —— 这是正常的流结束。 */
    if (n == 0 || (n < 0 && read_errno == EIO)) return -1;
    if (n < 0 && (read_errno == EAGAIN || read_errno == EINTR)) return 0;
    if (n < 0) {
        LOGE("pty read failed: errno=%d", read_errno);
        throw_io(env, "PTY 读失败");
        return -1;
    }
    return (jint)n;
}

/*
 * 向 master 写 [offset, offset+length)；返回实际写入字节数。
 *   0  暂时写不进去（EAGAIN / 超时）—— 调用方应让出后重试
 *  -1  非法参数或真错误
 */
static jint pty_write(JNIEnv *env, jobject thiz, jint fd, jbyteArray buffer, jint offset,
                      jint length) {
    (void)thiz;
    if (buffer == nullptr) return -1;
    if (length <= 0) return 0;
    const jsize buf_len = env->GetArrayLength(buffer);
    /* 显式边界校验：越界会让 GetByteArrayRegion 抛 ArrayIndexOutOfBounds，
     * 但调用方是按「写入失败」处理的，语义对不上。 */
    if (offset < 0 || offset > buf_len || length > buf_len - offset) return -1;

    struct pollfd ready;
    ready.fd = (int)fd;
    ready.events = POLLOUT;
    ready.revents = 0;
    const int polled = poll(&ready, 1, kPollTimeoutMs);
    if (polled == 0 || (polled < 0 && errno == EINTR)) return 0;
    if (polled < 0) {
        LOGE("pty write poll failed: errno=%d", errno);
        throw_io(env, "PTY 写轮询失败");
        return -1;
    }

    jbyte *tmp = (jbyte *)malloc((size_t)length);
    if (tmp == nullptr) {
        throw_io(env, "内存不足：PTY 写缓冲分配失败");
        return -1;
    }
    env->GetByteArrayRegion(buffer, offset, length, tmp);
    const ssize_t n = write((int)fd, tmp, (size_t)length);
    const int write_errno = errno;
    free(tmp);
    if (n < 0 && (write_errno == EAGAIN || write_errno == EINTR)) return 0;
    if (n < 0) {
        LOGE("pty write failed: errno=%d", write_errno);
        throw_io(env, "PTY 写失败");
        return -1;
    }
    return (jint)n;
}

/* TIOCSWINSZ；返回 0 成功，-1 失败。 */
static jint pty_resize(JNIEnv *env, jobject thiz, jint fd, jint columns, jint rows) {
    (void)env;
    (void)thiz;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)(columns > 0 ? columns : 80);
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    return ioctl((int)fd, TIOCSWINSZ, &ws) == 0 ? 0 : -1;
}

/*
 * 向 pid 所在的**进程组**发信号。
 *
 * 子进程调用过 setsid()，因此它的 pid 同时是 session/group id ⇒ kill(-pid)
 * 覆盖整棵前台进程树（超时/取消时正是要这个语义）。返回 0 成功，-1 失败。
 */
static jint pty_signal(JNIEnv *env, jobject thiz, jint pid, jint signal_number) {
    (void)env;
    (void)thiz;
    if (pid <= 0) return -1;
    if (kill(-pid, signal_number) == 0) return 0;
    /* 进程组已空（子进程已退出）时退回单 pid 尝试一次。 */
    return kill(pid, signal_number) == 0 ? 0 : -1;
}

/*
 * 非阻塞回收子进程，返回原始 wait status（见文件头常量）。
 *
 * 语义提醒：一旦返回了 status（真的回收了），再次用同一 pid 调用会返回
 * kWaitError（waitpid -> ECHILD）。Kotlin 侧必须缓存结果，绝不能在回收之后
 * 继续拿这个 pid 发信号 —— pid 可能已被内核复用给别的进程。
 */
static jlong pty_wait_no_hang(JNIEnv *env, jobject thiz, jint pid) {
    (void)thiz;
    if (pid <= 0) {
        throw_ise(env, "非法的 PTY 子进程 pid");
        return kWaitError;
    }
    int status = 0;
    pid_t reaped;
    do {
        reaped = waitpid((pid_t)pid, &status, WNOHANG);
    } while (reaped < 0 && errno == EINTR);

    if (reaped == 0) return kWaitRunning;
    if (reaped == (pid_t)pid) return (jlong)(uint32_t)status;
    /* ECHILD：已被回收，或本进程根本不是它的父进程。 */
    return kWaitError;
}

/* 关闭 master fd。fd < 0 时什么也不做。 */
static void pty_close_fd(JNIEnv *env, jobject thiz, jint fd) {
    (void)env;
    (void)thiz;
    if (fd >= 0) close((int)fd);
}

/* -------------------------------------------------------------------------*/
/* 注册表                                                                    */
/*                                                                          */
/* 签名串必须与 PtySession.kt 的 external fun 声明逐字一致。                  */
/* -------------------------------------------------------------------------*/

struct NativeMethod {
    const char *name;
    const char *signature;
    void *fn;
};

static const JNINativeMethod kMethods[] = {
    {"nativeOpenAndExec", "([Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;II)[I",
     (void *)pty_open_and_exec},
    {"nativeRead", "(I[B)I", (void *)pty_read},
    {"nativeWrite", "(I[BII)I", (void *)pty_write},
    {"nativeResize", "(III)I", (void *)pty_resize},
    {"nativeSignal", "(II)I", (void *)pty_signal},
    {"nativeWaitNoHang", "(I)J", (void *)pty_wait_no_hang},
    {"nativeCloseFd", "(I)V", (void *)pty_close_fd},
};

/*
 * 把 native 方法注册到 `<package>/PtySession$Companion`。
 *
 * 为什么是 Companion：这 7 个函数在 Kotlin 侧都是 companion object 的成员
 * （见 PtySession.kt）。`nativeOpenAndExec` 必须在没有实例时可用，所以只能放
 * companion；其它 6 个跟着放同一处，注册表就只有一张。
 *
 * 失败时返回 JNI_ERR：System.loadLibrary 会抛 UnsatisfiedLinkError，把
 * 「签名不一致」和「库没打进 AAR」两种原因都挡在加载期，而不是留到运行期
 * 第一次调用时再炸。
 */
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK || env == nullptr) {
        /* 没有 JNIEnv 就无法打 logcat（__android_log_print 不依赖 env，可以）。 */
        LOGE("JNI_OnLoad: GetEnv failed");
        return JNI_ERR;
    }

    const char *className = "com/heracles/sandbox/runtime/PtySession$Companion";
    jclass clazz = env->FindClass(className);
    if (clazz == nullptr) {
        env->ExceptionClear();
        LOGE("JNI_OnLoad: class not found: %s", className);
        return JNI_ERR;
    }
    const int count = (int)(sizeof(kMethods) / sizeof(kMethods[0]));
    const jint status = env->RegisterNatives(clazz, kMethods, count);
    env->DeleteLocalRef(clazz);
    if (status != JNI_OK) {
        env->ExceptionClear();
        LOGE("JNI_OnLoad: RegisterNatives failed (status=%d, %d methods)", (int)status, count);
        return JNI_ERR;
    }
    LOGI("libpty_bridge loaded: %d natives registered on %s", count, className);
    return JNI_VERSION_1_6;
}
