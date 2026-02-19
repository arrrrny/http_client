import 'dart:async';
import 'dart:io' as io;

import 'http_client.dart';
import 'src/headers.dart' show wrapHeaders;

export 'http_client.dart';

/// Exception thrown when a [ConsoleClient] operation fails.
class ConsoleClientException implements Exception {
  /// A human-readable message describing what went wrong.
  final String message;

  /// The underlying cause, if available.
  final Object? cause;

  /// Creates a [ConsoleClientException].
  ConsoleClientException(this.message, [this.cause]);

  @override
  String toString() {
    if (cause != null) {
      return 'ConsoleClientException: $message (cause: $cause)';
    }
    return 'ConsoleClientException: $message';
  }
}

/// HTTP Client in console (server) environment.
///
/// Built on top of `dart:io` [io.HttpClient] with the following hardening:
/// - **Closed-state tracking**: Throws [StateError] if [send] is called after
///   [close].
/// - **Default headers**: Constructor-level headers are applied as defaults and
///   never override per-request headers.
/// - **Robust body handling**: Supports `List<int>`, [StreamFn],
///   `Stream<List<int>>`, and [io.File] bodies. Unknown body types throw
///   [ArgumentError].
/// - **Connection-timeout support** via `connectionTimeout`.
/// - **Retry-safe StreamFn bodies**: `StreamFn` bodies are resolved before
///   piping.
/// - **Proper Content-Length**: Automatically sets `Content-Length` for
///   fixed-length bodies unless already specified by the caller.
class ConsoleClient implements Client {
  final io.HttpClient _delegate;
  final Headers? _defaultHeaders;

  /// Whether this client has been closed.
  bool _closed = false;

  ConsoleClient._(this._delegate, this._defaultHeaders);

  /// HTTP Client in console (server) environment.
  ///
  /// Set [proxy] for a static HTTP proxy, or [proxyFn] for dynamic proxy
  /// resolution. The return format for both should be e.g.
  /// `"PROXY host:port; PROXY host2:port2; DIRECT"`.
  ///
  /// **Mutually exclusive**: Providing both [proxy] and [proxyFn] throws an
  /// [ArgumentError].
  factory ConsoleClient({
    /// A static proxy string.
    String? proxy,

    /// A function that returns a proxy string per [Uri].
    String Function(Uri uri)? proxyFn,

    /// Default headers applied to every request.
    ///
    /// Per-request headers always take precedence. Accepts [Headers] or
    /// `Map<String, dynamic>`.
    /* Headers | Map */
    dynamic headers,

    /// The idle timeout of non-active persistent (keep-alive) connections.
    Duration? idleTimeout,

    /// The maximum number of live connections to a single host.
    int? maxConnectionsPerHost,

    /// Whether the body of a response will be automatically uncompressed.
    bool? autoUncompress,

    /// The default value of the `User-Agent` header for all requests.
    ///
    /// Set to an empty string to disable setting the User-Agent header
    /// automatically.
    String? userAgent,

    /// Whether to silently ignore bad certificates.
    ///
    /// **Security warning**: Use this only on known servers with demo/expired
    /// SSL certs.
    bool? ignoreBadCertificates,

    /// The time limit for establishing a connection.
    Duration? connectionTimeout,
  }) {
    if (proxy != null && proxyFn != null) {
      throw ArgumentError(
        'Cannot specify both proxy and proxyFn — they are mutually exclusive.',
      );
    }

    ignoreBadCertificates ??= false;
    final delegate = io.HttpClient();

    if (proxy != null) {
      delegate.findProxy = (uri) => proxy;
    } else if (proxyFn != null) {
      delegate.findProxy = proxyFn;
    }
    if (idleTimeout != null) {
      delegate.idleTimeout = idleTimeout;
    }
    if (maxConnectionsPerHost != null) {
      delegate.maxConnectionsPerHost = maxConnectionsPerHost;
    }
    if (autoUncompress != null) {
      delegate.autoUncompress = autoUncompress;
    }
    if (userAgent != null) {
      delegate.userAgent = userAgent.isEmpty ? null : userAgent;
    }
    if (ignoreBadCertificates) {
      delegate.badCertificateCallback = (cert, host, port) => true;
    }
    if (connectionTimeout != null) {
      delegate.connectionTimeout = connectionTimeout;
    }
    return ConsoleClient._(delegate, wrapHeaders(headers, clone: true));
  }

