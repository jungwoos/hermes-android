// The dialogs that create and repair a saved connection: the full
// add/edit form, a quick gateway API-key update, and the dashboard/proxy
// settings.
//
// They live beside the connection list rather than in main.dart because the
// list is rendered inside the app shell (both in the side panel and as the
// main pane), so the shell — not a parent route — owns them.
import 'package:flutter/material.dart';

import '../services/connection_manager.dart';
import '../theme.dart';

/// The inline error banner shared by every connection dialog.
class DialogErrorBox extends StatelessWidget {
  const DialogErrorBox(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: hermesAlert.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(HermesRadius.chip),
        border: Border.all(color: hermesAlert.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: hermesAlert, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: hermesAlert, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Adds a connection, or edits [existing]. [onSaved] fires after the store
/// changed so the caller can re-read it.
Future<void> showConnectionDialog(
  BuildContext context, {
  required ConnectionManager connManager,
  SavedConnection? existing,
  VoidCallback? onSaved,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ConnectionDialog(
      initialConnection: existing,
      onSave: (form) {
        if (existing == null) {
          connManager.saveConnection(
            form.label,
            form.host,
            dashboardPort: form.dashboardPort,
            dashboardPrefix: form.dashboardPrefix,
            dashboardProxied: form.dashboardProxied,
            dashboardUsername: form.dashboardUsername,
            dashboardPassword: form.dashboardPassword,
            gatewayPort: form.gatewayPort,
            apiKey: form.apiKey,
            gatewayPrefix: form.gatewayPrefix,
          );
        } else {
          connManager.updateConnection(
            existing.id,
            form.label,
            form.host,
            dashboardPort: form.dashboardPort,
            dashboardPrefix: form.dashboardPrefix,
            dashboardProxied: form.dashboardProxied,
            dashboardUsername: form.dashboardUsername,
            dashboardPassword: form.dashboardPassword,
            gatewayPort: form.gatewayPort,
            apiKey: form.apiKey,
            gatewayPrefix: form.gatewayPrefix,
          );
        }
        onSaved?.call();
      },
    ),
  );
}

/// Updates the API key of [connection]'s Gateway API Server, validating it
/// against `/health` before saving.
Future<void> showGatewayApiKeyDialog(
  BuildContext context, {
  required ConnectionManager connManager,
  required SavedConnection connection,
  VoidCallback? onSaved,
}) {
  final ctrl = TextEditingController(text: connection.apiKey);
  bool validating = false;
  String? error;

  return showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Gateway API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error != null) DialogErrorBox(error!),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'API_SERVER_KEY from ~/.hermes/.env',
              ),
              obscureText: true,
              enabled: !validating,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: validating ? null : () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: validating
                ? null
                : () async {
                    final key = ctrl.text.trim();
                    if (key.isEmpty) return;

                    setDialogState(() {
                      validating = true;
                      error = null;
                    });

                    try {
                      final client = ApiClient(
                        baseUrl: connection.gatewayBaseUrl!,
                        apiKey: key,
                        pathPrefix: connection.gatewayPrefix ?? '',
                      );
                      final ok = await client.healthCheck();
                      client.close();

                      if (!ctx.mounted) return;

                      if (ok) {
                        connManager.updateApiKey(connection.id, key);
                        onSaved?.call();
                        Navigator.pop(ctx);
                      } else {
                        setDialogState(() {
                          error = 'Invalid API key. Server returned 401.';
                          validating = false;
                        });
                      }
                    } catch (e) {
                      if (!ctx.mounted) return;
                      setDialogState(() {
                        error =
                            'Cannot reach '
                            '${connection.host}:${connection.gatewayPort}.';
                        validating = false;
                      });
                    }
                  },
            child: validating
                ? const _DialogSpinner()
                : const Text('Save'),
          ),
        ],
      ),
    ),
  ).whenComplete(ctrl.dispose);
}

