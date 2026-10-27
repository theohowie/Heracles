import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/data/open_source_licenses.dart';

void main() {
  test('开源许可数据完整：三组齐全、文本可解码非空', () {
    expect(kOssEntries.length, greaterThan(40));
    final groups = kOssEntries.map((e) => e.group).toSet();
    expect(groups, containsAll(<String>{'direct', 'second', 'platform'}));
    for (final e in kOssEntries) {
      expect(e.licenseText.trim(), isNotEmpty, reason: e.name);
      expect(e.licenseKind, isNotEmpty, reason: e.name);
    }
    // 关键项目必须在名单里
    final names = kOssEntries.map((e) => e.name).toSet();
    expect(names, containsAll(<String>{
      'dio', 'dart_agent_core', 'flutter_svg', 'Flutter', 'Shizuku API',
    }));
  });
}
