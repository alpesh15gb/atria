import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../../core/utils/whatsapp_links.dart';

/// A visible, user-operated linked WhatsApp Web session. No send automation.
class WhatsAppShareScreen extends StatefulWidget {
  const WhatsAppShareScreen({
    super.key,
    this.filePath,
    this.phone = '',
    this.message = '',
  });
  final String? filePath;
  final String phone, message;
  @override
  State<WhatsAppShareScreen> createState() => _WhatsAppShareState();
}

class _WhatsAppShareState extends State<WhatsAppShareScreen> {
  final _controller = WebviewController();
  static Future<void>? _environment;
  String? _error;
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!Platform.isWindows) {
      setState(() => _error = 'Use WhatsApp through your device share sheet.');
      return;
    }
    try {
      _environment ??= () async {
        final dir = await getApplicationSupportDirectory();
        await WebviewController.initializeEnvironment(
          userDataPath: p.join(dir.path, 'whatsapp-web-profile'),
        );
      }();
      await _environment;
      await _controller.initialize();
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _controller.loadUrl('https://web.whatsapp.com/');
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(
          () => _error =
              'WhatsApp Web could not start. Install Microsoft Edge WebView2 Runtime or use your browser. $e',
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _chat() async {
    final digits = WhatsAppLinks.normalize(widget.phone);
    final uri = Uri.https('web.whatsapp.com', '/send', {
      'phone': '91$digits',
      'text': widget.message,
    });
    await _controller.loadUrl(uri.toString());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('WhatsApp Web'),
      actions: [
        TextButton(
          onPressed: () => launchUrl(
            Uri.parse('https://web.whatsapp.com/'),
            mode: LaunchMode.externalApplication,
          ),
          child: const Text('Open in browser'),
        ),
        if (_controller.value.isInitialized)
          TextButton(
            onPressed: () => _controller.reload(),
            child: const Text('Reload'),
          ),
      ],
    ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Scan the QR code using WhatsApp → Linked devices. Choose the recipient, attach the PDF and press Send yourself. Use WhatsApp Settings → Log out on shared computers.',
              ),
              if (widget.filePath != null)
                SelectableText('PDF attachment: ${widget.filePath}'),
              Wrap(
                spacing: 8,
                children: [
                  if (widget.phone.isNotEmpty &&
                      _controller.value.isInitialized)
                    FilledButton(
                      onPressed: _chat,
                      child: const Text('Open customer chat'),
                    ),
                  if (widget.message.isNotEmpty)
                    OutlinedButton(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: widget.message),
                      ),
                      child: const Text('Copy message'),
                    ),
                  if (widget.filePath != null)
                    OutlinedButton(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: widget.filePath!),
                      ),
                      child: const Text('Copy PDF path'),
                    ),
                  if (widget.filePath != null)
                    OutlinedButton(
                      onPressed: () =>
                          OpenFilex.open(p.dirname(widget.filePath!)),
                      child: const Text('Show PDF folder'),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!))
              : _controller.value.isInitialized
              ? Webview(_controller)
              : const Center(child: CircularProgressIndicator()),
        ),
      ],
    ),
  );
}