/// Quick path for the settings that change most often on a live dashboard:
/// its port, its login, and the proxy paths in front of it.
Future<void> showDashboardSettingsDialog(
  BuildContext context, {
  required ConnectionManager connManager,
  required SavedConnection connection,
  VoidCallback? onSaved,
}) {
  final conn = connection;
  final portCtrl = TextEditingController(text: conn.dashboardPort.toString());
  final userCtrl = TextEditingController(text: conn.dashboardUsername ?? '');
  final passCtrl = TextEditingController(text: conn.dashboardPassword ?? '');
  final dashboardPrefixCtrl = TextEditingController(
    text: conn.dashboardPrefix ?? '',
  );
  final gatewayPrefixCtrl = TextEditingController(
    text: conn.gatewayPrefix ?? '',
  );
  var proxied = conn.dashboardProxied;
  bool validating = false;
  String? error;

  return showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Dashboard / Proxy Settings'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'The dashboard backs Bots, Memory, Skills, Cron and '
                  'Settings. Leave username/password blank for an open '
                  'dashboard, or enable proxied mode when your reverse proxy '
                  'injects dashboard auth.',
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
              if (error != null) DialogErrorBox(error!),
              TextField(
                controller: portCtrl,
                decoration: const InputDecoration(
                  labelText: 'Dashboard Port',
                  hintText: '9119',
                ),
                keyboardType: TextInputType.number,
                enabled: !validating,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: userCtrl,
                decoration: const InputDecoration(
                  labelText: 'Username (optional)',
                ),
                autocorrect: false,
                enabled: !validating,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                decoration: const InputDecoration(
                  labelText: 'Password (optional)',
                ),
                obscureText: true,
                enabled: !validating,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: dashboardPrefixCtrl,
                decoration: const InputDecoration(
                  labelText: 'Dashboard path prefix',
                  hintText: 'e.g. /dashboard',
                ),
                autocorrect: false,
                enabled: !validating,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: proxied,
                contentPadding: EdgeInsets.zero,
                title: const Text('Dashboard behind proxy'),
                subtitle: const Text(
                  'Proxy injects auth; app sends clean requests',
                ),
                onChanged: validating
                    ? null
                    : (v) => setDialogState(() => proxied = v),
              ),
              if (conn.hasGateway) ...[
                const SizedBox(height: 4),
                TextField(
                  controller: gatewayPrefixCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Gateway path prefix',
                    hintText: 'e.g. /profile/peter',
                  ),
                  autocorrect: false,
                  enabled: !validating,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: validating ? null : () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: validating
                ? null
                : () async {
                    final port = int.tryParse(portCtrl.text.trim());
                    if (port == null || port <= 0) {
                      setDialogState(() => error = 'Invalid port number.');
                      return;
                    }
                    final user = userCtrl.text.trim();
                    final pass = passCtrl.text.trim();
                    final gatewayPrefix = gatewayPrefixCtrl.text.trim();
                    final dashboardPrefix = dashboardPrefixCtrl.text.trim();

                    setDialogState(() {
                      validating = true;
                      error = null;
                    });

                    // A changed gateway prefix is only worth checking when
                    // this connection actually has a gateway.
                    if (conn.hasGateway &&
                        gatewayPrefix != (conn.gatewayPrefix ?? '')) {
                      final apiClient = ApiClient(
                        baseUrl: conn.gatewayBaseUrl!,
                        apiKey: conn.apiKey,
                        pathPrefix: gatewayPrefix,
                      );
                      final ok = await apiClient.healthCheck();
                      apiClient.close();
                      if (!ctx.mounted) return;
                      if (!ok) {
                        setDialogState(() {
                          error =
                              'Could not reach/authenticate the Gateway API at '
                              '${conn.host}:${conn.gatewayPort}$gatewayPrefix.';
                          validating = false;
                        });
                        return;
                      }
                    }

                    final client = DashboardClient(
                      host: conn.host,
                      port: port,
                      useHttps: conn.useHttps,
                      pathPrefix: dashboardPrefix,
                      proxied: proxied,
                      username: user.isEmpty ? null : user,
                      password: pass.isEmpty ? null : pass,
                    );
                    try {
                      await client.getModelInfo();
                      client.close();
                      if (!ctx.mounted) return;
                      connManager.updateDashboardAuth(
                        conn.id,
                        dashboardPort: port,
                        username: user,
                        password: pass,
                        gatewayPrefix: conn.hasGateway ? gatewayPrefix : null,
                        dashboardPrefix: dashboardPrefix,
                        dashboardProxied: proxied,
                      );
                      onSaved?.call();
                      Navigator.pop(ctx);
                    } catch (e) {
                      client.close();
                      if (!ctx.mounted) return;
                      setDialogState(() {
                        error =
                            'Could not reach/authenticate the dashboard at '
                            '${conn.host}:$port. '
                            'Check the port and credentials.';
                        validating = false;
                      });
                    }
                  },
            child: validating
                ? const _DialogSpinner()
                : const Text('Save'),
          ),
        ],
      ),
    ),
  ).whenComplete(() {
    portCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    dashboardPrefixCtrl.dispose();
    gatewayPrefixCtrl.dispose();
  });
}

/// The in-button spinner every connection dialog shows while validating.
class _DialogSpinner extends StatelessWidget {
  const _DialogSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
    );
  }
}

/// Everything the connection dialog collected. The dashboard fields are always
/// filled in — it is the surface the app is built on. The gateway fields stay
/// null when the user left that section empty.
class _ConnectionForm {
  const _ConnectionForm({
    required this.label,
    required this.host,
    required this.dashboardPort,
    this.dashboardPrefix,
    this.dashboardProxied = false,
    this.dashboardUsername,
    this.dashboardPassword,
    this.gatewayPort,
    this.apiKey = '',
    this.gatewayPrefix,
  });

