// Cron job browser — list and manage Hermes scheduled cron jobs.
//
// API: GET /api/cron/jobs — returns JSON array of job objects
//      POST /api/cron/jobs/{id}/pause | resume | trigger
//      DELETE /api/cron/jobs/{id}
//      POST /api/cron/jobs — create new job
//      PUT /api/cron/jobs/{id} — update existing job
import 'package:flutter/material.dart';

import '../services/connection_manager.dart';
import '../theme.dart';
import '../widgets/aurora.dart';
import '../widgets/glass.dart';
import '../widgets/status_view.dart';

class CronScreen extends StatefulWidget {
  final SavedConnection connection;

  /// When true the screen is rendered inside the split-view detail pane, so
  /// it must not show a back button.
  final bool embedded;

  const CronScreen({
    required this.connection,
    this.embedded = false,
    super.key,
  });

  @override
  State<CronScreen> createState() => _CronScreenState();
}

class _CronScreenState extends State<CronScreen> {
  late DashboardClient _client;
  List<Map<String, dynamic>> _jobs = [];
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
    _loadJobs();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _loadJobs() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final data = await _client.apiGetList('cron/jobs');
      final items = <Map<String, dynamic>>[];
      for (final item in data) {
        if (item is Map<String, dynamic>) items.add(item);
      }

      if (!mounted) return;
      setState(() {
        _jobs = items;
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

  bool _isPaused(Map<String, dynamic> job) {
    return job['paused_at'] != null ||
        job['state'] == 'paused' ||
        job['enabled'] == false;
  }

  String _scheduleDisplay(Map<String, dynamic> job) {
    final display = job['schedule_display'] as String?;
    if (display != null && display.isNotEmpty) return display;

    final schedule = job['schedule'];
    if (schedule is String) return schedule;
    if (schedule is Map) {
      return schedule['display'] as String? ??
          schedule['run_at'] as String? ??
          schedule.toString();
    }
    return '';
  }

  String _jobName(Map<String, dynamic> job) {
    return job['name'] as String? ?? job['id'] as String? ?? 'Untitled';
  }

  String _jobPrompt(Map<String, dynamic> job) {
    final prompt = job['prompt'] as String? ?? '';
    if (prompt.length > 120) return '${prompt.substring(0, 120)}…';
    return prompt;
  }

  Future<void> _togglePause(Map<String, dynamic> job) async {
    final jobId = job['id'] as String? ?? '';
    if (jobId.isEmpty) return;
    final paused = _isPaused(job);
    final action = paused ? 'resume' : 'pause';

    try {
      await _client.apiPost('cron/jobs/$jobId/$action');
      if (paused) {
        job.remove('paused_at');
        job['state'] = 'active';
        job['enabled'] = true;
      } else {
        job['paused_at'] = DateTime.now().toIso8601String();
        job['state'] = 'paused';
      }
      if (mounted) {
        setState(() {});
        showAppSnackBar(context, paused ? 'Job resumed' : 'Job paused');
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Failed: $e', isError: true);
      }
    }
  }

  Future<void> _deleteJob(Map<String, dynamic> job) async {
    final jobId = job['id'] as String? ?? '';
    if (jobId.isEmpty) return;
    final name = _jobName(job);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Cron Job'),
        content: Text('Delete "$name"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: hermesAlert,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _client.apiDelete('cron/jobs/$jobId');
      if (mounted) {
        setState(() => _jobs.removeWhere((j) => j['id'] == jobId));
        showAppSnackBar(context, 'Deleted "$name"');
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Delete failed: $e', isError: true);
      }
    }
  }

  Future<void> _triggerJob(Map<String, dynamic> job) async {
    final jobId = job['id'] as String? ?? '';
    if (jobId.isEmpty) return;
    try {
      await _client.apiPost('cron/jobs/$jobId/trigger');
      if (mounted) {
        showAppSnackBar(context, 'Job triggered');
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Failed: $e', isError: true);
      }
    }
  }

  Future<void> _showAddJobDialog() async {
    final result = await _showJobDialog(
      title: 'Add Cron Job',
      actionLabel: 'Add',
    );
    if (result == null || !mounted) return;

    try {
      final created = await _client.createJob(
        name: result['name']?.toString() ?? '',
        prompt: result['prompt']?.toString() ?? '',
        schedule: result['schedule']?.toString() ?? '',
      );
      if (result['no_agent'] == true) {
        final jobId =
            created['id']?.toString() ?? created['job_id']?.toString() ?? '';
        if (jobId.isNotEmpty) {
          await _client.updateJob(jobId, {'no_agent': true});
        }
      }
      if (!mounted) return;
      showAppSnackBar(context, 'Cron job added');
      await _loadJobs();
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Failed to add job: $e', isError: true);
      }
    }
  }

  Future<void> _showEditJobDialog(Map<String, dynamic> job) async {
    final result = await _showJobDialog(
      title: 'Edit Cron Job',
      actionLabel: 'Save',
      initialName: _jobName(job),
      initialPrompt: job['prompt'] as String? ?? '',
      initialSchedule: _scheduleDisplay(job),
      initialNoAgent: job['no_agent'] == true,
    );
    if (result == null || !mounted) return;

    final jobId = job['id'] as String? ?? '';
    if (jobId.isEmpty) return;

    try {
      await _client.updateJob(jobId, result);
      if (!mounted) return;
      showAppSnackBar(context, 'Cron job updated');
      await _loadJobs();
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Failed to update job: $e', isError: true);
      }
    }
  }

