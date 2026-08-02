// Skills browser — list installed skills with enabled/disabled status.
import 'package:flutter/material.dart';
import '../services/connection_manager.dart';
import '../theme.dart';
import '../widgets/aurora.dart';
import '../widgets/glass.dart';
import '../widgets/status_view.dart';

class SkillsScreen extends StatefulWidget {
  final SavedConnection connection;

  /// When true the screen is rendered inside the split-view detail pane, so
  /// it must not show a back button.
  final bool embedded;

  const SkillsScreen({
    required this.connection,
    this.embedded = false,
    super.key,
  });

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  late DashboardClient _client;
  List<Map<String, dynamic>> _skills = [];
  bool _loading = true;
  String? _error;

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
    _load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await _client.getSkills();
      if (!mounted) return;
      setState(() {
        _skills = raw.whereType<Map<String, dynamic>>().toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
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
        title: Text('Skills (${_skills.length})'),
        actions: [
          FaintIconButton(
            icon: Icons.refresh,
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const StatusView.loading();
    if (_error != null) {
      return StatusView.error(
        title: 'Failed to load skills',
        message: _error!,
        onRetry: _load,
      );
    }
    if (_skills.isEmpty) {
      return const StatusView.empty(
        icon: Icons.extension_off,
        title: 'No skills found',
      );
    }
    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        itemCount: _skills.length,
        separatorBuilder: (_, index) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final skill = _skills[i];
          final name = skill['name'] as String? ?? '';
          final enabled = skill['enabled'] as bool? ?? false;
          final description = skill['description'] as String? ?? '';
          final statusColor = enabled
              ? hermesCyan
              : theme.colorScheme.onSurfaceVariant;

          return GlassCard(
            radius: HermesRadius.tile,
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(top: 5, right: 12),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                    boxShadow: enabled
                        ? hermesGlow(hermesCyan, alpha: 0.6, blur: 8)
                        : null,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Text(
                  enabled ? 'on' : 'off',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: statusColor,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
