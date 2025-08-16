import 'package:flutter/services.dart';

class ShareHandler {
  static const MethodChannel _channel = MethodChannel('com.trapcosmos.cosmos_queue/share');
  
  static void init(Function(String url, String? text) onShare) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'handleShare') {
        final String? url = call.arguments['url'];
        final String? text = call.arguments['text'];
        if (url != null) {
          onShare(url, text);
        }
      }
    });
  }
  
  static Future<String?> getInitialShare() async {
    try {
      final result = await _channel.invokeMethod('getInitialShare');
      return result?['url'];
    } catch (e) {
      return null;
    }
  }
}
