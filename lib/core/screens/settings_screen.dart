// Settings screen for model selection, theme toggle, and app info.
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/connection_manager.dart';
import '../theme.dart';
import '../widgets/aurora.dart';
import '../widgets/glass.dart';
import '../widgets/status_view.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SettingsScreen extends StatefulWidget {
  final SavedConnection connection;

  /// When true the screen is rendered inside the split-view detail pane, so
  /// it must not show a back button.
  final bool embedded;

  const SettingsScreen({
    required this.connection,
    this.embedded = false,
    super.key,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late DashboardClient _client;
  Map<String, dynamic>? _modelInfo;
  Map<String, dynamic>? _modelOptions;
  bool _loading = true;
  String? _error;
  String? _successMsg;

  // Selected values
  String _selectedProvider = '';
  String _selectedModel = '';
  List<String> _providers = [];
  Map<String, List<Map<String, dynamic>>> _providerModels = {};

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
    _loadData();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait([
        _client.getModelInfo(),
        _client.getModelOptions(),
      ]);

      setState(() {
        _modelInfo = results[0];
        _modelOptions = results[1];
        _loading = false;
        _parseModelOptions();
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _parseModelOptions() {
    if (_modelOptions == null) return;

    final providers = _modelOptions!['providers'] as List<dynamic>? ?? [];
    _providers = [];
    _providerModels = {};

    for (final p in providers) {
      if (p is! Map<String, dynamic>) continue;
      final pMap = p;
      // Provider key is 'slug', not 'id'
      final providerId =
          (pMap['slug'] as String?) ?? (pMap['id'] as String?) ?? '';
      final rawModels = pMap['models'] as List<dynamic>? ?? [];
      if (providerId.isEmpty || rawModels.isEmpty) continue;

      _providers.add(providerId);
      // Models are strings (model IDs), not dicts
      // Convert to list of {'id': modelId, 'name': modelId} maps for dropdown
      _providerModels[providerId] = rawModels
          .map((m) {
            if (m is String) {
              return {'id': m, 'name': m};
            } else if (m is Map<String, dynamic>) {
              return m;
            }
            return <String, dynamic>{};
          })
          .where((m) => m['id'] != null && (m['id'] as String).isNotEmpty)
          .toList();
    }

    // Set initial selections from current model
    if (_modelInfo != null) {
      _selectedProvider = (_modelInfo!['provider'] as String?) ?? '';
      _selectedModel = (_modelInfo!['model'] as String?) ?? '';
    }
  }

  Future<void> _applyModel() async {
    if (_selectedProvider.isEmpty || _selectedModel.isEmpty) return;

    setState(() {
      _error = null;
      _successMsg = null;
    });

    try {
      await _client.setModel('main', _selectedProvider, _selectedModel);
      setState(() {
        _successMsg = 'Model set to $_selectedModel — applies to new sessions';
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      intensity: 0.7,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: const Text('Settings'),
        actions: [
          FaintIconButton(
            icon: Icons.refresh,
            onPressed: _loading ? null : _loadData,
            tooltip: 'Refresh',
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

    if (_error != null && _modelOptions == null) {
      return StatusView.error(
        title: 'Failed to load settings',
        message: _error!,
        onRetry: _loadData,
      );
    }

    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // ---- Section: Model ----
        const SectionLabel('Model Selection'),
        if (_modelInfo != null)
          GlassCard(
            glow: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: hermesAccentGradient,
                        boxShadow: hermesGlow(
                          hermesMagenta,
                          alpha: 0.35,
                          blur: 14,
                        ),
                      ),
                      child: const Icon(
                        Icons.smart_toy,
                        size: 17,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Current Model',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '${_modelInfo!['model'] ?? '???'}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'via ${_modelInfo!['provider'] ?? '???'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_modelInfo!['effective_context_length'] != null &&
                    _modelInfo!['effective_context_length'] != 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Context: ${_modelInfo!['effective_context_length']} tokens',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),

        // Provider picker
        if (_providers.isNotEmpty) ...[
          _buildDropdown<String>(
            label: 'Provider',
            value:
                _selectedProvider.isNotEmpty &&
                    _providers.contains(_selectedProvider)
                ? _selectedProvider
                : null,
            items: _providers
                .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                .toList(),
            onChanged: (val) {
              setState(() {
                _selectedProvider = val!;
                // Reset model when switching providers
                final models = _providerModels[val];
                if (models != null && models.isNotEmpty) {
                  _selectedModel = models.first['id'] as String? ?? '';
                } else {
                  _selectedModel = '';
                }
              });
            },
          ),
          const SizedBox(height: 12),
        ],

        // Model picker
        if (_selectedProvider.isNotEmpty &&
            _providerModels.containsKey(_selectedProvider)) ...[
          _buildDropdown<String>(
            label: 'Model',
            value: _selectedModel,
            items: _providerModels[_selectedProvider]!.map((m) {
              final id = m['id'] as String? ?? '';
              final name = m['name'] as String? ?? id;
              return DropdownMenuItem(value: id, child: Text(name));
            }).toList(),
            onChanged: (val) {
              setState(() => _selectedModel = val!);
            },
          ),
          const SizedBox(height: 16),
          GradientPillButton(
            label: 'Apply Model',
            icon: Icons.check,
            expand: true,
            onPressed: _applyModel,
          ),
        ],
        const SizedBox(height: 16),

        // Success/error messages
        if (_successMsg != null)
          StatusMessageCard.success(message: _successMsg!),
        if (_error != null && _modelOptions != null)
          StatusMessageCard.error(message: _error!),

        const SizedBox(height: 16),

        // ---- Section: Theme ----
        const SectionLabel('Appearance'),
        _ThemeToggle(),
        const SizedBox(height: 10),
        _VerboseToggle(),
        const SizedBox(height: 28),

        // ---- Section: Voice ----
        const SectionLabel('Voice'),
        _VoicePicker(),
        const SizedBox(height: 28),

        // ---- Section: Session Sources ----
        const SectionLabel('Session Sources'),
        _SessionSourcesFilter(connectionId: widget.connection.id),
        const SizedBox(height: 28),

        // ---- Section: Connection ----
        const SectionLabel('Connection'),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoRow('Label', widget.connection.label),
              const SizedBox(height: 8),
              _infoRow('Host', widget.connection.host),
              const SizedBox(height: 8),
              _infoRow('Port', '${widget.connection.port}'),
              const SizedBox(height: 8),
              _infoRow('Base URL', widget.connection.baseUrl),
            ],
          ),
        ),
        const SizedBox(height: 28),

        // ---- Section: About ----
        const SectionLabel('About'),
        _AboutCard(),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 84,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown<T>({
    required String label,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
      items: items,
      onChanged: onChanged,
    );
  }
}

/// About card that reads the real version from package_info_plus.
class _AboutCard extends StatefulWidget {
  @override
  State<_AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends State<_AboutCard> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      setState(() => _version = '${info.version}+${info.buildNumber}');
    } catch (_) {
      setState(() => _version = 'unknown');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Hermes Agent for Android',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Version ${_version.isNotEmpty ? _version : '…'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Browse and manage your Hermes Agent sessions from your phone. '
            'Connects to a Hermes dashboard running on your local network.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Toggle for verbose mode — shows tool calls, thinking, and message metadata in chat.
class _VerboseToggle extends StatefulWidget {
  @override
  State<_VerboseToggle> createState() => _VerboseToggleState();
}

class _VerboseToggleState extends State<_VerboseToggle> {
  bool _verbose = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _verbose = prefs.getBool('verbose_mode') ?? false);
  }

  Future<void> _set(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('verbose_mode', value);
    setState(() => _verbose = value);
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: SwitchListTile(
        title: const Text('Verbose Mode'),
        subtitle: Text(
          'Show tool calls, thinking, and message metadata',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        secondary: const Icon(Icons.terminal),
        value: _verbose,
        onChanged: _set,
      ),
    );
  }
}

class _ThemeToggle extends StatefulWidget {
  @override
  State<_ThemeToggle> createState() => _ThemeToggleState();
}

class _ThemeToggleState extends State<_ThemeToggle> {
  String _mode = HermesThemeMode.toPrefsValue(HermesThemeMode.notifier.value);

  Future<void> _setMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode);
    if (!mounted) return;
    setState(() => _mode = mode);
    HermesThemeMode.notifier.value = HermesThemeMode.fromPrefsValue(mode);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SegmentedButton<String>(
        segments: const [
          ButtonSegment(
            value: 'system',
            label: Text('System'),
            icon: Icon(Icons.brightness_auto, size: 18),
          ),
          ButtonSegment(
            value: 'dark',
            label: Text('Dark'),
            icon: Icon(Icons.dark_mode, size: 18),
          ),
          ButtonSegment(
            value: 'light',
            label: Text('Light'),
            icon: Icon(Icons.light_mode, size: 18),
          ),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => _setMode(s.first),
        style: ButtonStyle(visualDensity: VisualDensity.compact),
      ),
    );
  }
}

class _VoicePicker extends StatefulWidget {
  @override
  State<_VoicePicker> createState() => _VoicePickerState();
}

class _VoicePickerState extends State<_VoicePicker> {
  final FlutterTts _tts = FlutterTts();
  final List<Map<String, String>> _voices = [];
  String? _selectedVoiceName;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _selectedVoiceName = prefs.getString('voice_name');

    try {
      final raw = await _tts.getVoices;
      if (raw is List && raw.isNotEmpty) {
        for (final item in raw) {
          if (item is Map) {
            final m = <String, String>{};
            m['name'] = (item['name'] ?? '').toString();
            m['locale'] = (item['locale'] ?? '').toString();
            if (m['name']!.isNotEmpty) _voices.add(m);
          }
        }
      }
    } catch (_) {}

    if (_voices.isEmpty) {
      try {
        final raw = await _tts.getLanguages;
        final seen = <String>{};
        if (raw is List) {
          for (final item in raw) {
            final lang = item.toString();
            if (lang.isNotEmpty && seen.add(lang)) {
              _voices.add({'name': lang, 'locale': lang});
            }
          }
        }
      } catch (_) {}
    }

    _voices.sort(
      (a, b) => (a['locale'] ?? '').compareTo(b['locale'] ?? ''),
    );

    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _set(Map<String, String>? voice) async {
    final prefs = await SharedPreferences.getInstance();
    if (voice == null) {
      await prefs.remove('voice_name');
      await prefs.remove('voice_locale');
      setState(() => _selectedVoiceName = null);
    } else {
      final name = voice['name'] ?? '';
      final locale = voice['locale'] ?? '';
      await prefs.setString('voice_name', name);
      await prefs.setString('voice_locale', locale);
      setState(() => _selectedVoiceName = name);
    }
  }

  String _voiceLabel(Map<String, String> voice) {
    final name = voice['name'] ?? '';
    final locale = voice['locale'] ?? '';
    if (name == locale) return locale;
    final gender = name.contains('male')
        ? '(male)'
        : name.contains('female')
            ? '(female)'
            : '';
    return '$locale $gender  [$name]';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const GlassCard(
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_voices.isEmpty) {
      return GlassCard(
        child: Text(
          'No TTS voices found.\n'
          'Install Google Text-to-Speech and download voice data.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      );
    }

    final items = <DropdownMenuItem<Map<String, String>?>>[
      const DropdownMenuItem(
        value: null,
        child: Text('Auto (device default)'),
      ),
      ..._voices.map(
        (v) => DropdownMenuItem(
          value: v,
          child: Text(
            _voiceLabel(v),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ];

    final current = _selectedVoiceName != null
        ? _voices.where((v) => v['name'] == _selectedVoiceName).firstOrNull
        : null;

    return DropdownButtonFormField<Map<String, String>?>(
      initialValue: current,
      decoration: const InputDecoration(
        labelText: 'Voice',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      items: items,
      onChanged: _set,
    );
  }
}

/// Checkbox list of session sources. Unchecked sources are filtered
/// client-side from the fetched session list by `Session.source`.
class _SessionSourcesFilter extends StatefulWidget {
  final String connectionId;
  const _SessionSourcesFilter({required this.connectionId});

  @override
  State<_SessionSourcesFilter> createState() => _SessionSourcesFilterState();
}

class _SessionSourcesFilterState extends State<_SessionSourcesFilter> {
  /// Known session source types. Hermes Gateway persists `session.source` for
  /// every session. Sources not in this list are always shown (whitelisted).
  static const Map<String, String> _knownSources = {
    'acp': 'Autonomous agents',
    'api_server': 'External API clients',
    'cli': 'Command-line chats',
    'cron': 'Scheduled tasks',
    'desktop': 'Desktop app',
    'discord': 'Discord chats',
    'gateway': 'Gateway API access',
    'mobile': 'Phone or tablet',
    'signal': 'Signal messages',
    'slack': 'Slack chats',
    'telegram': 'Telegram messages',
    'tool': 'Developer tool calls',
    'tui': 'Terminal sessions',
    'whatsapp': 'WhatsApp messages',
  };

  Set<String> _excluded = {};

  String get _prefsKey =>
      'excluded_session_sources_${widget.connectionId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _excluded =
          prefs.getStringList(_prefsKey)?.toSet() ?? {};
    });
  }

  Future<void> _toggle(String source, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (enabled) {
        _excluded.remove(source);
      } else {
        _excluded.add(source);
      }
    });
    await prefs.setStringList(_prefsKey, _excluded.toList());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: _knownSources.entries.map((entry) {
          final source = entry.key;
          final label = entry.value;
          final isVisible = !_excluded.contains(source);
          return CheckboxListTile(
            title: Text(label),
            subtitle: Text(
              source,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            value: isVisible,
            onChanged: (val) => _toggle(source, val ?? true),
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
          );
        }).toList(),
      ),
    );
  }
}
