// The saved-gateway roster, shared by the shell's side panel (compact) and its
// main pane (full width).
//
// Picking a gateway is a selection inside the shell, not a route above it: the
// same screen stays on show and only its content swaps, which is why this is a
// widget rather than a screen of its own.
import 'package:flutter/material.dart';

import '../services/connection_manager.dart';
import '../theme.dart';
import '../utils/responsive.dart';
import 'connection_dialogs.dart';
import 'glass.dart';
import 'plasma_orb.dart';
import 'status_view.dart';

/// The dashboard address of [conn], plus its gateway port when it has one.
String connectionAddressLine(SavedConnection conn) {
  final dashboard =
      '${conn.host}:${conn.dashboardPort}${conn.dashboardPrefix ?? ''}';
  return conn.hasGateway
      ? '$dashboard · gateway ${conn.gatewayPort}'
      : dashboard;
}

class ConnectionListView extends StatelessWidget {
  const ConnectionListView({
    required this.connManager,
    required this.connections,
    required this.onSelect,
    required this.onChanged,
    this.activeId,
    this.compact = false,
    this.minimal = false,
    super.key,
  });

  final ConnectionManager connManager;

  /// Rendered as given — the shell owns the list so it can also name the
  /// active gateway in the panel header.
  final List<SavedConnection> connections;

  final ValueChanged<SavedConnection> onSelect;

  /// Fires whenever a dialog or a delete changed the store.
  final VoidCallback onChanged;

  /// Highlights the gateway the shell is currently showing.
  final String? activeId;

  /// Denser layout for the side panel.
  final bool compact;

  /// Stripped-back layout for a phone-width pinned column: a colour dot and
  /// the label, with no room for the address or the lock.
  final bool minimal;

  @override
  Widget build(BuildContext context) {
    if (connections.isEmpty) {
      return compact
          ? const StatusView.empty(
              icon: Icons.router,
              title: 'No connections',
              message: 'Add a gateway with the + button.',
            )
          : _buildEmptyState(context);
    }

    if (!compact && Responsive.isTablet(context)) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: Responsive.gridColumns(context),
          childAspectRatio: 3.2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: connections.length,
        itemBuilder: (ctx, i) => _buildCard(ctx, connections[i]),
      );
    }

    return ListView.separated(
      padding: compact
          ? const EdgeInsets.fromLTRB(10, 4, 10, 16)
          : const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: connections.length,
      separatorBuilder: (_, index) => SizedBox(height: compact ? 10 : 12),
      itemBuilder: (ctx, i) => _buildCard(ctx, connections[i]),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PlasmaOrb(size: 168),
            const SizedBox(height: 36),
            Text(
              'No connections',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Tap + to add a remote Hermes machine\n(Dashboard, port 9119)',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, SavedConnection conn) {
    final theme = Theme.of(context);
    final secured = conn.dashboardSecured;
    final avatar = compact ? 30.0 : 46.0;

    return GlassCard(
      padding: minimal
          ? const EdgeInsets.fromLTRB(10, 10, 0, 10)
          : compact
          ? const EdgeInsets.fromLTRB(12, 10, 0, 10)
          : const EdgeInsets.fromLTRB(14, 14, 4, 14),
      active: conn.id == activeId,
      onTap: () => onSelect(conn),
      child: Row(
        children: [
          if (minimal)
            // Same dot the bot roster uses: the disc and its glyph are the
            // first things to go at this width.
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: hermesAccentGradient,
                boxShadow: hermesGlow(hermesMagenta, alpha: 0.5, blur: 10),
              ),
            )
          else
            Container(
              width: avatar,
              height: avatar,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: hermesAccentGradient,
                boxShadow: hermesGlow(hermesMagenta, alpha: 0.35, blur: 18),
              ),
              child: Icon(
                Icons.router,
                color: Colors.white,
                size: compact ? 16 : 21,
              ),
            ),
          SizedBox(width: minimal ? 8 : (compact ? 9 : 14)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  conn.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      (compact
                              ? theme.textTheme.titleSmall
                              : theme.textTheme.titleMedium)
                          ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (!minimal) ...[
                  const SizedBox(height: 3),
                  Text(
                    connectionAddressLine(conn),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: compact ? 11.5 : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // An open dashboard on a trusted LAN is normal, so this reports
          // whether a login is in use rather than flagging its absence.
          if (!minimal)
            Icon(
              secured ? Icons.lock_outline : Icons.lock_open,
              size: 16,
              color: secured ? hermesCyan : theme.colorScheme.onSurfaceVariant,
            ),
          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_vert,
              color: theme.colorScheme.onSurfaceVariant,
              size: minimal ? 16 : (compact ? 18 : 24),
            ),
            onSelected: (v) => _onMenu(context, conn, v),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'edit',
                child: Text('Edit Connection'),
              ),
              const PopupMenuItem(
                value: 'dashboard',
                child: Text('Dashboard / Proxy Settings'),
              ),
              // Only meaningful once a gateway is configured.
              if (conn.hasGateway)
                const PopupMenuItem(
                  value: 'apikey',
                  child: Text('Gateway API Key'),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete', style: TextStyle(color: hermesAlert)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _onMenu(BuildContext context, SavedConnection conn, String action) {
    switch (action) {
      case 'edit':
        showConnectionDialog(
          context,
          connManager: connManager,
          existing: conn,
          onSaved: onChanged,
        );
      case 'dashboard':
        showDashboardSettingsDialog(
          context,
          connManager: connManager,
          connection: conn,
          onSaved: onChanged,
        );
      case 'apikey':
        showGatewayApiKeyDialog(
          context,
          connManager: connManager,
          connection: conn,
          onSaved: onChanged,
        );
      case 'delete':
        connManager.deleteConnection(conn.id);
        onChanged();
    }
  }
}
