import 'dart:io';

import 'package:dio/dio.dart';







class NetworkErrorMessages {
  const NetworkErrorMessages._();



  static const String offline =
      'No internet connection. This device could not get online, so BeatzLock '
      'could not reach the server. Turn Wi-Fi or mobile data back on, then try '
      'again.';


  static const String serverUnreachable =
      'Could not reach the BeatzLock server. Your device looks online, so the '
      'server may be busy or temporarily down. Try again in a moment.';

  static const String timedOut =
      'The server took too long to answer. Your connection may be slow or '
      'dropping out right now. Try again in a moment.';



  static const String secureConnectionFailed =
      'Could not open a secure connection to the server. This is almost always '
      'a wrong date or time on this device -- check that, then try again. On a '
      'work or school network, security software can also block it.';

  static const String serverError =
      'The server had a problem handling that request. Please try again in a '
      'moment.';

  static const String canceled = 'That request was cancelled.';



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





  static const Set<DioExceptionType> _timeoutTypes = {
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
  };





  static String forUnexpected(Object error, String fallback) {
    if (isOfflineError(error)) {
      return offline;
    }
    if (error is HandshakeException || _isCertificateError(error)) {
      return secureConnectionFailed;
    }



    if (error is SocketException) {
      return serverUnreachable;
    }
    return fallback;
  }




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


      return type == DioExceptionType.connectionError
          ? serverUnreachable
          : null;
    }

    return null;
  }
}
