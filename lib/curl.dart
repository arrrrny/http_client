import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'http_client.dart';
export 'http_client.dart';

/// SOCKS is a protocol used for proxies and curl supports it. curl supports
/// both SOCKS version 4 as well as version 5, and both versions come in two
/// flavors.
/// https://ec.haxx.se/usingcurl/usingcurl-proxies#socks-types
enum CurlSocksProxyType {
  /// SOCKS4 is for the version 4
  socks4,

  /// SOCKS4a is for the version 4 without resolving the host name locally
  socks4a,

  /// SOCKS5 is for the version 5
  socks5,

  /// SOCKS5-hostname is for the version 5 without resolving the host name
  /// locally
  socks5hostname,
}

/// Exception thrown when the curl process exits with a non-zero exit code.
class CurlException implements Exception {
  /// The curl exit code.
  final int exitCode;

  /// A human-readable description mapped from the exit code.
  final String reason;

  /// The raw stderr output from curl.
  final String stderr;

  /// Creates a [CurlException].
  CurlException(this.exitCode, this.reason, this.stderr);

  @override
  String toString() =>
      'CurlException(exitCode: $exitCode, reason: $reason, stderr: $stderr)';
}

/// Maps well-known curl exit codes to human-readable descriptions.
String _curlExitCodeReason(int exitCode) {
  // https://curl.se/libcurl/c/libcurl-errors.html
  const reasons = <int, String>{
    1: 'Unsupported protocol',
    2: 'Failed to initialize',
    3: 'URL malformed',
    5: 'Couldn\'t resolve proxy',
    6: 'Couldn\'t resolve host',
    7: 'Failed to connect to host',
    22: 'HTTP returned error',
    23: 'Write error',
    26: 'Read error',
    27: 'Out of memory',
    28: 'Operation timed out',
    33: 'Range error',
    35: 'SSL connect error',
    47: 'Too many redirects',
    51: 'Peer certificate verification failed',
    52: 'Server returned nothing',
    53: 'SSL crypto engine not found',
    54: 'SSL crypto engine set failed',
    55: 'Send error',
    56: 'Receive error',
    58: 'Local certificate problem',
    59: 'Couldn\'t use SSL cipher',
    60: 'SSL certificate problem',
    61: 'Unrecognized transfer encoding',
    63: 'Maximum file size exceeded',
    67: 'Login denied',
    77: 'SSL CA cert problem',
    78: 'Remote file not found',
    92: 'Stream error',
  };
  return reasons[exitCode] ?? 'Unknown curl error (exit code: $exitCode)';
}

/// HTTP Client in Linux/macOS environment, executing the `curl` binary.
///
/// Use it only if the required feature (e.g. SOCKS proxy) is not available in
/// `console.dart`'s `ConsoleClient`.
///
/// Features:
/// - Parses real HTTP status codes, reason phrases and response headers.
/// - Sends `--compressed` to enable transparent decompression.
/// - Avoids duplicating the `User-Agent` header.
/// - Supports binary request bodies via stdin piping.
/// - Maps curl exit codes to [CurlException].
/// - Tracks closed state.
class CurlClient implements Client {
  /// The `curl` executable path / name.
  final String executable;

  /// The default HTTP User-Agent string.
  ///
  /// Will only be applied if the request does not already contain a
  /// `User-Agent` header.
  final String? userAgent;

  /// SOCKS Proxy in `host:port` format.
  final String? socksHostPort;

  /// SOCKS Proxy type. Default is SOCKS5.
  final CurlSocksProxyType socksProxyType;

  /// Optional connection timeout. Passed as `--connect-timeout` to curl.
  final Duration? connectTimeout;

  /// Whether this client has been closed.
  bool _closed = false;

  /// HTTP Client in Linux/macOS environment, executing the `curl` binary.
  CurlClient({
    String? executable,
    this.userAgent,
    this.socksHostPort,
    this.socksProxyType = CurlSocksProxyType.socks5,
    this.connectTimeout,
  }) : executable = executable ?? 'curl';

  /// HTTP methods that SHOULD NOT carry a request body per RFC 7231.
  static const _methodsWithoutBody = {
    'GET',
    'HEAD',
    'DELETE',
    'CONNECT',
    'OPTIONS',
    'TRACE',
  };

  /// Returns `true` when [method] semantically supports a request body.
  bool methodSupportsBody(String method) =>
      !_methodsWithoutBody.contains(method.toUpperCase());

