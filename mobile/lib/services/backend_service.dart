/// Backend API service.
/// Sends receipt images to the backend for OCR + LLM parsing.
/// The backend handles all secrets (Cloud Vision key, LLM API key).

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import 'auth_service.dart';

class BackendService {
  static final BackendService instance = BackendService._();
  BackendService._();

  static const String _prefKeyBackendUrl = 'backend_url';

  Future<String> getBackendUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKeyBackendUrl) ?? AppConstants.defaultBackendUrl;
  }

  Future<void> setBackendUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyBackendUrl, url);
  }

  /// Send a receipt image to the backend for processing (OCR + LLM parse).
  /// Returns the parsed receipt data as a Map.
  ///
  /// Throws on network error or non-200 response.
  Future<Map<String, dynamic>> processReceipt({
    required String imagePath,
    required String receiptId,
    String locale = 'he-IL',
    String currencyDefault = '',
  }) async {
    final backendUrl = await getBackendUrl();
    final uri = Uri.parse('$backendUrl/processReceipt');

    final imageFile = File(imagePath);
    if (!await imageFile.exists()) {
      throw Exception('Image file not found: $imagePath');
    }

    // Get Google access token for backend authentication
    final accessToken = await AuthService.instance.getAccessToken();
    if (accessToken == null) {
      throw Exception('Not authenticated — please sign in first');
    }

    // Build multipart request
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $accessToken'
      ..fields['receipt_id'] = receiptId
      ..fields['locale_hint'] = locale
      ..fields['currency_default'] = currencyDefault
      ..fields['timezone'] = AppConstants.defaultTimezone
      ..files.add(
        await http.MultipartFile.fromPath(
          'image',
          imagePath,
          filename: '$receiptId.jpg',
        ),
      );

    debugPrint('Backend: sending receipt $receiptId to $uri');

    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        throw Exception('Backend request timed out');
      },
    );

    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception(
        'Backend returned ${response.statusCode}: ${response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    debugPrint('Backend: got response for $receiptId');
    return data;
  }

  /// Send raw image bytes to the backend for processing (OCR + LLM parse).
  /// Used to avoid temporary file churn in byte-oriented pipelines.
  Future<Map<String, dynamic>> processReceiptBytes({
    required Uint8List imageBytes,
    required String receiptId,
    String locale = 'he-IL',
    String currencyDefault = '',
  }) async {
    final backendUrl = await getBackendUrl();
    final uri = Uri.parse('$backendUrl/processReceipt');

    if (imageBytes.isEmpty) {
      throw Exception('Image bytes are empty');
    }

    // Get Google access token for backend authentication
    final accessToken = await AuthService.instance.getAccessToken();
    if (accessToken == null) {
      throw Exception('Not authenticated — please sign in first');
    }

    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $accessToken'
      ..fields['receipt_id'] = receiptId
      ..fields['locale_hint'] = locale
      ..fields['currency_default'] = currencyDefault
      ..fields['timezone'] = AppConstants.defaultTimezone
      ..files.add(
        http.MultipartFile.fromBytes(
          'image',
          imageBytes,
          filename: '$receiptId.jpg',
        ),
      );

    debugPrint('Backend: sending receipt bytes $receiptId to $uri');

    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        throw Exception('Backend request timed out');
      },
    );

    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception(
        'Backend returned ${response.statusCode}: ${response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    debugPrint('Backend: got response for byte request $receiptId');
    return data;
  }

  /// OCR-only: send an image and get back raw OCR text (no LLM).
  /// Used for PDF page-by-page OCR where text is merged before LLM.
  ///
  /// Tries the dedicated /ocrOnly endpoint first. If it isn't deployed yet
  /// (404/405), falls back to /processReceipt and extracts raw_ocr_text.
  Future<String> ocrOnly({
    required String imagePath,
    String locale = 'he-IL',
  }) async {
    final backendUrl = await getBackendUrl();
    final accessToken = await AuthService.instance.getAccessToken();
    if (accessToken == null) {
      throw Exception('Not authenticated — please sign in first');
    }

    // Try dedicated /ocrOnly endpoint
    try {
      final uri = Uri.parse('$backendUrl/ocrOnly');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $accessToken'
        ..fields['locale_hint'] = locale
        ..files.add(await http.MultipartFile.fromPath('image', imagePath));

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw Exception('OCR request timed out'),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return (data['ocr_text'] as String?) ?? '';
      }

      debugPrint(
        'ocrOnly: endpoint returned ${response.statusCode}, using fallback',
      );
    } catch (e) {
      debugPrint('ocrOnly: endpoint unavailable ($e), using fallback');
    }

    // Fallback: use /processReceipt and extract raw_ocr_text
    final result = await processReceipt(
      imagePath: imagePath,
      receiptId: 'ocr_${DateTime.now().millisecondsSinceEpoch}',
      locale: locale,
    );
    return (result['raw_ocr_text'] as String?) ?? '';
  }

  /// OCR-only with in-memory bytes to avoid temp file writes/reads.
  Future<String> ocrOnlyBytes({
    required Uint8List imageBytes,
    String locale = 'he-IL',
  }) async {
    final backendUrl = await getBackendUrl();
    final accessToken = await AuthService.instance.getAccessToken();
    if (accessToken == null) {
      throw Exception('Not authenticated — please sign in first');
    }

    // Try dedicated /ocrOnly endpoint
    try {
      final uri = Uri.parse('$backendUrl/ocrOnly');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $accessToken'
        ..fields['locale_hint'] = locale
        ..files.add(http.MultipartFile.fromBytes(
          'image',
          imageBytes,
          filename: 'ocr_${DateTime.now().millisecondsSinceEpoch}.jpg',
        ));

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw Exception('OCR request timed out'),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return (data['ocr_text'] as String?) ?? '';
      }

      debugPrint(
        'ocrOnlyBytes: endpoint returned ${response.statusCode}, using fallback',
      );
    } catch (e) {
      debugPrint('ocrOnlyBytes: endpoint unavailable ($e), using fallback');
    }

    // Fallback: use /processReceipt and extract raw_ocr_text
    final result = await processReceiptBytes(
      imageBytes: imageBytes,
      receiptId: 'ocr_${DateTime.now().millisecondsSinceEpoch}',
      locale: locale,
    );
    return (result['raw_ocr_text'] as String?) ?? '';
  }

  /// LLM-only: send raw OCR text and get back structured receipt JSON.
  /// Used after merging OCR text from multiple PDF pages.
  Future<Map<String, dynamic>> parseReceiptText({
    required String ocrText,
    required String receiptId,
    String locale = 'he-IL',
    String currencyDefault = '',
  }) async {
    final backendUrl = await getBackendUrl();
    final uri = Uri.parse('$backendUrl/parseReceipt');

    final accessToken = await AuthService.instance.getAccessToken();
    if (accessToken == null) {
      throw Exception('Not authenticated — please sign in first');
    }

    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $accessToken'
      ..fields['receipt_id'] = receiptId
      ..fields['ocr_text'] = ocrText
      ..fields['locale_hint'] = locale
      ..fields['currency_default'] = currencyDefault
      ..fields['timezone'] = AppConstants.defaultTimezone;

    debugPrint('Backend: sending merged OCR text for $receiptId to $uri');

    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw Exception('Parse request timed out'),
    );

    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception('Parse failed: ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    debugPrint('Backend: got parse response for $receiptId');
    return data;
  }

  /// Health check
  Future<bool> isHealthy() async {
    try {
      final backendUrl = await getBackendUrl();
      final response = await http.get(
        Uri.parse('$backendUrl/health'),
      ).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

