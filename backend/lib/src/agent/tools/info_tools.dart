/// **信息获取类工具** —— 抓网页、查设备状态。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../capability/capabilities.dart';
import '../../tools/tool_factory.dart';

/// 构建网络 / 设备工具。
List<Tool> buildInfoTools(ToolFactory f, Capabilities caps) {
  final web = caps.web;
  final health = caps.deviceHealth;

  return [
    // ---------------------------------------------------------------- 抓网页
    f.build(
      name: 'web_fetch',
      description: '抓取一个网页并返回可读文本（已去除 HTML 标签）。'
          '适合查文档、看 API 说明、读技术文章。'
          '只返回前若干字符，很长的页面会被截断并告知。',
      parameters: {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': '完整 URL，必须以 http:// 或 https:// 开头。',
          },
          'max_chars': {
            'type': 'integer',
            'description': '最多返回多少字符，默认 50000。',
            'default': 50000,
          },
        },
        'required': ['url'],
      },
      isAvailable: () => web != null,
      unavailableReason: '当前环境不支持联网抓取',
      run: (args) async {
        final url = requireString(args, 'url');
        // 基础校验放在工具层：明显不合法的输入不必浪费一次网络往返
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          return const CapabilityFailure(
            'URL 必须以 http:// 或 https:// 开头',
            isRetryable: true,
          );
        }
        final maxChars = optionalInt(args, 'max_chars') ?? 50000;
        return web!.fetch(url, maxChars: maxChars);
      },
    ),

    // ------------------------------------------------------------ 设备状态
    f.build(
      name: 'check_device_state',
      description: '查询设备当前电量、温度、是否在充电。'
          '执行长时间任务（如构建 APK）前建议先查一次 —— '
          '电量过低或温度过高时任务会被自动暂停，提前知道能避免白跑。',
      parameters: {
        'type': 'object',
        'properties': <String, dynamic>{},
        'required': <String>[],
      },
      isAvailable: () => health != null,
      unavailableReason: '当前环境不支持读取设备状态',
      run: (args) async {
        // `health` 是函数级局部变量（可空）；闭包里提升成非空局部，
        // 避免 `!` 与非空推断互相打架。
        final h = health;
        if (h == null) {
          return const CapabilityFailure('当前环境不支持读取设备状态');
        }
        final battery = await h.batteryPercent();
        final temp = await h.temperatureCelsius();
        final charging = await h.isCharging();

        final buf = StringBuffer('设备状态：\n');
        buf.writeln('- 电量：${battery == null ? "未知" : "$battery%"}'
            '${charging == true ? "（充电中）" : ""}');
        buf.writeln('- 温度：${temp == null ? "未知" : "${temp.toStringAsFixed(1)}°C"}');

        // 把熔断阈值如实告诉模型，它就能自己判断该不该开始长任务
        if (battery != null && battery < 20) {
          buf.writeln('\n⚠️ 电量低于 20%：长任务（构建/逆向）可能会被暂停。建议先充电。');
        }
        if (temp != null && temp > 43) {
          buf.writeln('\n⚠️ 温度高于 43°C：长任务会被熔断暂停。建议等设备降温。');
        }
        return CapabilitySuccess(buf.toString().trimRight());
      },
    ),
  ];
}