  /// Whether this client has been closed.
  bool get isClosed => _closed;

  @override
  Future<Response> send(Request request) {
    if (_closed) {
      throw StateError(
        'ConsoleClient has been closed. Create a new instance to send '
        'requests.',
      );
    }

    if (request.timeout != null && request.timeout! > Duration.zero) {
      return _send(request).timeout(
        request.timeout!,
        onTimeout: () => throw TimeoutException(
          'Request to ${request.uri} timed out after ${request.timeout}.',
          request.timeout,
        ),
      );
    } else {
      return _send(request);
    }
  }

  Future<Response> _send(Request request) async {
    final io.HttpClientRequest rq;
    try {
      rq = await _delegate.openUrl(request.method, request.uri);
    } on io.SocketException catch (e) {
      throw ConsoleClientException(
        'Failed to open connection to ${request.uri}',
        e,
      );
    }

    // --- Apply headers (request headers first, then defaults) ---------------
    final appliedHeaders = <String>{};

    void applyHeader(Headers headers, String key) {
      final values = headers[key];
      if (values == null || values.isEmpty) return;
      final lowerKey = key.toLowerCase();
      appliedHeaders.add(lowerKey);
      if (values.length == 1) {
        rq.headers.set(key, values.single);
      } else {
        rq.headers.set(key, values);
      }
    }

    void applyContentLength(int length) {
      if (appliedHeaders.contains('content-length')) return;
      rq.headers.set('Content-Length', length.toString());
      appliedHeaders.add('content-length');
    }

    // Per-request headers always win.
    for (final key in request.headers.keys) {
      applyHeader(request.headers, key);
    }

    // Default headers are applied only when the key was NOT already set.
    if (_defaultHeaders != null) {
      for (final key in _defaultHeaders!.keys) {
        if (appliedHeaders.contains(key.toLowerCase())) continue;
        applyHeader(_defaultHeaders!, key);
      }
    }

    // --- Connection settings ------------------------------------------------
    if (request.persistentConnection != null) {
      rq.persistentConnection = request.persistentConnection!;
    }
    if (request.followRedirects != null) {
      rq.followRedirects = request.followRedirects!;
    }
    if (request.maxRedirects != null) {
      rq.maxRedirects = request.maxRedirects!;
    }

    // --- Send body ----------------------------------------------------------
    await _writeBody(rq, request.body, applyContentLength);

    // --- Read response ------------------------------------------------------
    final rs = await rq.done;

    final responseHeaders = Headers();
    rs.headers.forEach((String key, List<String> values) {
      responseHeaders.add(key, values);
    });

    return Response(
      rs.statusCode,
      rs.reasonPhrase,
      responseHeaders,
      rs,
      redirects: rs.redirects
          .map(
            (ri) => RedirectInfo(ri.statusCode, ri.method, ri.location),
          )
          .toList(),
      requestAddress: rq.connectionInfo?.remoteAddress.address,
      responseAddress: rs.connectionInfo?.remoteAddress.address,
    );
  }

  /// Writes [body] to the [request] and closes it.
  ///
  /// Automatically sets `Content-Length` for fixed-size bodies via
  /// [applyContentLength].
  Future<void> _writeBody(
    io.HttpClientRequest request,
    dynamic body,
    void Function(int length) applyContentLength,
  ) async {
    if (body == null) {
      await request.close();
      return;
    }

    if (body is List<int>) {
      applyContentLength(body.length);
      request.add(body);
      await request.close();
      return;
    }

    if (body is StreamFn) {
      final stream = await body();
      await stream.pipe(request);
      return;
    }

    if (body is Stream<List<int>>) {
      await body.pipe(request);
      return;
    }

    if (body is io.File) {
      if (!await body.exists()) {
        throw ArgumentError(
          'Request body file does not exist: ${body.path}',
        );
      }
      applyContentLength(await body.length());
      await body.openRead().cast<List<int>>().pipe(request);
      return;
    }

    throw ArgumentError(
      'Unsupported request body type: ${body.runtimeType}. '
      'Expected List<int>, StreamFn, Stream<List<int>>, or File.',
    );
  }

  @override
  Future close({bool force = false}) async {
    _closed = true;
    _delegate.close(force: force);
  }
}
