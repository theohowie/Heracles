// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **项目类型识别（V0.4 T1-6，2026-11-02）** —— "任意代码项目"定位的落地。
//
// ## 为什么需要它
//
// 产品定位从"构建 APK"改成"完成任意代码项目"之后，最直接的落地就是：
// **先认出这是什么项目，再给出这个生态的构建/测试命令**。
// 靠提示词喊"别默认是 Android"不可靠（抗幻觉必须由架构保证），所以做成
// 纯函数：输入工作区清单文件名，输出项目类型 + 建议命令，可单测、可给 UI。
//
// ## 不编造原则
//
// 只根据**清单文件是否存在**判断；认不出 ⇒ `unknown`（建议命令为空），
// **绝不猜一个命令让模型去跑**。
library;

/// 项目类型（只增）。
enum ProjectKind {
  /// Node / JavaScript / TypeScript（`package.json`）。
  node,

  /// Python（`pyproject.toml` / `setup.py` / `requirements.txt`）。
  python,

  /// Go（`go.mod`）。
  go,

  /// Rust（`Cargo.toml`）。
  rust,

  /// Flutter / Dart（`pubspec.yaml`）。
  flutter,

  /// Android（`build.gradle(.kts)` / `AndroidManifest.xml`）。
  android,

  /// Java Maven（`pom.xml`）。
  maven,

  /// 认不出。
  unknown,
}

/// 识别结果（给 UI / 给模型的项目上下文）。
class ProjectDetection {
  const ProjectDetection({
    required this.kind,
    required this.manifest,
    required this.buildCommands,
    required this.testCommands,
    this.notes = const <String>[],
  });

  final ProjectKind kind;

  /// 命中的清单文件名（`unknown` 时为 null）。
  final String? manifest;

  /// 建议构建命令（空 = 不知道该跑什么，**不编造**）。
  final List<String> buildCommands;

  /// 建议测试命令。
  final List<String> testCommands;

  /// 补充说明（例如"Flutter 项目也可出 APK，但 APK 只是能力之一"）。
  final List<String> notes;

  String get label => switch (kind) {
        ProjectKind.node => 'Node/前端',
        ProjectKind.python => 'Python',
        ProjectKind.go => 'Go',
        ProjectKind.rust => 'Rust',
        ProjectKind.flutter => 'Flutter/Dart',
        ProjectKind.android => 'Android',
        ProjectKind.maven => 'Java (Maven)',
        ProjectKind.unknown => '未识别',
      };

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'label': label,
        'manifest': ?manifest,
        'buildCommands': buildCommands,
        'testCommands': testCommands,
        'notes': notes,
      };
}

/// **从工作区文件清单识别项目类型**（纯函数；输入 = 相对路径或文件名集合）。
///
/// 判断顺序：Flutter（`pubspec.yaml`）先于 Android（Gradle）—— 因为 Flutter 项目
/// 里也有 `android/build.gradle`，若先判 Android 会把 Flutter 项目认错。
ProjectDetection detectProject(Iterable<String> fileNames) {
  final names = <String>{};
  for (final raw in fileNames) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    // 只取 basename（输入可能是 `app/package.json` 这类路径）
    final parts = trimmed.split(RegExp(r'[\\/]'));
    names.add(parts.last);
  }

  if (names.contains('pubspec.yaml')) {
    return const ProjectDetection(
      kind: ProjectKind.flutter,
      manifest: 'pubspec.yaml',
      buildCommands: ['flutter build apk --debug', 'flutter build appbundle'],
      testCommands: ['flutter test'],
      notes: ['Flutter 项目：可构建 APK/AppBundle，但 APK 只是本产品能力之一'],
    );
  }
  if (names.contains('build.gradle') || names.contains('build.gradle.kts')) {
    return const ProjectDetection(
      kind: ProjectKind.android,
      manifest: 'build.gradle',
      buildCommands: ['./gradlew assembleDebug', './gradlew build'],
      testCommands: ['./gradlew test'],
    );
  }
  if (names.contains('pom.xml')) {
    return const ProjectDetection(
      kind: ProjectKind.maven,
      manifest: 'pom.xml',
      buildCommands: ['mvn package'],
      testCommands: ['mvn test'],
    );
  }
  if (names.contains('package.json')) {
    return const ProjectDetection(
      kind: ProjectKind.node,
      manifest: 'package.json',
      buildCommands: ['npm run build'],
      testCommands: ['npm test'],
      notes: ['具体命令以 package.json 的 scripts 为准'],
    );
  }
  if (names.contains('pyproject.toml') ||
      names.contains('setup.py') ||
      names.contains('requirements.txt')) {
    final manifest = names.contains('pyproject.toml')
        ? 'pyproject.toml'
        : (names.contains('setup.py') ? 'setup.py' : 'requirements.txt');
    return ProjectDetection(
      kind: ProjectKind.python,
      manifest: manifest,
      buildCommands: const ['python -m build'],
      testCommands: const ['pytest'],
    );
  }
  if (names.contains('go.mod')) {
    return const ProjectDetection(
      kind: ProjectKind.go,
      manifest: 'go.mod',
      buildCommands: ['go build ./...'],
      testCommands: ['go test ./...'],
    );
  }
  if (names.contains('Cargo.toml')) {
    return const ProjectDetection(
      kind: ProjectKind.rust,
      manifest: 'Cargo.toml',
      buildCommands: ['cargo build'],
      testCommands: ['cargo test'],
    );
  }
  return const ProjectDetection(
    kind: ProjectKind.unknown,
    manifest: null,
    buildCommands: [],
    testCommands: [],
    notes: ['没有发现已知的项目清单文件 ⇒ 不猜构建/测试命令；请先看目录结构或 README'],
  );
}
