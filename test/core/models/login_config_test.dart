import 'dart:convert';

import 'package:api_to_dart/api_to_dart.dart';
import 'package:test/test.dart';

void main() {
  group('LoginStep', () {
    test('resolvedUrl leaves absolute URLs alone', () {
      const step = LoginStep(url: 'https://auth.example.com/login');
      expect(step.resolvedUrl('https://api.example.com'),
          'https://auth.example.com/login');
    });

    test('resolvedUrl joins a bare path onto the base URL', () {
      const step = LoginStep(url: '/auth/login');
      expect(step.resolvedUrl('https://api.example.com'),
          'https://api.example.com/auth/login');
    });

    test('resolvedUrl handles a missing leading slash', () {
      const step = LoginStep(url: 'auth/login');
      expect(step.resolvedUrl('https://api.example.com'),
          'https://api.example.com/auth/login');
    });

    test('resolvedUrl strips trailing slashes from the base URL', () {
      const step = LoginStep(url: '/login');
      expect(step.resolvedUrl('https://api.example.com//'),
          'https://api.example.com/login');
    });

    test('toBody encodes JSON bodies as rawJson', () {
      const step = LoginStep(
        url: '/login',
        fields: {'email': 'a@b.com', 'password': 'secret'},
      );
      final body = step.toBody();
      expect(body.contentType, BodyContentType.rawJson);
      expect(jsonDecode(body.rawBody!),
          {'email': 'a@b.com', 'password': 'secret'});
    });

    test('toBody encodes form bodies as urlEncoded fields, not a raw body', () {
      const step = LoginStep(
        url: '/login',
        fields: {'email': 'a@b.com'},
        bodyFormat: LoginBodyFormat.form,
      );
      final body = step.toBody();
      expect(body.contentType, BodyContentType.urlEncoded);
      expect(body.formFields, {'email': 'a@b.com'});
      expect(body.rawBody, isNull);
    });

    test('toBody injects the OTP code alongside the static fields', () {
      const step = LoginStep(
        url: '/verify',
        fields: {'phone': '0100'},
        otpField: 'code',
      );
      final decoded = jsonDecode(step.toBody(otpCode: '1111').rawBody!);
      expect(decoded, {'phone': '0100', 'code': '1111'});
    });

    test('toBody omits the OTP field when no code is supplied', () {
      const step = LoginStep(
        url: '/verify',
        fields: {'phone': '0100'},
        otpField: 'code',
      );
      expect(jsonDecode(step.toBody().rawBody!), {'phone': '0100'});
    });

    test('round-trips through JSON', () {
      const step = LoginStep(
        url: '/verify',
        method: HttpMethod.PUT,
        fields: {'phone': '0100'},
        bodyFormat: LoginBodyFormat.form,
        headers: {'X-App': 'test'},
        otpField: 'code',
      );
      final back = LoginStep.fromJson(step.toJson())!;
      expect(back.url, step.url);
      expect(back.method, HttpMethod.PUT);
      expect(back.fields, step.fields);
      expect(back.bodyFormat, LoginBodyFormat.form);
      expect(back.headers, step.headers);
      expect(back.otpField, 'code');
    });

    test('fromJson returns null without a URL', () {
      expect(LoginStep.fromJson({'method': 'POST'}), isNull);
    });
  });

  group('LoginConfig', () {
    const singleStep = LoginConfig(steps: [
      LoginStep(url: '/login', fields: {'email': 'a@b.com'}),
    ]);

    const otpFlow = LoginConfig(
      steps: [
        LoginStep(url: '/send-otp', fields: {'phone': '0100'}),
        LoginStep(url: '/verify', fields: {'phone': '0100'}, otpField: 'code'),
      ],
      fixedOtpCode: '1111',
    );

    test('single-step config round-trips', () {
      final back = LoginConfig.fromJson(singleStep.toJson())!;
      expect(back.steps, hasLength(1));
      expect(back.steps.first.url, '/login');
      expect(back.needsOtp, isFalse);
    });

    test('two-step OTP config round-trips preserving order and OTP data', () {
      final back = LoginConfig.fromJson(otpFlow.toJson())!;
      expect(back.steps, hasLength(2));
      expect(back.steps[0].url, '/send-otp');
      expect(back.steps[1].url, '/verify');
      expect(back.steps[1].otpField, 'code');
      expect(back.fixedOtpCode, '1111');
    });

    test('isUnattended is false for OTP without a fixed code', () {
      const noCode = LoginConfig(steps: [
        LoginStep(url: '/verify', otpField: 'code'),
      ]);
      expect(noCode.needsOtp, isTrue);
      expect(noCode.isUnattended, isFalse);
    });

    test('isUnattended is true for OTP with a fixed code', () {
      expect(otpFlow.isUnattended, isTrue);
    });

    test('isUnattended is true for a single-step login', () {
      expect(singleStep.isUnattended, isTrue);
    });

    test('isValid rejects an empty or oversized step list', () {
      expect(const LoginConfig(steps: []).isValid, isFalse);
      expect(
        const LoginConfig(steps: [
          LoginStep(url: '/a'),
          LoginStep(url: '/b'),
          LoginStep(url: '/c'),
        ]).isValid,
        isFalse,
      );
    });

    group('matchesLoginStep', () {
      test('matches the exact login path', () {
        expect(singleStep.matchesLoginStep('/login'), isTrue);
      });

      test('does NOT match a different endpoint that merely shares a suffix',
          () {
        // The regression this guards: a suffix match would treat a step at
        // /auth/login as covering a separate /login endpoint, silently
        // skipping its re-login.
        const nested = LoginConfig(steps: [LoginStep(url: '/auth/login')]);
        expect(nested.matchesLoginStep('/login'), isFalse);
        expect(nested.matchesLoginStep('/auth/login'), isTrue);
      });

      test('does not match on a shared trailing segment', () {
        const nested = LoginConfig(steps: [LoginStep(url: '/api/users/login')]);
        expect(nested.matchesLoginStep('/users/login'), isFalse);
      });

      test('compares the path of an absolute step URL', () {
        const absolute = LoginConfig(steps: [
          LoginStep(url: 'https://api.test/api/v1/auth/login'),
        ]);
        expect(absolute.matchesLoginStep('/login'), isFalse);
        expect(absolute.matchesLoginStep('/api/v1/auth/login'), isTrue);
      });

      test('normalizes leading and trailing slashes', () {
        const s = LoginConfig(steps: [LoginStep(url: 'auth/login/')]);
        expect(s.matchesLoginStep('/auth/login'), isTrue);
      });

      test('never matches an empty path', () {
        expect(singleStep.matchesLoginStep(''), isFalse);
        expect(singleStep.matchesLoginStep('/'), isFalse);
      });

      test('matches either step of an OTP flow', () {
        expect(otpFlow.matchesLoginStep('/send-otp'), isTrue);
        expect(otpFlow.matchesLoginStep('/verify'), isTrue);
        expect(otpFlow.matchesLoginStep('/profile'), isFalse);
      });
    });

    test('fromJson survives malformed input without throwing', () {
      expect(LoginConfig.fromJson({}), isNull);
      expect(LoginConfig.fromJson({'steps': 'not-a-list'}), isNull);
      expect(LoginConfig.fromJson({'steps': []}), isNull);
      expect(LoginConfig.fromJson({'steps': [<String, dynamic>{}]}), isNull);
    });
  });

  group('LoginConfigStore', () {
    test('namespaces the key by sanitized source name', () {
      expect(LoginConfigStore.keyFor('Apidog: My API'), 'login.Apidog_My_API');
      expect(LoginConfigStore.keyFor(''), 'login.default');
      expect(LoginConfigStore.keyFor('!!!'), 'login.default');
    });

    test('different sources get different keys', () {
      expect(
        LoginConfigStore.keyFor('Staging API'),
        isNot(LoginConfigStore.keyFor('Production API')),
      );
    });
  });
}