  final String label;
  final String host;
  final int dashboardPort;
  final String? dashboardPrefix;
  final bool dashboardProxied;
  final String? dashboardUsername;
  final String? dashboardPassword;
  final int? gatewayPort;
  final String apiKey;
  final String? gatewayPrefix;
}

class _ConnectionDialog extends StatefulWidget {
  final SavedConnection? initialConnection;
  final void Function(_ConnectionForm form) onSave;
  const _ConnectionDialog({required this.onSave, this.initialConnection});

  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late final TextEditingController _label;
  late final TextEditingController _host;
  late final TextEditingController _dashPort;
  late final TextEditingController _dashUser;
  late final TextEditingController _dashPass;
  late final TextEditingController _dashboardPrefix;
  late final TextEditingController _gatewayPort;
  late final TextEditingController _apiKey;
  late final TextEditingController _gatewayPrefix;
  late bool _showGateway;
  late bool _dashboardProxied;
  bool _validating = false;
  String? _error;

  bool get _isEditing => widget.initialConnection != null;

  @override
  void initState() {
    super.initState();
    final conn = widget.initialConnection;
    _label = TextEditingController(text: conn?.label ?? 'Home');
    _host = TextEditingController(
      text: conn == null
          ? ''
          : conn.useHttps
          ? 'https://${conn.host}'
          : conn.host,
    );
    _dashPort = TextEditingController(
      text: (conn?.dashboardPort ?? SavedConnection.defaultDashboardPort)
          .toString(),
    );
    _dashUser = TextEditingController(text: conn?.dashboardUsername ?? '');
    _dashPass = TextEditingController(text: conn?.dashboardPassword ?? '');
    _dashboardPrefix = TextEditingController(text: conn?.dashboardPrefix ?? '');
    _gatewayPort = TextEditingController(
      text: conn?.gatewayPort?.toString() ?? '',
    );
    _apiKey = TextEditingController(text: conn?.apiKey ?? '');
    _gatewayPrefix = TextEditingController(text: conn?.gatewayPrefix ?? '');
    _dashboardProxied = conn?.dashboardProxied ?? false;
    _showGateway =
        conn?.hasGateway == true ||
        conn?.dashboardPrefix?.isNotEmpty == true ||
        _dashboardProxied;
  }

  /// The gateway port to save, or null for a dashboard-only connection.
  ///
  /// An API key or a gateway prefix with no port is read as "yes, there is a
  /// gateway" rather than as an inconsistency — the port is the part with an
  /// obvious default.
  int? _resolveGatewayPort(NormalizedConnectionHost normalized) {
    final typed = _gatewayPort.text.trim();
    // 0 rather than null on unparseable text, so it reads as an invalid port
    // instead of silently dropping the gateway.
    if (typed.isNotEmpty) return int.tryParse(typed) ?? 0;
    if (_apiKey.text.trim().isEmpty && _gatewayPrefix.text.trim().isEmpty) {
      return null;
    }
    // Behind an HTTPS proxy both surfaces normally share the external port.
    return normalized.useHttps
        ? normalized.port
        : SavedConnection.defaultGatewayPort;
  }

