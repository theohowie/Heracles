/// **GitHub Device Flow 协议测试**（2026-10-27，Step 3）。
///
/// ## 为什么这些测试特别值得写
///
/// Device Flow 的状态机有几个**在真机上极难复现**的分支：
///
/// · `slow_down`（轮询太快）—— 真机上要故意打快才触发，且会把
///   **全应用共享的 50 次/小时**配额烧掉；
/// · `expired_token`（15 分钟超时）—— 真机上要等 15 分钟；
/// · 网络抖动（某一次轮询抛异常）—— 随机出现。
///
/// 用注入的假 HTTP + 假时钟，这些都能毫秒级、确定性地验证。
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 假 GitHub：把一串预设响应按顺序吐出来，并记录收到的请求。
class _FakeGitHub {
  _FakeGitHub(this.script);

  /// 每次 post 依次返回的 Map（用完后重复最后一个）。
  final List<Map<String, dynamic>> script;

  final List<({String url, Map<String, String> body})> requests = [];
  int _i = 0;

  Future<Map<String, dynamic>> post(String url, Map<String, String> body) async {
    requests.add((url: url, body: body));
    final r = script[_i < script.length ? _i : script.length - 1];
    _i++;
    return r;
  }
}

void main() {
  /// 构造一个"设备码已拿到"的 info（大部分用例直接用它）。
  DeviceCodeInfo info({
    int expiresIn = 900,
    int interval = 5,
  }) =>
      DeviceCodeInfo(
        deviceCode: 'dev-code-123',
        userCode: 'WDJB-MJHT',
        verificationUri: 'https://github.com/login/device',
        expiresIn: expiresIn,
        interval: interval,
      );

  group('第 1 步：requestCode', () {
    test('★ 正常返回 ⇒ DeviceCodeInfo 四件套齐', () async {
      final gh = _FakeGitHub([
        {
          'device_code': 'dc-1',
          'user_code': 'ABCD-1234',
          'verification_uri': 'https://github.com/login/device',
          'expires_in': 900,
          'interval': 5,
        }
      ]);
      final flow = GitHubDeviceFlow(clientId: 'Ov23liTEST', post: gh.post);

      final r = await flow.requestCode(scopes: 'repo read:user');
      expect(r, isA<DeviceCodeInfo>());
      final d = r as DeviceCodeInfo;
      expect(d.deviceCode, 'dc-1');
      expect(d.userCode, 'ABCD-1234', reason: '★ 这是要给用户输入的 8 位码');
      expect(d.verificationUri, 'https://github.com/login/device');
      expect(d.expiresIn, 900);
      expect(d.interval, 5);
    });

    test('★ 请求带上 client_id 与 scope（不带的后果是 400）', () async {
      final gh = _FakeGitHub([
        {
          'device_code': 'dc',
          'user_code': 'A-B',
          'verification_uri': 'u',
        }
      ]);
      final flow = GitHubDeviceFlow(clientId: 'Ov23liX', post: gh.post);
      await flow.requestCode(scopes: 'public_repo read:user');

      final req = gh.requests.single;
      expect(req.url, 'https://github.com/login/device/code');
      expect(req.body['client_id'], 'Ov23liX');
      expect(req.body['scope'], 'public_repo read:user');
      expect(req.body.containsKey('client_secret'), isFalse,
          reason: '★★ Device Flow 绝不能带 client_secret —— 那正是选它的理由');
    });

    test('★ GitHub 回 error ⇒ 转成人话失败（不抛）', () async {
      final gh = _FakeGitHub([
        {'error': 'unauthorized_client', 'error_description': 'Client not enabled'}
      ]);
      final flow = GitHubDeviceFlow(clientId: 'x', post: gh.post, sleep: (_) async {});
      final r = await flow.requestCode();
      expect(r, isA<GitHubAuthFailure>());
      expect((r as GitHubAuthFailure).reason, contains('Client not enabled'));
    });

    test('★ 返回字段不全 ⇒ 明确失败，不带着 null 往下走', () async {
      final gh = _FakeGitHub([
        {'device_code': 'dc'} // 缺 user_code / verification_uri
      ]);
      final flow = GitHubDeviceFlow(clientId: 'x', post: gh.post, sleep: (_) async {});
      final r = await flow.requestCode();
      expect(r, isA<GitHubAuthFailure>());
      expect((r as GitHubAuthFailure).reason, contains('不完整'));
    });

    test('★ 网络异常 ⇒ 转成人话失败', () async {
      final flow = GitHubDeviceFlow(
        clientId: 'x',
        post: (_, __) async => throw Exception('连接超时'),
      );
      final r = await flow.requestCode();
      expect(r, isA<GitHubAuthFailure>());
      expect((r as GitHubAuthFailure).reason, contains('连接超时'));
    });
  });

  group('第 3 步：poll 状态机', () {
    test('★ 一次 pending 后成功 ⇒ 拿到 token + scope', () async {
      final gh = _FakeGitHub([
        {'error': 'authorization_pending'},
        {
          'access_token': 'gho_TOKEN',
          'token_type': 'bearer',
          'scope': 'repo read:user',
        },
      ]);
      final flow = GitHubDeviceFlow(clientId: 'x', post: gh.post, sleep: (_) async {});
      final r = await flow.poll(info());

      expect(r, isA<GitHubAuthSuccess>());
      final s = r as GitHubAuthSuccess;
      expect(s.accessToken, 'gho_TOKEN');
      expect(s.scopes, 'repo read:user');
      expect(gh.requests, hasLength(2), reason: 'pending 一次 + 成功一次');
    });

    test('★★ slow_down ⇒ interval +5 秒（不照做会烧光全应用配额）', () async {
      final sleeps = <Duration>[];
      final gh = _FakeGitHub([
        {'error': 'slow_down'},
        {'error': 'authorization_pending'},
        {'access_token': 'gho_T'},
      ]);
      final flow = GitHubDeviceFlow(
        clientId: 'x',
        post: gh.post,
        sleep: (d) async => sleeps.add(d),
      );
      await flow.poll(info(interval: 5));

      // 第 1 次等 5s；收到 slow_down 后 interval=10；第 2 次等 10s；
      // 再 pending；第 3 次还是 10s
      expect(sleeps.map((d) => d.inSeconds), [5, 10, 10],
          reason: '★ 文档：slow_down adds 5 seconds to the last interval');
    });

    test('★ 用户拒绝（access_denied）⇒ 终止 + 可重试（可能点错了）', () async {
      final gh = _FakeGitHub([
        {'error': 'access_denied'},
      ]);
      final flow = GitHubDeviceFlow(clientId: 'x', post: gh.post, sleep: (_) async {});
      final r = await flow.poll(info());

      expect(r, isA<GitHubAuthFailure>());
      final f = r as GitHubAuthFailure;
      expect(f.reason, contains('拒绝'));
      expect(f.isRetryable, isTrue, reason: '用户可能只是点错了，允许重来');
      expect(gh.requests, hasLength(1), reason: '★ 拒绝后不该继续轮询');
    });

    test('★ 过期（expired_token）⇒ 终止 + 可重试（重新取码）', () async {
      final gh = _FakeGitHub([
        {'error': 'expired_token'},
      ]);
      final flow = GitHubDeviceFlow(clientId: 'x', post: gh.post, sleep: (_) async {});
      final r = await flow.poll(info());

      expect(r, isA<GitHubAuthFailure>());
      final f = r as GitHubAuthFailure;
      expect(f.reason, contains('过期'));
      expect(f.isRetryable, isTrue);
    });

    test('★★ 到达 expires_in 就停（不在客户端无脑轮询）', () async {
      // 用假时钟：每次 sleep 就把时间往前推
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final gh = _FakeGitHub([
        {'error': 'authorization_pending'},
      ]);
      final flow = GitHubDeviceFlow(
        clientId: 'x',
        post: gh.post,
        clock: () => fakeNow,
        sleep: (d) async => fakeNow = fakeNow.add(d),
      );

      final r = await flow.poll(info(expiresIn: 20, interval: 5));
      expect(r, isA<GitHubAuthFailure>());
      expect((r as GitHubAuthFailure).reason, contains('超时'));
      // 20s / 5s ≈ 4 次左右就停，不会无限轮
      expect(gh.requests.length, lessThanOrEqualTo(5),
          reason: '★ 到点必须停 —— 否则会一直打 GitHub');
    });

    test('★ 未知 error ⇒ 终止且不可重试（别瞎重试）', () async {
      final gh = _FakeGitHub([
        {'error': 'something_new_github_added'},
      ]);
      final flow = GitHubDeviceFlow(clientId: 'x', post: gh.post, sleep: (_) async {});
      final r = await flow.poll(info());

      expect(r, isA<GitHubAuthFailure>());
      final f = r as GitHubAuthFailure;
      expect(f.isRetryable, isFalse,
          reason: '不认识的状态不该让 UI 引导用户反复重试');
      expect(f.reason, contains('something_new_github_added'));
    });

    test('★ 网络抖动（轮询抛异常）⇒ 继续等，不当作失败', () async {
      var calls = 0;
      final flow = GitHubDeviceFlow(
        clientId: 'x',
        post: (_, __) async {
          calls++;
          if (calls == 1) throw Exception('网络抖了一下');
          return {'access_token': 'gho_T'};
        },
        sleep: (_) async {},
      );
      final r = await flow.poll(info());

      expect(r, isA<GitHubAuthSuccess>(),
          reason: '★ 一次网络抖动不该让整个授权失败');
      expect(calls, 2);
    });

    test('★ 轮询请求的 grant_type 必须是 device_code 那个 URN', () async {
      final gh = _FakeGitHub([
        {'access_token': 'gho_T'},
      ]);
      final flow = GitHubDeviceFlow(clientId: 'x', post: gh.post, sleep: (_) async {});
      await flow.poll(info());

      final req = gh.requests.single;
      expect(req.url, 'https://github.com/login/oauth/access_token');
      expect(req.body['client_id'], 'x');
      expect(req.body['device_code'], 'dev-code-123');
      expect(req.body['grant_type'],
          'urn:ietf:params:oauth:grant-type:device_code');
      expect(req.body.containsKey('client_secret'), isFalse,
          reason: '★★ 换 token 也不能带 client_secret');
    });
  });

  group('协议工具函数', () {
    test('★ encodeFormBody 会做 URL 编码（中文/特殊字符不崩）', () {
      final body = encodeFormBody({
        'client_id': 'Ov23li',
        'scope': 'repo read:user',
        'note': '中文 & 符号',
      });
      // form-urlencoded 规范：空格编码成 `+`（不是 %20）。`Uri.encodeQueryComponent` 行为正确。
      expect(body, contains('scope=repo+read%3Auser'));
      expect(body, contains('%26'), reason: '& 必须编码，否则会被拆成新参数');
    });

    test('★ decodeGitHubResponse 认得 JSON', () {
      final m = decodeGitHubResponse('{"access_token":"gho_X"}');
      expect(m['access_token'], 'gho_X');
    });

    test('★ decodeGitHubResponse 也认得 form-urlencoded（缺 Accept 头时的兜底）', () {
      final m = decodeGitHubResponse(
          'access_token=gho_X&token_type=bearer&scope=repo%2Cgist');
      expect(m['access_token'], 'gho_X');
      expect(m['scope'], 'repo,gist');
    });

    test('★ encode → decode 往返一致', () {
      final original = {
        'client_id': 'Ov23liABC',
        'scope': 'repo read:user',
      };
      final m = decodeGitHubResponse(encodeFormBody(original));
      expect(m['client_id'], 'Ov23liABC');
      expect(m['scope'], 'repo read:user');
    });
  });
}