  @override
  Future<Response> send(Request request) async {
    if (_closed) {
      throw StateError('CurlClient has been closed.');
    }

    final method = request.method.toUpperCase();
    if (request.body != null && !methodSupportsBody(method)) {
      throw ArgumentError(
        'HTTP $method requests must not carry a body.',
      );
    }

    final args = <String>[
      // Silence the progress meter but still show errors.
      '-s',
      '-S',
      // Include response headers in the output so we can parse them.
      '-i',
      // Request compressed transfer and auto-decompress.
      '--compressed',
    ];

    // --- Follow redirects ------------------------------------------------
    if (request.followRedirects == null || request.followRedirects!) {
      args.add('-L');
    }
    if (request.maxRedirects != null) {
      args.addAll(['--max-redirs', request.maxRedirects.toString()]);
    }

    // --- User-Agent (only if not already set in request headers) ----------
    final hasUserAgentHeader = request.headers.keys.any(
      (k) => k.toLowerCase() == 'user-agent',
    );
    if (!hasUserAgentHeader && userAgent != null) {
      args.addAll(['-A', userAgent!]);
    }

    // --- SOCKS proxy -----------------------------------------------------
    if (socksHostPort != null) {
      switch (socksProxyType) {
        case CurlSocksProxyType.socks4:
          args.add('--socks4');
          break;
        case CurlSocksProxyType.socks4a:
          args.add('--socks4a');
          break;
        case CurlSocksProxyType.socks5:
          args.add('--socks5');
          break;
        case CurlSocksProxyType.socks5hostname:
          args.add('--socks5-hostname');
          break;
      }
      args.add(socksHostPort!);
    }

    // --- Method ----------------------------------------------------------
    args.addAll(['-X', method]);

    // --- Timeouts --------------------------------------------------------
    if (connectTimeout != null) {
      args.addAll([
        '--connect-timeout',
        connectTimeout!.inSeconds.clamp(1, 999999).toString(),
      ]);
    }
    if (request.timeout != null && request.timeout! > Duration.zero) {
      args.addAll([
        '--max-time',
        request.timeout!.inSeconds.clamp(1, 999999).toString(),
      ]);
    }

    // --- Headers ---------------------------------------------------------
    request.headers.toSimpleMap().forEach((key, value) {
      args.addAll(['-H', '$key: $value']);
    });

    // --- Body (binary-safe via stdin pipe) --------------------------------
    List<int>? bodyBytes;
    if (request.body != null) {
      if (request.body is! List<int>) {
        throw ArgumentError('Request body type must be List<int>.');
      }
      bodyBytes = request.body as List<int>;
      // Tell curl to read the body from stdin -- preserves binary data.
      args.addAll(['--data-binary', '@-']);
    }

    // --- URL (must be last) ----------------------------------------------
    args.add(request.uri.toString());

    // --- Execute ---------------------------------------------------------
    final process = await Process.start(executable, args);

    // If we have body bytes, write them to stdin and close it.
    if (bodyBytes != null) {
      process.stdin.add(bodyBytes);
      await process.stdin.close();
    } else {
      await process.stdin.close();
    }

    // Collect stdout and stderr concurrently.
    final stdoutFuture = _collectBytes(process.stdout);
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode;
    final rawOutput = await stdoutFuture;
    final stderrOutput = await stderrFuture;

    if (exitCode != 0) {
      throw CurlException(
        exitCode,
        _curlExitCodeReason(exitCode),
        stderrOutput.trim(),
      );
    }

    // --- Parse response (headers + body from `-i` output) ----------------
    return _parseResponse(rawOutput);
  }

  /// Collects all bytes from [stream] into a single list.
  Future<List<int>> _collectBytes(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Parses the raw output of `curl -i` into a [Response].
  ///
  /// The format is:
  /// ```
  /// HTTP/1.1 200 OK\r\n
  /// Content-Type: text/html\r\n
  /// \r\n
  /// <body bytes>
  /// ```
  ///
  /// When following redirects (`-L`), curl emits multiple HTTP response blocks.
  /// We parse the **last** one.
  Response _parseResponse(List<int> raw) {
    // We need to find the last status line + headers block.
    // Each block ends with \r\n\r\n (or potentially \n\n).
    // We look for the last occurrence of a HTTP status line.

    final rawStr = latin1.decode(raw);

    // Find the last HTTP status line.
    int lastStatusIndex = -1;
    int searchFrom = 0;
    while (true) {
      final idx = rawStr.indexOf(RegExp(r'HTTP/\S+ \d{3}'), searchFrom);
      if (idx == -1) break;
      lastStatusIndex = idx;
      searchFrom = idx + 1;
    }

    if (lastStatusIndex == -1) {
      // Couldn't parse headers — return a best-effort response.
      return Response(
        200,
        '',
        Headers(),
        Stream.fromIterable(<List<int>>[raw]),
      );
    }

    final remaining = rawStr.substring(lastStatusIndex);

    // Find the header/body separator.
    int separatorEnd;
    final crlfIdx = remaining.indexOf('\r\n\r\n');
    final lfIdx = remaining.indexOf('\n\n');

    if (crlfIdx != -1 && (lfIdx == -1 || crlfIdx <= lfIdx)) {
      separatorEnd = lastStatusIndex + crlfIdx + 4;
    } else if (lfIdx != -1) {
      separatorEnd = lastStatusIndex + lfIdx + 2;
    } else {
      // No separator found — treat the entire output as headers.
      separatorEnd = raw.length;
    }

    final headerSection = rawStr.substring(lastStatusIndex, separatorEnd);
    final bodyBytes = raw.sublist(separatorEnd);

    // Parse the status line.
    final lines = headerSection.split(RegExp(r'\r?\n'));
    int statusCode = 200;
    String reasonPhrase = '';
    if (lines.isNotEmpty) {
      final statusLine = lines.first;
      final match = RegExp(r'HTTP/\S+\s+(\d{3})\s*(.*)').firstMatch(statusLine);
      if (match != null) {
        statusCode = int.parse(match.group(1)!);
        reasonPhrase = match.group(2)?.trim() ?? '';
      }
    }

    // Parse response headers.
    final headers = Headers();
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;
      final colonIdx = line.indexOf(':');
      if (colonIdx == -1) continue;
      final key = line.substring(0, colonIdx).trim();
      final value = line.substring(colonIdx + 1).trim();
      if (key.isNotEmpty) {
        headers.add(key, value);
      }
    }

    return Response(
      statusCode,
      reasonPhrase,
      headers,
      Stream.fromIterable(<List<int>>[bodyBytes]),
    );
  }

  @override
  Future close({bool force = false}) async {
    _closed = true;
  }
}