  Future<Map<String, dynamic>?> _showJobDialog({
    required String title,
    required String actionLabel,
    String initialName = '',
    String initialPrompt = '',
    String initialSchedule = '',
    bool initialNoAgent = false,
  }) async {
    final nameCtrl = TextEditingController(text: initialName);
    final promptCtrl = TextEditingController(text: initialPrompt);
    final scheduleCtrl = TextEditingController(text: initialSchedule);
    var noAgent = initialNoAgent;

    try {
      return await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g., Daily backup',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: promptCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Prompt',
                      hintText: 'What should the agent do?',
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: scheduleCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Schedule',
                      hintText: 'e.g., 0 9 * * * or every 2h',
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    value: noAgent,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Script only (no agent)'),
                    subtitle: const Text(
                      'Use for cron jobs backed by scripts.',
                    ),
                    onChanged: (value) => setDialogState(() => noAgent = value),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  final prompt = promptCtrl.text.trim();
                  final schedule = scheduleCtrl.text.trim();

                  if (name.isEmpty || prompt.isEmpty || schedule.isEmpty) {
                    showAppSnackBar(
                      ctx,
                      'Name, prompt, and schedule are required',
                    );
                    return;
                  }

                  Navigator.pop(ctx, {
                    'name': name,
                    'prompt': prompt,
                    'schedule': schedule,
                    'no_agent': noAgent,
                  });
                },
                child: Text(actionLabel),
              ),
            ],
          ),
        ),
      );
    } finally {
      nameCtrl.dispose();
      promptCtrl.dispose();
      scheduleCtrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      intensity: 0.7,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: const Text('Cron Jobs'),
        actions: [
          FaintIconButton(
            icon: Icons.refresh,
            tooltip: 'Refresh',
            onPressed: _loading ? null : _loadJobs,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: GradientOrbButton(
        icon: Icons.add,
        size: 58,
        tooltip: 'Add new cron job',
        onPressed: _loading ? null : _showAddJobDialog,
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const StatusView.loading();
    }

    if (_error != null) {
      return StatusView.error(
        title: 'Failed to load cron jobs',
        message: _error!,
        onRetry: _loadJobs,
      );
    }

    if (_jobs.isEmpty) {
      return const StatusView.empty(icon: Icons.schedule, title: 'No cron jobs');
    }

    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: _loadJobs,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: _jobs.length,
        separatorBuilder: (_, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final job = _jobs[index];
          final name = _jobName(job);
          final prompt = _jobPrompt(job);
          final schedule = _scheduleDisplay(job);
          final paused = _isPaused(job);
          final lastRun = job['last_run_at'] as String?;
          final nextRun = job['next_run_at'] as String?;
          final isNoAgent = job['no_agent'] == true;
          final stateColor = paused
              ? theme.colorScheme.onSurfaceVariant
              : hermesCyan;

          return GlassCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 14),
            onTap: () => _showEditJobDialog(job),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // A live job glows; a paused one goes dim.
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: stateColor,
                        boxShadow: paused
                            ? null
                            : hermesGlow(hermesCyan, alpha: 0.6, blur: 8),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isNoAgent)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        margin: const EdgeInsets.only(right: 4),
                        decoration: BoxDecoration(
                          color: hermesViolet.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(
                            HermesRadius.pill,
                          ),
                          border: Border.all(
                            color: hermesViolet.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Text(
                          'script',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 0.5,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    PopupMenuButton<String>(
                      icon: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onSelected: (action) {
                        if (action == 'trigger') _triggerJob(job);
                        if (action == 'edit') _showEditJobDialog(job);
                        if (action == 'toggle') _togglePause(job);
                        if (action == 'delete') _deleteJob(job);
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'trigger',
                          child: Row(
                            children: [
                              Icon(Icons.play_arrow, size: 18),
                              SizedBox(width: 8),
                              Text('Trigger now'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit, size: 18),
                              SizedBox(width: 8),
                              Text('Edit'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'toggle',
                          child: Row(
                            children: [
                              Icon(
                                paused ? Icons.play_arrow : Icons.pause,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(paused ? 'Resume' : 'Pause'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete,
                                size: 18,
                                color: hermesAlert,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Delete',
                                style: TextStyle(color: hermesAlert),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (prompt.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(
                      prompt,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                if (schedule.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Icons.schedule,
                        size: 13,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          schedule,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (lastRun != null && lastRun.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Last: $lastRun',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (nextRun != null && nextRun.isNotEmpty)
                  Text(
                    'Next: $nextRun',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
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
