// Memory browser screen — read the agent's memory entries.
//
// Hermes stores built-in memory as text files under ~/.hermes/memories/
// (USER.md for the user profile, MEMORY.md for cross-session facts), with
// entries separated by '§' lines. They are fetched through the dashboard's
// managed-files API (GET /api/files/read). Older Hermes versions kept a
// list of {target, content} entries in config.yaml, so /api/memory and
// /api/config remain as fallbacks.
import 'dart:convert';

import 'package:flutter/material.dart';
import '../services/connection_manager.dart';
import '../theme.dart';
import '../widgets/aurora.dart';
import '../widgets/glass.dart';
import '../widgets/status_view.dart';

class MemoryScreen extends StatefulWidget {
  final SavedConnection connection;

  /// When true the screen is rendered inside the split-view detail pane, so
  /// it must not show a back button.
  final bool embedded;

  const MemoryScreen({
    required this.connection,
    this.embedded = false,
    super.key,
  });

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  late DashboardClient _client;
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  String? _error;
  String? _source; // 'config' or 'api'

  @override
  void initState() {
    super.initState();
    _client = DashboardClient(
      host: widget.connection.host,
      port: widget.connection.dashboardPort,
      pathPrefix: widget.connection.dashboardPrefix ?? "",
      proxied: widget.connection.dashboardProxied,
      useHttps: widget.connection.useHttps,
      username: widget.connection.dashboardUsername,
      password: widget.connection.dashboardPassword,
    );
    _loadMemory();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  /// Reads one built-in memory file via the managed-files API and returns
  /// its '§'-separated entries, or an empty list if unavailable.
  Future<List<Map<String, dynamic>>> _readMemoryFile(
    String fileName,
    String target,
  ) async {
    try {
      final path = Uri.encodeComponent('~/.hermes/memories/$fileName');
      final res = await _client.apiGet('files/read?path=$path');
      final dataUrl = res['data_url'] as String? ?? '';
      final comma = dataUrl.indexOf(',');
      if (comma < 0) return [];
      final text = utf8.decode(base64Decode(dataUrl.substring(comma + 1)));
      return text
          .split(RegExp(r'\n?§\n?'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .map((e) => {'target': target, 'content': e})
          .toList();
    } catch (_) {
      // File missing / endpoint unavailable — treat as no entries.
      return [];
    }
  }

  Future<void> _loadMemory() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Primary: the built-in memory files (user profile + long-term facts).
      final fileEntries = [
        ...await _readMemoryFile('USER.md', 'user'),
        ...await _readMemoryFile('MEMORY.md', 'memory'),
      ];
      if (fileEntries.isNotEmpty) {
        setState(() {
          _entries = fileEntries;
          _source = 'files';
          _loading = false;
        });
        return;
      }

      // Fallback: dedicated /api/memory entry list (if the server has one).
      try {
        final memData = await _client.apiGet('memory');
        final items =
            memData['entries'] as List? ?? memData['memory'] as List? ?? [];
        if (items.isNotEmpty && items.first is Map) {
          setState(() {
            _entries = items.cast<Map<String, dynamic>>();
            _source = 'api';
            _loading = false;
          });
          return;
        }
      } catch (_) {
        // Endpoint not available — fall through to config
      }

      // Fallback: older Hermes kept memory as a list of {target, content}
      // in config.yaml. (A map under 'memory' is provider *settings*, not
      // content, so it is deliberately not rendered here.)
      final config = await _client.apiGet('config');
      final mem = config['memory'];
      setState(() {
        _entries = mem is List ? mem.cast<Map<String, dynamic>>() : [];
        _source = 'config';
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      intensity: 0.7,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Memory'),
            if (_source != null)
              Text(
                'Source: $_source',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          FaintIconButton(
            icon: Icons.refresh,
            tooltip: 'Refresh',
            onPressed: _loading ? null : _loadMemory,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const StatusView.loading();
    }

    if (_error != null) {
      return StatusView.error(
        title: 'Failed to load memory',
        message: _error!,
        onRetry: _loadMemory,
      );
    }

    if (_entries.isEmpty) {
      return const StatusView.empty(
        icon: Icons.psychology,
        title: 'No memory entries',
        message:
            'Memory entries are cross-session facts the agent remembers.\n'
            'They are configured in ~/.hermes/config.yaml',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadMemory,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        itemCount: _entries.length,
        separatorBuilder: (_, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final entry = _entries[index];
          final target = entry['target'] as String? ?? 'memory';
          final content = entry['content'] as String? ?? '';

          final theme = Theme.of(context);
          final isUserEntry = target == 'user';

          return GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The entry's origin reads as a lit tag for the user profile
                // and a quiet outline for general long-term facts.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(HermesRadius.pill),
                    gradient: isUserEntry ? hermesAccentGradient : null,
                    border: isUserEntry
                        ? null
                        : Border.all(
                            color: HermesGlass.stroke(theme.brightness),
                          ),
                    boxShadow: isUserEntry
                        ? hermesGlow(hermesMagenta, alpha: 0.30, blur: 12)
                        : null,
                  ),
                  child: Text(
                    target,
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w600,
                      color: isUserEntry
                          ? Colors.white
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  content,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
