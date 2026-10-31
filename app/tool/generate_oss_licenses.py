#!/usr/bin/env python3
"""生成「开源许可」页数据：app/lib/data/open_source_licenses.dart

口径（用户 2026-10-27 定）：
  · 直接依赖（app 与 backend 两个 pubspec 的 dependencies，不含 dev）
  · 上述依赖的依赖（递归深度上限 2 层）
  · 平台与原生侧（Flutter SDK、Gradle 依赖、图标资产）手工条目
许可文本逐字取自各包在 pub cache 中的 LICENSE 文件，不改写。
依赖升级后重跑本脚本即可刷新（手工条目文本在 MANUAL_SOURCES 里）。

用法： python3 tool/generate_oss_licenses.py [仓库根目录]
"""
import base64
import os
import sys

import yaml

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else
                       os.path.join(os.path.dirname(__file__), '..', '..'))
APP = os.path.join(ROOT, 'app')
PUB_CACHE = os.path.expanduser('~/.pub-cache/hosted/pub.dev')
MANUAL_DIR = os.path.expanduser('~/workspace/oss-manual')
FLUTTER_LICENSE = os.path.expanduser('~/workspace/flutter-sdk/LICENSE')
APACHE_CANONICAL = os.path.expanduser(
    '~/.pub-cache/hosted/pub.dev/clock-1.1.2/LICENSE')
OWN_PACKAGES = {'heracles', 'heracles_backend'}
SDK_PACKAGES = {'flutter', 'flutter_test', 'sky_engine', 'flutter_lints'}


def load_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f)


def direct_deps(pubspec_path):
    spec = load_yaml(pubspec_path) or {}
    deps = (spec.get('dependencies') or {})
    return {k for k in deps if k not in OWN_PACKAGES and k not in SDK_PACKAGES}


def lock_versions():
    lock = load_yaml(os.path.join(APP, 'pubspec.lock')) or {}
    out = {}
    for name, info in (lock.get('packages') or {}).items():
        out[name] = str(info.get('version', ''))
    return out


def cache_dir(name, version):
    d = os.path.join(PUB_CACHE, f'{name}-{version}')
    return d if os.path.isdir(d) else None


def package_deps(name, version):
    d = cache_dir(name, version)
    if not d:
        return set()
    spec_path = os.path.join(d, 'pubspec.yaml')
    if not os.path.exists(spec_path):
        return set()
    spec = load_yaml(spec_path) or {}
    deps = (spec.get('dependencies') or {})
    return {k for k in deps if k not in OWN_PACKAGES and k not in SDK_PACKAGES}


def license_text(name, version):
    d = cache_dir(name, version)
    if not d:
        # SDK 内置包（如 flutter_web_plugins）不在 pub cache 里，
        # 许可文件在 Flutter SDK 的 packages 目录下（同为 BSD）。
        sdk_pkg = os.path.expanduser(
            f'~/workspace/flutter-sdk/packages/{name}')
        if os.path.isdir(sdk_pkg):
            d = sdk_pkg
        else:
            return ''
    for cand in ('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'license',
                 'COPYING', 'LICENSE-MIT'):
        p = os.path.join(d, cand)
        if os.path.exists(p):
            with open(p, errors='replace') as f:
                return f.read().strip()
    # 子目录里的 LICENSE（如 licenses/）兜底取第一个
    for base, _dirs, files in os.walk(d):
        for fn in files:
            if fn.upper().startswith('LICENSE'):
                with open(os.path.join(base, fn), errors='replace') as f:
                    return f.read().strip()
    # SDK 内置包自身不带 LICENSE 文件 —— 其源码头注明适用 SDK 根
    # 目录的 LICENSE（BSD），按此兜底，不留空。
    if 'flutter-sdk' in d:
        return read_file(FLUTTER_LICENSE)
    return ''


def detect_kind(text):
    t = text.lower()
    if 'apache license' in t:
        return 'Apache-2.0'
    if 'mit license' in t or ('permission is hereby granted, free of charge' in t
                              and 'the software is provided' in t):
        return 'MIT'
    if 'mozilla public license' in t:
        return 'MPL-2.0'
    if 'cc0 1.0' in t or 'creativecommons.org/publicdomain' in t:
        return 'CC0-1.0'
    if 'redistribution and use in source and binary forms' in t:
        return 'BSD'
    if 'gnu general public license' in t:
        return 'GPL'
    if 'permission to use, copy, modify, and/or distribute this software' in t:
        return 'ISC'
    if 'unlicense' in t:
        return 'Unlicense'
    return '开源许可'


def read_file(path):
    with open(path, errors='replace') as f:
        return f.read().strip()


