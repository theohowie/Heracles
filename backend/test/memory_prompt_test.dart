/// **记忆注入渲染/选择门禁**（2026-10-29 三作用域重设计）。
///
/// ## 每个用例抓什么缺陷（设计稿 §五测试表 8 条）
///
/// | # | 用例 | 抓的缺陷 |
/// |---|---|---|
/// | ① | 三段顺序 global→workspace→session | 顺序错 ⇒ 易变段占前缀、缓存全废；优先级倒置 |
/// | ② | 空段不输出标题 | 空标题白占字节、破坏前缀缓存 |
/// | ③ | 6000 共享 / 4000 独立 + 边界 6000/6001 | 预算没真实现 / 两段算成了一本账 |
/// | ④ | 无关键词命中只按预算裁 | 旧的"无命中回落全量"把窗口灌爆 |
/// | ⑤ | 条目整条取舍不截断 | 从中间截断 ⇒ 模型读到半句约定 |
/// | ⑥ | 冲突尾注只出现一次且在末尾 | 重复尾注白占字节且互相矛盾 |
/// | ⑦ | 8K 窗口按 5% 缩预算 | `min(常量, 窗口×5%)` 只写在注释里没实现 |
/// | ⑧ | 过期条目不参与、也不算"未注入" | 过期内容仍被注入 / 过期被算成裁剪（误导） |
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 造一条记忆。
MemoryRecord rec(
  String text, {
  MemoryScope scope = MemoryScope.global,
  String source = MemoryRecord.sourceAgent,
  int createdAt = 0,
  int? expiresAt,
  String id = 'm1',
}) =>
    MemoryRecord(
      id: id,
      scope: scope,
      kind: 'other',
      text: text,
      source: source,
      createdAt: createdAt,
      expiresAt: expiresAt,
    );

/// 取渲染结果里某一段（段与段之间用空行分隔）。
String sectionOf(String rendered, String title) {
  final start = rendered.indexOf(title);
  if (start < 0) return '';
  final next = rendered.indexOf('\n\n', start);
  return next < 0 ? rendered.substring(start) : rendered.substring(start, next);
}

/// 段内条目行数（`- [来源] ...`）。
int entryLineCount(String section) =>
    '\n- '.allMatches('\n$section').length;

const int defaultWindow = 128000; // ContractModel.defaultWindowTokens

