// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **项目类型识别测试（V0.4 T1-6）**。
//
// | # | 用例 | 抓的缺陷 |
// |---|---|---|
// | ① | 各生态清单 → 正确 kind + 命令 | 把 Python 项目当 Android（定位偏差） |
// | ② | Flutter 优先于 Android（有 pubspec.yaml 也有 build.gradle） | Flutter 项目被认成纯 Android |
// | ③ | 路径输入（`app/package.json`）取 basename | 路径前缀导致认不出 |
// | ④ | 认不出 ⇒ unknown 且**命令为空**（不编造） | 猜一个命令让模型去跑 |
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  test('① 各生态清单 → kind + 建议命令', () {
    final node = detectProject(['package.json', 'src/index.js']);
    expect(node.kind, ProjectKind.node);
    expect(node.manifest, 'package.json');
    expect(node.testCommands, contains('npm test'));

    final py = detectProject(['pyproject.toml']);
    expect(py.kind, ProjectKind.python);
    expect(py.testCommands, contains('pytest'));

    final go = detectProject(['go.mod', 'main.go']);
    expect(go.kind, ProjectKind.go);
    expect(go.buildCommands, contains('go build ./...'));

    final rust = detectProject(['Cargo.toml']);
    expect(rust.kind, ProjectKind.rust);
    expect(rust.testCommands, contains('cargo test'));

    final mvn = detectProject(['pom.xml']);
    expect(mvn.kind, ProjectKind.maven);
    expect(mvn.testCommands, contains('mvn test'));

    final android = detectProject(['build.gradle.kts', 'AndroidManifest.xml']);
    expect(android.kind, ProjectKind.android);
    expect(android.buildCommands.first, contains('gradlew'));
  });

  test('② Flutter 优先于 Android（pubspec.yaml 存在时）', () {
    final d = detectProject([
      'pubspec.yaml',
      'android/build.gradle',
      'android/app/build.gradle',
    ]);
    expect(d.kind, ProjectKind.flutter,
        reason: '★ Flutter 项目里也有 build.gradle；先判 Android 会认错生态');
    expect(d.notes.join(), contains('APK 只是本产品能力之一'));
  });

  test('③ 路径输入取 basename', () {
    expect(detectProject(['app/package.json']).kind, ProjectKind.node);
    expect(detectProject(['server/go.mod']).kind, ProjectKind.go);
    expect(detectProject([r'service\Cargo.toml']).kind, ProjectKind.rust);
  });

  test('④ 认不出 ⇒ unknown 且命令为空（绝不编造）', () {
    final d = detectProject(['README.md', 'src/main.txt']);
    expect(d.kind, ProjectKind.unknown);
    expect(d.buildCommands, isEmpty, reason: '★ 不知道项目类型就不许编命令');
    expect(d.testCommands, isEmpty);
    expect(d.notes.join(), contains('不猜'));
    expect(d.toJson()['kind'], 'unknown');
  });
}