def main():
    versions = lock_versions()
    app_roots = direct_deps(os.path.join(APP, 'pubspec.yaml'))
    backend_roots = direct_deps(os.path.join(ROOT, 'backend', 'pubspec.yaml'))
    roots = app_roots | backend_roots

    level = {}
    origin = {}
    for name in roots:
        level[name] = 1
        tags = []
        if name in app_roots:
            tags.append('前端')
        if name in backend_roots:
            tags.append('后端')
        origin[name] = ' · '.join(tags)
    frontier = list(roots)
    for name in frontier:
        for dep in package_deps(name, versions.get(name, '')):
            if dep not in level:
                level[dep] = 2
                origin[dep] = '传递依赖'

    entries = []
    missing = []
    for name in sorted(level):
        text = license_text(name, versions.get(name, ''))
        if not text:
            missing.append(name)
        entries.append({
            'name': name,
            'version': versions.get(name, ''),
            'group': 'direct' if level[name] == 1 else 'second',
            'origin': origin[name],
            'kind': detect_kind(text) if text else '见包内说明',
            'note': '',
            'text': text,
        })

    # 项目本体（Heracles 自己的 GPL-3.0）—— 用户 2026-11-01 指出开源许可页
    # 只列了第三方依赖，漏了本项目的许可证。置顶，单独 group 'self'。
    entries.insert(0, dict(
        name='Heracles', version='', group='self', origin='本项目',
        kind='GPL-3.0', note='应用本体',
        text=read_file(os.path.join(ROOT, 'LICENSE'))))
    apache = read_file(APACHE_CANONICAL)
    manual = [
        dict(name='Flutter', version='', group='platform', origin='平台',
             kind='BSD-3-Clause', note='应用框架与运行时',
             text=read_file(FLUTTER_LICENSE)),
        dict(name='Shizuku API', version='13.1.5', group='platform',
             origin='原生', kind='MIT', note='设备提权通道（无线调试授权）',
             text=read_file(os.path.join(MANUAL_DIR, 'shizuku.txt'))),
        dict(name='Stellar-API', version='1.0.3', group='platform',
             origin='原生', kind='未附许可文件', note='设备提权通道（Stellar）',
             text='该项目的代码仓库未附独立的 LICENSE 文件，此处仅作致谢，'
                  '不转载许可文本。其接口与 Shizuku API 兼容。'),
        dict(name='kotlinx-coroutines', version='1.9.0', group='platform',
             origin='原生', kind='Apache-2.0', note='原生侧协程运行时',
             text=read_file(os.path.join(MANUAL_DIR, 'coroutines.txt'))),
        dict(name='AndroidX DocumentFile', version='1.0.1', group='platform',
             origin='原生', kind='Apache-2.0', note='SAF 目录文档访问',
             text=apache),
        dict(name='Lucide', version='', group='platform', origin='设计资产',
             kind='ISC', note='分支等图标的几何造型来源',
             text=read_file(os.path.join(MANUAL_DIR, 'lucide.txt'))),
        dict(name='Simple Icons', version='', group='platform',
             origin='设计资产', kind='CC0-1.0', note='GitHub 标记图标',
             text=read_file(os.path.join(MANUAL_DIR, 'simple-icons.txt'))),
    ]
    entries.extend(manual)

    def esc(s):
        return s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$')

    lines = [
        '// GENERATED —— 由 app/tool/generate_oss_licenses.py 生成，请勿手改。',
        '//',
        '// 口径：直接依赖 + 其依赖（深度上限 2）+ 平台/原生/资产手工条目；',
        '// 许可文本逐字取自各包 LICENSE 文件。依赖变更后重跑生成脚本。',
        "import 'dart:convert';",
        '',
        'class OssEntry {',
        '  const OssEntry({',
        '    required this.name,',
        '    required this.version,',
        '    required this.group,',
        '    required this.origin,',
        '    required this.licenseKind,',
        '    required this.note,',
        '    required this.textB64,',
        '  });',
        '',
        '  final String name;',
        '  final String version;',
        "  /// 'direct' 直接依赖 / 'second' 二层依赖 / 'platform' 平台与原生",
        '  final String group;',
        '  final String origin;',
        '  final String licenseKind;',
        '  final String note;',
        '  final String textB64;',
        '',
        '  String get licenseText => utf8.decode(base64Decode(textB64));',
        '}',
        '',
        'const List<OssEntry> kOssEntries = [',
    ]
    for e in entries:
        b64 = base64.b64encode(e['text'].encode()).decode()
        lines.append('  OssEntry(')
        lines.append(f"    name: '{esc(e['name'])}',")
        lines.append(f"    version: '{esc(e['version'])}',")
        lines.append(f"    group: '{e['group']}',")
        lines.append(f"    origin: '{esc(e['origin'])}',")
        lines.append(f"    licenseKind: '{esc(e['kind'])}',")
        lines.append(f"    note: '{esc(e['note'])}',")
        # base64 每 76 字符折行成相邻字符串，避免超长行
        chunks = [b64[i:i + 76] for i in range(0, len(b64), 76)] or ['']
        joined = "' '".join(chunks)
        lines.append(f"    textB64: '{joined}',")
        lines.append('  ),')
    lines.append('];')
    lines.append('')

    out_path = os.path.join(APP, 'lib', 'data', 'open_source_licenses.dart')
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, 'w') as f:
        f.write('\n'.join(lines))
    print(f'entries: {len(entries)} '
          f'(direct {sum(1 for e in entries if e["group"] == "direct")}, '
          f'second {sum(1 for e in entries if e["group"] == "second")}, '
          f'platform {sum(1 for e in entries if e["group"] == "platform")})')
    print('missing LICENSE:', ', '.join(missing) or 'none')
    print('wrote', out_path)


if __name__ == '__main__':
    main()