void main() {
  test('① 三段顺序 = global → workspace → session（session 最后 = 最高优先）', () {
    final ctx = MemoryContext(
      global: [rec('GLOBAL-ENTRY 项目构建', scope: MemoryScope.global)],
      workspace: [rec('WORKSPACE-ENTRY 项目构建', scope: MemoryScope.workspace)],
      session: [rec('SESSION-ENTRY 项目构建', scope: MemoryScope.session)],
    );

    final out = renderMemoryContext(
      ctx,
      task: '项目构建',
      windowTokens: defaultWindow,
    );

    // 常量顺序（改这里 = 改产品行为，测试必须跟着红）
    expect(memoryInjectionOrder, [
      MemoryScope.global,
      MemoryScope.workspace,
      MemoryScope.session,
    ]);

    final iGlobal = out.indexOf(globalMemorySectionTitle);
    final iWorkspace = out.indexOf(workspaceMemorySectionTitle);
    final iSession = out.indexOf(sessionMemorySectionTitle);
    expect(iGlobal, greaterThanOrEqualTo(0));
    expect(iWorkspace, greaterThan(iGlobal),
        reason: '★ 顺序错 ⇒ 会话段（最易变）挤到前面，前缀缓存每轮整条失效');
    expect(iSession, greaterThan(iWorkspace),
        reason: '★ session 必须是最后一段（最易变 ⇒ 尾部变化，缓存损失最小）');

    // 正文也按同一顺序（不只是标题）
    expect(out.indexOf('GLOBAL-ENTRY'), lessThan(out.indexOf('WORKSPACE-ENTRY')));
    expect(out.indexOf('WORKSPACE-ENTRY'), lessThan(out.indexOf('SESSION-ENTRY')));
  });

  test('② 空段不输出标题；全空/开关关/全空白 ⇒ 渲染为空串', () {
    // 只有 session 段有内容 ⇒ 不许出现 global / workspace 的空标题
    final onlySession = MemoryContext(
      session: [rec('只有会话记忆', scope: MemoryScope.session)],
    );
    final out = renderMemoryContext(
      onlySession,
      task: '会话',
      windowTokens: defaultWindow,
    );
    expect(out, contains(sessionMemorySectionTitle));
    expect(out, isNot(contains(globalMemorySectionTitle)),
        reason: '空段注入标题 = 白占前缀字节，还打断缓存');
    expect(out, isNot(contains(workspaceMemorySectionTitle)));

    // 三段都空 ⇒ 空串（调用方据此不注入）
    expect(
      renderMemoryContext(const MemoryContext(),
          task: '随便', windowTokens: defaultWindow),
      '',
    );

    // 全局开关关掉 ⇒ 只有 global 条目也不注入了（数据保留，但不进上下文）
    final globalOff = MemoryContext(
      global: [rec('全局条目')],
      globalEnabled: false,
    );
    expect(
      renderMemoryContext(globalOff, task: '全局', windowTokens: defaultWindow),
      '',
      reason: 'globalEnabled=false 时连空壳都不该出现',
    );

    // 正文全是空白 ⇒ 视为无效条目，不注入
    expect(
      renderMemoryContext(
        MemoryContext(global: [rec('   \n\t ')]),
        task: '',
        windowTokens: defaultWindow,
      ),
      '',
    );
  });

  test('③ 预算：global+workspace 共享 6000（global 先占），session 独立 4000', () {
    // ---- 先量出"段头 + 行前缀"的开销（不硬编码文案长度，改文案不会假红）----
    final probeTask = 'XX';
    final probe = renderMemoryContext(
      MemoryContext(global: [rec('X' * 10)]),
      task: probeTask,
      windowTokens: defaultWindow,
    );
    final overhead = sectionOf(probe, globalMemorySectionTitle).length - 10;
    expect(overhead, greaterThan(0));

    // 恰好 6000 ⇒ 放得下（边界内的最后一条）
    final exact = renderMemoryContext(
      MemoryContext(global: [rec('X' * (6000 - overhead))]),
      task: probeTask,
      windowTokens: defaultWindow,
    );
    expect(sectionOf(exact, globalMemorySectionTitle).length, 6000,
        reason: '共享预算 = 6000：正好用满必须放行');

    // 6001 ⇒ 整条放不下，而它又是唯一一条 ⇒ 一条都没注入 ⇒ 空串
    expect(
      renderMemoryContext(
        MemoryContext(global: [rec('X' * (6001 - overhead))]),
        task: probeTask,
        windowTokens: defaultWindow,
      ),
      '',
      reason: '超出 1 字符也必须整条放弃，绝不从中间截断',
    );

    // ---- global 先占：global 用掉几乎全部共享预算 ⇒ workspace 段整体放不下 ----
    final shared = renderMemoryContext(
      MemoryContext(
        global: [rec('X' * (6000 - overhead - 40))],
        workspace: [rec('WORKSPACE-TOO-LATE', scope: MemoryScope.workspace)],
      ),
      task: 'XX',
      windowTokens: defaultWindow,
    );
    expect(sectionOf(shared, globalMemorySectionTitle).length,
        lessThanOrEqualTo(6000));
    expect(shared, isNot(contains('WORKSPACE-TOO-LATE')),
        reason: '★ global 先占共享预算，workspace 只能吃剩余（不是各 6000）');
    expect(shared, isNot(contains(workspaceMemorySectionTitle)),
        reason: 'workspace 一条都没放进去 ⇒ 连段头都不输出');
    expect(shared, contains('另有 1 条未注入'),
        reason: '裁剪必须如实回报条数（不变量 I6）');

    // ---- session 独立 4000（不受 global/workspace 用掉多少影响）----
    final sessionProbe = renderMemoryContext(
      MemoryContext(session: [rec('S' * 10, scope: MemoryScope.session)]),
      task: 'SS',
      windowTokens: defaultWindow,
    );
    final sessionOverhead =
        sectionOf(sessionProbe, sessionMemorySectionTitle).length - 10;

    final sessionExact = renderMemoryContext(
      MemoryContext(
        // 全局段吃掉 6000、会话段仍要能独立用满 4000
        global: [rec('X' * (6000 - overhead))],
        session: [rec('S' * (4000 - sessionOverhead), scope: MemoryScope.session)],
      ),
      task: 'XX SS',
      windowTokens: defaultWindow,
    );
    expect(sectionOf(sessionExact, sessionMemorySectionTitle).length, 4000,
        reason: 'session 预算独立 4000：global 用满不影响它');
    expect(sectionOf(sessionExact, globalMemorySectionTitle).length, 6000);
  });

  test('④ 无关键词命中 ⇒ 只按预算裁剪，**绝不**回落全量（旧行为已删）', () {
    // 300 条各 200 字符；task 与任何条目都不匹配（旧实现在这里会全量返回）
    final entries = [
      for (var i = 0; i < 300; i++)
        rec(
          'NOPE$i ${'a' * 195} TAIL$i',
          source: MemoryRecord.sourceUser,
          createdAt: i,
          id: 'm$i',
        ),
    ];
    final ctx = MemoryContext(global: entries);

    final out = renderMemoryContext(
      ctx,
      task: 'zzz 完全无关',
      windowTokens: defaultWindow,
    );
    final section = sectionOf(out, globalMemorySectionTitle);

    // 全量返回会是 300 条 ≈ 60KB —— 这里必须远小于它
    expect(entries.map((e) => e.text).join().length, greaterThan(60000),
        reason: '夹具本身要够大，否则"没全量返回"证明不了什么');
    expect(section.length, lessThanOrEqualTo(6000),
        reason: '★ 必须按预算裁剪；旧实现"无命中 ⇒ 全量"会把它撑到 60KB');
    expect(entryLineCount(section), lessThanOrEqualTo(40),
        reason: '每 scope 最多 injectMaxEntriesPerScope 条');
    expect(out, contains('另有 '),
        reason: '裁掉多少必须如实说（不变量 I6）');
    // 更硬的证据：某条只出现在摘要/或干脆没出现，**全文绝不在**
    expect(section, isNot(contains('TAIL0')),
        reason: '★ 无命中时旧实现会把 TAIL0 的全文塞进来');

    // 同一条规则也要在公开选择函数里成立（宿主/UI 复用它做预估）
    final picked = selectForInjection(
      entries,
      'zzz 完全无关',
      budgetChars: 6000,
      maxEntries: 40,
    );
    expect(picked.length, lessThanOrEqualTo(40));
    expect(picked.length, lessThan(entries.length),
        reason: '★ 选择函数也不许"全量回落"');
  });

  test('⑤ 条目整条取舍：放不下的整条不注入（绝不从中间截断）', () {
    // 两条都命中关键词 ⇒ 全文注入；A 放得下、B 放不下
    final a = 'project ${'a' * 2890} TAILA';
    final b = 'project ${'b' * 5000} TAILB';
    final ctx = MemoryContext(
      global: [
        rec(a, createdAt: 2, id: 'a'), // 更新的在前
        rec(b, createdAt: 1, id: 'b'),
      ],
    );

    final out = renderMemoryContext(
      ctx,
      task: 'project',
      windowTokens: defaultWindow,
    );

    expect(out, contains('TAILA'), reason: 'A 整条放得下 ⇒ 全文在');
    expect(out, isNot(contains('TAILB')));
    // 关键：B 连**开头**都不许出现 —— 出现任何前缀都说明被截断了
    expect(out, isNot(contains('project bbbb')),
        reason: '★ 从中间截断会让模型读到半句约定，比没有更危险');
    expect(out, contains('另有 1 条未注入'));
  });

  test('⑥ 冲突尾注全篇只出现一次，且必须是最后一句话', () {
    final ctx = MemoryContext(
      global: [rec('全局条目', scope: MemoryScope.global)],
      workspace: [rec('工作区条目', scope: MemoryScope.workspace)],
      session: [rec('会话条目', scope: MemoryScope.session)],
    );
    final out = renderMemoryContext(
      ctx,
      task: '条目',
      windowTokens: defaultWindow,
    );

    expect(RegExp('以当前对话为准').allMatches(out).length, 1,
        reason: '冲突裁决重复出现 = 白占字节，且措辞漂移时互相矛盾');
    expect(RegExp('会话私有 > 工作区 > 全局').allMatches(out).length, 1,
        reason: '跨层优先级必须写明且只写一次');
    expect(RegExp('不用复述').allMatches(out).length, 1);
    expect(out.trimRight().endsWith(memoryConflictRule), isTrue,
        reason: '★ 尾注必须在最末（放中间会被后面的条目覆盖掉注意力）');
    // 三段都在尾注之前
    for (final title in [
      globalMemorySectionTitle,
      workspaceMemorySectionTitle,
      sessionMemorySectionTitle,
    ]) {
      expect(out.indexOf(title), lessThan(out.indexOf(memoryConflictRule)));
    }
  });

  test('⑦ 窗口自适应：8K 模型按 5% 缩预算（min 是真实现，不是注释）', () {
    // min(常量, floor(window × 5%)) 的两条分支都要钉住
    expect(injectBudgetChars(capChars: 6000, windowTokens: 128000), 6000,
        reason: '128000×5% = 6400 > 6000 ⇒ 常量生效');
    expect(injectBudgetChars(capChars: 6000, windowTokens: 8192), 409,
        reason: '8192×5% = 409 < 6000 ⇒ 窗口比例生效');
    expect(injectBudgetChars(capChars: 4000, windowTokens: 8192), 409);
    expect(injectBudgetChars(capChars: 4000, windowTokens: 128000), 4000);

    // 行为层：同三条约 300 字的条目，128K 三条都在、8K 只放得下一条
    final entries = [
      for (var i = 0; i < 3; i++)
        rec('project entry$i ${'x' * 290} TAIL$i', createdAt: i, id: 'm$i'),
    ];
    final wide = renderMemoryContext(
      MemoryContext(global: entries),
      task: 'project',
      windowTokens: 128000,
    );
    final narrow = renderMemoryContext(
      MemoryContext(global: entries),
      task: 'project',
      windowTokens: 8192,
    );

    expect(entryLineCount(sectionOf(wide, globalMemorySectionTitle)), 3);
    final narrowSection = sectionOf(narrow, globalMemorySectionTitle);
    expect(entryLineCount(narrowSection), 1,
        reason: '★ 8K 窗口只允许 409 字符 ⇒ 只能放 1 条；'
            '"只写在注释里的 min" 会在这里变红');
    expect(narrowSection.length, lessThanOrEqualTo(409),
        reason: '★ 小窗口下记忆不许把人设挤出窗口');
    expect(narrow, contains('另有 2 条未注入'));
  });

  test('⑧ 过期条目不参与注入，也不被算成"未注入"', () {
    const now = 1000;
    final ctx = MemoryContext(
      global: [
        rec('EXPIRED-MARKER 项目约定', expiresAt: now, id: 'old'), // == now ⇒ 到期
        rec('ALIVE-MARKER 项目约定', id: 'live'),
      ],
      nowMs: now,
    );

    final out = renderMemoryContext(
      ctx,
      task: '项目约定',
      windowTokens: defaultWindow,
    );

    expect(out, contains('ALIVE-MARKER'));
    expect(out, isNot(contains('EXPIRED-MARKER')),
        reason: '★ 过期条目必须过滤（旧实现读取时过滤，注入也必须）');
    expect(out, isNot(contains('另有')),
        reason: '过期不算"未注入"（它本就不该出现在任何清单里），'
            '否则用户会被"另有 1 条"误导去记忆页找一条过期条目');
    // 尾注仍然在（有注入就有格式承诺）
    expect(out.trimRight().endsWith(memoryConflictRule), isTrue);
  });
}
