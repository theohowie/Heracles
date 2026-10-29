/// 全屏看图（2026-10-29）—— 已发送的图片、输入框里待发送
/// 的图片附件，点开都是这一页：黑底、双指缩放/拖动、点任意
/// 处或右上 × 关闭。文件已被清掉时如实占位，不崩。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/cupertino_kit.dart';

/// 打开全屏看图。path = 本地文件绝对路径；name 仅用于
/// 文件不存在时的占位文案。
void showImageViewer(BuildContext context, String path, {String? name}) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => _ImageViewerPage(path: path, name: name),
      transitionsBuilder: (_, anim, _, child) =>
          FadeTransition(opacity: anim, child: child),
    ),
  );
}

class _ImageViewerPage extends StatelessWidget {
  const _ImageViewerPage({required this.path, this.name});

  final String path;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    final exists = file.existsSync();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: exists
                  ? InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Center(
                        child: Image.file(
                          file,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => _missing(context),
                        ),
                      ),
                    )
                  : _missing(context),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            right: 14,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(AppIcons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _missing(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.image, size: 44, color: Colors.white54),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              name == null || name!.isEmpty
                  ? '图片文件已不存在'
                  : '图片文件已不存在\n$name',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
