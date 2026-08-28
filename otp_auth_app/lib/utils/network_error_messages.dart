import 'dart:io';

import 'package:dio/dio.dart';

/// Turns transport failures into something a person can act on.
///
/// The old messages named the machinery -- DNS, proxies, TLS handshakes,
/// certificate trust -- which told a user nothing they could do about it. These
/// say what went wrong in ordinary words and then name the one or two things
/// that are actually worth checking.
class NetworkErrorMessages {
  const NetworkErrorMessages._();

  /// No route to the internet at all. A failed name lookup almost always means
  /// the device is offline rather than anything subtle about name servers.
  static const String offline =
      'No internet connection. This device could not get online, so BeatzLock '
      'could not reach the server. Turn Wi-Fi or mobile data back on, then try '
      'again.';

  /// The device is online but the server did not answer.
  static const String serverUnreachable =
      'Could not reach the BeatzLock server. Your device looks online, so the '
      'server may be busy or temporarily down. Try again in a moment.';

  static const String timedOut =
      'The server took too long to answer. Your connection may be slow or '
      'dropping out right now. Try again in a moment.';

  /// A TLS failure. On real devices this is nearly always a wrong clock, so
  /// that is the only thing the message asks the user to check.
  static const String secureConnectionFailed =
      'Could not open a secure connection to the server. This is almost always '
      'a wrong date or time on this device -- check that, then try again. On a '
      'work or school network, security software can also block it.';

  static const String serverError =
      'The server had a problem handling that request. Please try again in a '
      'moment.';

  static const String canceled = 'That request was cancelled.';

  /// Whether [error] is a name-lookup failure, which in practice means the
  /// device has no working internet connection.
  static bool isOfflineError(Object? rawError) {
    final text = rawError?.toString().toLowerCase() ?? '';
    return text.contains('failed host lookup') ||
        text.contains('no address associated with hostname') ||
        text.contains('nodename nor servname') ||
        text.contains('network is unreachable') ||
        text.contains('no route to host');
  }

  static bool _isCertificateError(Object? rawError) {
    final text = rawError?.toString().toLowerCase() ?? '';
    return text.contains('handshakeexception') || text.contains('certificate');
  }

  /// Timeout-shaped failures. Written as a set rather than a switch because
  /// dio adds values to DioExceptionType between releases, and an unrecognised
  /// one should fall through to the caller's own wording instead of being
  /// guessed at.
  static const Set<DioExceptionType> _timeoutTypes = {
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
  };

  /// A plain-language message for a non-dio failure that turns out to be a
  /// connectivity problem, or [fallback] when it is something else. Generic
  /// `catch (e)` blocks used to report "please try again" for a phone that was
  /// simply offline.
  static String forUnexpected(Object error, String fallback) {
    if (isOfflineError(error)) {
      return offline;
    }
    if (error is HandshakeException || _isCertificateError(error)) {
      return secureConnectionFailed;
    }
    // A socket failure that is not a name lookup -- refused, reset, timed out
    // -- means the device did get onto the network and the server did not
    // answer. Telling that user they have no internet would be wrong.
    if (error is SocketException) {
      return serverUnreachable;
    }
    return fallback;
  }

  /// A plain-language message for a transport-level [DioException], or null
  /// when the failure is about the response itself and the caller should use
  /// its own wording.
  static String? forTransport(DioException error) {
    final type = error.type;
    final rawError = error.error;

    if (_timeoutTypes.contains(type)) return timedOut;
    if (type == DioExceptionType.badCertificate) return secureConnectionFailed;
    if (type == DioExceptionType.cancel) return canceled;

    if (type == DioExceptionType.connectionError ||
        type == DioExceptionType.unknown) {
      if (isOfflineError(rawError)) return offline;
      if (_isCertificateError(rawError)) return secureConnectionFailed;
      // An "unknown" failure can be anything, including a bug in our own
      // decoding, so only a real connection error claims the server is down.
      return type == DioExceptionType.connectionError
          ? serverUnreachable
          : null;
    }

    return null;
  }
}
