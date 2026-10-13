/// Stable exception names only. Provider-supplied class names can contain
/// arbitrary data, so unknown values never enter a diagnostic file.
String? canonicalDiagnosticType(Object? value) =>
    value is String &&
        const {
          'NoSuchMethodError',
          'NoSuchFieldError',
          'NoClassDefFoundError',
          'ClassNotFoundException',
          'ExceptionInInitializerError',
          'VerifyError',
          'UnsupportedClassVersionError',
          'UnsatisfiedLinkError',
          'AbstractMethodError',
          'IncompatibleClassChangeError',
          'LinkageError',
          'BrowserChallengeException',
          'IOException',
          'ConnectException',
          'UnknownHostException',
          'SSLHandshakeException',
          'SocketTimeoutException',
          'SocketException',
          'InterruptedIOException',
          'IllegalArgumentException',
          'IllegalStateException',
          'NullPointerException',
          'IndexOutOfBoundsException',
          'ArithmeticException',
          'SourceNotLoadedException',
          'SecurityException',
          'UnsupportedOperationException',
          'FirebaseException',
          'PlatformException',
          'TimeoutException',
          'FormatException',
          'MissingPluginException',
        }.contains(value)
    ? value
    : null;
