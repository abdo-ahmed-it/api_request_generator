import '../logger/logger.dart';
import '../models/login_config.dart';
import '../sources/api_fetchers/config_storage.dart';
import 'login_service.dart';

/// Config key holding the most recently minted token.
///
/// Also the sync channel between the terminal wizard and the web UI: the web
/// server runs in its own isolate with a *copy* of the token, so a refresh on
/// one side can't mutate the other's memory. Both sides re-read this key, and
/// `ConfigStorage` hits the file on every get, so a refresh propagates at the
/// next request either way.
const String kLastTokenKey = 'wizard.last_token';

/// Owns the live auth token for one run and knows how to mint a new one.
///
/// Mutable by design: [token] changes in place when a 401 forces a re-login, so
/// every holder of the same session sees the new value without threading a
/// return value back up the call stack. That's what makes the refreshed token
/// survive into the wizard's next select→generate cycle.
class TokenSession {
  String? token;

  /// Not final: setup can be offered reactively the first time a 401 lands, and
  /// the resulting recipe has to take effect for the rest of the same run.
  LoginConfig? config;

  final String? baseUrl;
  final LoginService? _service;

  /// Swappable so per-request loggers (e.g. the web server's buffering logger)
  /// can capture re-login progress for that request's response.
  Logger _logger;

  /// Interactive fallbacks. Null in non-TTY contexts (the web server isolate,
  /// `--no-interactive`), which makes those paths fail fast instead of hanging
  /// on a stdin read that will never return.
  final Future<String?> Function()? promptForToken;
  final Future<String?> Function()? promptForOtp;

  /// Set once a refresh has definitively failed, or once a fresh token turned
  /// out not to fix the 401. Either way, stop trying for the rest of the run.
  bool _givenUp = false;

  /// De-dupes concurrent refreshes. Not reachable today (both generate loops
  /// are strictly sequential) but cheap insurance if they're ever parallelized.
  Future<bool>? _inFlight;

  /// True if any refresh succeeded during this run — surfaced to the web UI.
  bool refreshed = false;

  TokenSession({
    required this.token,
    required Logger logger,
    this.config,
    this.baseUrl,
    LoginService? service,
    this.promptForToken,
    this.promptForOtp,
  })  : _logger = logger,
        _service = service;

  /// Whether a 401 is worth reacting to at all.
  bool get canRefresh {
    if (_givenUp) return false;
    final hasLogin = _service != null && (config?.isValid ?? false);
    return hasLogin || promptForToken != null;
  }

  /// True once we've concluded auth can't be fixed this run.
  bool get gaveUp => _givenUp;

  /// Whether an automatic (non-interactive) login is configured.
  bool get hasLogin => _service != null && (config?.isValid ?? false);

  /// Attempts to obtain a new token. Returns true if [token] changed.
  ///
  /// Latches on failure — a second call after a failed login returns false
  /// without touching the network, so an N-endpoint run costs at most one
  /// failed login rather than N.
  /// [otpCode] supplies a code the stored config doesn't carry (e.g. typed into
  /// the web UI), overriding [LoginConfig.fixedOtpCode] for this attempt.
  Future<bool> refresh({required String reason, String? otpCode}) {
    if (_givenUp) return Future.value(false);
    return _inFlight ??=
        _refresh(reason, otpCode).whenComplete(() => _inFlight = null);
  }

  Future<bool> _refresh(String reason, String? otpCode) async {
    _logger.d('Token refresh triggered: $reason');

    if (hasLogin) {
      final otp = (otpCode != null && otpCode.isNotEmpty)
          ? (code: otpCode, blocked: false)
          : await _resolveOtpCode();
      if (otp.blocked) {
        _logger.e('✗ Re-login needs an OTP code but none is configured '
            'and there is no terminal to ask on.');
      } else {
        final result = await _service!.login(
          config!,
          baseUrl: baseUrl,
          otpCode: otp.code,
        );
        if (result.isSuccess) {
          _adopt(result.token!);
          _logger.i('✓ Re-authenticated — got a fresh token.');
          return true;
        }
        _logger.e('✗ Re-login failed: ${result.error}');
      }
    }

    // Automatic login unavailable or failed — ask a human, if there is one.
    if (promptForToken != null) {
      final pasted = await promptForToken!();
      if (pasted != null && pasted.isNotEmpty) {
        _adopt(pasted);
        _logger.i('✓ Using the token you pasted.');
        return true;
      }
    }

    _givenUp = true;
    return false;
  }

  /// Records that a request STILL failed auth after a successful refresh, which
  /// proves the 401 isn't token expiry. Disables further attempts this run.
  void markRefreshIneffective() => _givenUp = true;

  /// Adopts a login recipe configured mid-run, clearing the give-up latch so
  /// the newly-configured login actually gets its chance.
  void applyConfig(LoginConfig fresh) {
    config = fresh;
    _givenUp = false;
  }

  /// Redirects progress messages, so a request-scoped logger can collect them.
  void attachLogger(Logger logger) => _logger = logger;

  /// Resets the per-request "did a refresh happen" flag.
  void clearRefreshedFlag() => refreshed = false;

  /// Takes on a token obtained outside the login flow (pasted by hand) and
  /// publishes it so the other side of the isolate boundary picks it up.
  void adopt(String fresh) {
    token = fresh;
    refreshed = true;
    _givenUp = false; // a working token means auth is worth trying again
    try {
      ConfigStorage.set(kLastTokenKey, fresh);
    } catch (_) {/* best-effort — the in-memory token still works */}
  }

  void _adopt(String fresh) => adopt(fresh);

  /// Picks up a token refreshed by the *other* side of the isolate boundary.
  /// Returns true if [token] changed.
  bool syncFromConfig() {
    try {
      final stored = ConfigStorage.get(kLastTokenKey);
      if (stored != null && stored.isNotEmpty && stored != token) {
        token = stored;
        return true;
      }
    } catch (_) {/* best-effort */}
    return false;
  }

  Future<({String? code, bool blocked})> _resolveOtpCode() async {
    if (!config!.needsOtp) return (code: null, blocked: false);

    final fixed = config!.fixedOtpCode;
    if (fixed != null && fixed.isNotEmpty) return (code: fixed, blocked: false);

    if (promptForOtp != null) {
      final typed = await promptForOtp!();
      if (typed != null && typed.isNotEmpty) {
        return (code: typed, blocked: false);
      }
    }
    return (code: null, blocked: true);
  }

  /// Masks a token for display — enough to recognize, useless if leaked.
  static String mask(String? value) {
    if (value == null || value.isEmpty) return '';
    if (value.length <= 12) return '${value.substring(0, 2)}…';
    return '${value.substring(0, 4)}…${value.substring(value.length - 4)}';
  }
}