  Future<void> _validateAndSave() async {
    final label = _label.text.trim();
    final host = _host.text.trim();
    final dashPortText = _dashPort.text.trim();
    final dashPort =
        int.tryParse(dashPortText) ?? SavedConnection.defaultDashboardPort;

    if (label.isEmpty || host.isEmpty) return;
    if (dashPortText.isNotEmpty && int.tryParse(dashPortText) == null) {
      setState(() => _error = 'Invalid dashboard port.');
      return;
    }

    final dashUser = _dashUser.text.trim();
    final dashPass = _dashPass.text.trim();
    final dashboardPrefix = _dashboardPrefix.text.trim();
    final apiKey = _apiKey.text.trim();
    final gatewayPrefix = _gatewayPrefix.text.trim();

    setState(() {
      _validating = true;
      _error = null;
    });

    final normalized = SavedConnection.normalizeHostAndPort(host, dashPort);
    final gatewayPort = _resolveGatewayPort(normalized);
    if (gatewayPort != null && gatewayPort <= 0) {
      setState(() {
        _error = 'Invalid gateway port.';
        _validating = false;
        _showGateway = true;
      });
      return;
    }

    // The dashboard is the surface the app runs on, so it is validated first
    // and its failure blocks the save.
    final dashClient = DashboardClient(
      host: normalized.host,
      port: normalized.port,
      useHttps: normalized.useHttps,
      pathPrefix: dashboardPrefix,
      proxied: _dashboardProxied,
      username: dashUser.isEmpty ? null : dashUser,
      password: dashPass.isEmpty ? null : dashPass,
    );
    try {
      await dashClient.getModelInfo();
    } catch (_) {
      dashClient.close();
      if (!mounted) return;
      setState(() {
        _error =
            'Could not reach the dashboard at '
            '${normalized.host}:${normalized.port}$dashboardPrefix. '
            'Check the port, and the login if the dashboard is protected.';
        _validating = false;
      });
      return;
    }
    dashClient.close();
    if (!mounted) return;

    // The gateway is optional: only what the user filled in gets checked.
    if (gatewayPort != null) {
      final gatewayBaseUrl = SavedConnection(
        id: '',
        label: '',
        host: normalized.host,
        useHttps: normalized.useHttps,
        gatewayPort: gatewayPort,
      ).gatewayBaseUrl!;
      final apiClient = ApiClient(
        baseUrl: gatewayBaseUrl,
        apiKey: apiKey,
        pathPrefix: gatewayPrefix,
      );
      bool ok;
      try {
        ok = await apiClient.healthCheck();
      } catch (_) {
        ok = false;
      }
      apiClient.close();
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _error = apiKey.isEmpty
              ? 'Dashboard connected, but the Gateway API Server at '
                    '${normalized.host}:$gatewayPort needs an API key. Enter '
                    'your API_SERVER_KEY, or clear the gateway fields to skip it.'
              : 'Dashboard connected, but the Gateway API Server at '
                    '${normalized.host}:$gatewayPort refused the request. '
                    'Check the port and API key, or clear the gateway fields '
                    'to skip it.';
          _validating = false;
          _showGateway = true;
        });
        return;
      }
    }

    widget.onSave(
      _ConnectionForm(
        label: label,
        host: host,
        dashboardPort: dashPort,
        dashboardPrefix: dashboardPrefix.isEmpty ? null : dashboardPrefix,
        dashboardProxied: _dashboardProxied,
        dashboardUsername: dashUser.isEmpty ? null : dashUser,
        dashboardPassword: dashPass.isEmpty ? null : dashPass,
        gatewayPort: gatewayPort,
        apiKey: apiKey,
        gatewayPrefix: gatewayPrefix.isEmpty ? null : gatewayPrefix,
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_isEditing ? 'Edit Connection' : 'Add Connection'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) DialogErrorBox(_error!),
            TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'Host',
                hintText:
                    '192.168.1.50, 100.x.y.z, or hermes-machine.tailnet.ts.net',
              ),
              keyboardType: TextInputType.text,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dashPort,
              decoration: const InputDecoration(
                labelText: 'Dashboard Port',
                hintText: '9119 (Dashboard)',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dashUser,
              decoration: const InputDecoration(
                labelText: 'Dashboard Username (optional)',
              ),
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dashPass,
              decoration: const InputDecoration(
                labelText: 'Dashboard Password (optional)',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 6),
            Text(
              'The dashboard serves Bots, Memory, Skills, Cron and Settings. '
              'Leave the login blank for an open dashboard.',
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: _validating
                  ? null
                  : () => setState(() => _showGateway = !_showGateway),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      _showGateway ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Gateway API Server and proxy paths',
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_showGateway) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Optional. The Sessions list and its chat run on the Gateway '
                  'API Server, whose API key covers one profile. Leave the port '
                  'blank for a dashboard-only connection.',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
              TextField(
                controller: _gatewayPort,
                decoration: const InputDecoration(
                  labelText: 'Gateway Port',
                  hintText: '8642 (API Server) — blank to skip',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKey,
                decoration: const InputDecoration(
                  labelText: 'Gateway API Key',
                  hintText: 'API_SERVER_KEY from ~/.hermes/.env',
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _gatewayPrefix,
                decoration: const InputDecoration(
                  labelText: 'Gateway path prefix',
                  hintText:
                      'e.g. /profile/peter (proxy path before /api/ and /v1/)',
                ),
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _dashboardPrefix,
                decoration: const InputDecoration(
                  labelText: 'Dashboard path prefix',
                  hintText: 'e.g. /dashboard (proxy path before /api/)',
                ),
                autocorrect: false,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: _dashboardProxied,
                contentPadding: EdgeInsets.zero,
                title: const Text('Dashboard behind proxy'),
                subtitle: const Text(
                  'Nginx injects auth — app sends clean requests',
                ),
                onChanged: (v) => setState(() => _dashboardProxied = v),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _validating ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _validating ? null : _validateAndSave,
          child: _validating
              ? const _DialogSpinner()
              : Text(_isEditing ? 'Save Changes' : 'Connect'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _dashPort.dispose();
    _dashUser.dispose();
    _dashPass.dispose();
    _dashboardPrefix.dispose();
    _gatewayPort.dispose();
    _apiKey.dispose();
    _gatewayPrefix.dispose();
    super.dispose();
  }
}
