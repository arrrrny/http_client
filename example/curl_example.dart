import 'dart:async';
import 'package:http_client/curl.dart';

Future<void> main() async {
  // Create a CurlClient instance
  final client = CurlClient();

  // Send a GET request to example.com
  final response =
      await client.send(Request('GET', 'https://www.example.com/'));
  final textContent = await response.readAsString();

  print(textContent);

  // Close the client when done
  await client.close();
}
