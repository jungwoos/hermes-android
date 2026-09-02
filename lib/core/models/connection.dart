// Connection model for one remote Hermes machine.
//
// The dashboard (port 9119) is the primary surface: Bot Mode, Memory, Cron,
// Skills and Settings all speak to it, and a single dashboard session covers
// every agent profile on the machine.
//
// The Gateway API Server (port 8642) is optional. Its API key is scoped to one
// profile, so it cannot stand in for the dashboard; it only backs the Sessions
// list and that list's SSE chat. A connection with no gateway port configured
// simply has no Sessions surface.

class NormalizedConnectionHost {
  final String host;
  final int port;
  final bool useHttps;

  const NormalizedConnectionHost({
    required this.host,
    required this.port,
    this.useHttps = false,
  });
}

class SavedConnection {
  /// Default port of the dashboard — the primary surface.
  static const int defaultDashboardPort = 9119;

  /// Default port of the optional Gateway API Server.
  static const int defaultGatewayPort = 8642;

  final String id;
  final String label;
  final String host;
  final bool useHttps;

  /// Explicit dashboard port. When null, [dashboardPort] falls back to the
  /// default topology (see below). Dashboard-first connections always store it.
  final int? dashboardPortOverride;

  final String? dashboardPrefix;
  final bool dashboardProxied;

  /// Optional dashboard credentials for a basic-auth (password-protected)
  /// dashboard. When both are set, [DashboardClient] performs the
  /// `/auth/password-login` flow and authenticates with the resulting session
  /// cookie (same as hermes-desktop). When empty, it falls back to scraping the
  /// SPA session token, which only works on an insecure (open) dashboard.
  final String? dashboardUsername;
  final String? dashboardPassword;

  /// Port of the Gateway API Server, or null when this connection has none.
  /// Null disables the Sessions list and its chat; every dashboard-backed
  /// screen keeps working.
  final int? gatewayPort;

  /// `API_SERVER_KEY` for [gatewayPort]. Empty on an open or absent gateway.
  final String apiKey;

  final String? gatewayPrefix;

  SavedConnection({
    required this.id,
    required this.label,
    required this.host,
    this.useHttps = false,
    this.dashboardPortOverride,
    this.dashboardPrefix,
    this.dashboardProxied = false,
    this.dashboardUsername,
    this.dashboardPassword,
    this.gatewayPort,
    this.apiKey = '',
    this.gatewayPrefix,
  });

  String get _scheme => useHttps ? 'https' : 'http';

  /// Dashboard/API-server topology differs between local LAN and HTTPS proxy
  /// setups. Local dashboards live on 9119 while the Gateway API Server uses
  /// 8642. HTTPS reverse-proxy deployments usually expose both API surfaces on
  /// the same external HTTPS port. An explicit [dashboardPortOverride] always
  /// wins; the fallback only serves connections saved before the dashboard
  /// became the primary surface.
  int get dashboardPort =>
      dashboardPortOverride ??
      (useHttps ? (gatewayPort ?? 443) : defaultDashboardPort);

  String get dashboardBaseUrl => '$_scheme://$host:$dashboardPort';

  /// True when this connection can also reach the Gateway API Server.
  bool get hasGateway => gatewayPort != null;

  /// Base URL of the Gateway API Server, or null when there is no gateway.
  String? get gatewayBaseUrl =>
      gatewayPort == null ? null : '$_scheme://$host:$gatewayPort';

  /// True when the dashboard is reached with credentials rather than as an
  /// open (insecure) dashboard.
  bool get dashboardSecured =>
      dashboardProxied ||
      (dashboardUsername?.isNotEmpty ?? false) ||
      (dashboardPassword?.isNotEmpty ?? false);

  /// Joins a base URL with an optional path prefix, normalising slashes.
  static String joinBaseUrl(String baseUrl, String pathPrefix) {
    var url = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    if (pathPrefix.isNotEmpty) {
      var prefix = pathPrefix.startsWith('/') ? pathPrefix : '/$pathPrefix';
      prefix = prefix.endsWith('/')
          ? prefix.substring(0, prefix.length - 1)
          : prefix;
      url = '$url$prefix';
    }
    return url;
  }

  /// Parses [input] as a URI and extracts host, port, and HTTPS flag.
  ///
  /// When the user provides an explicit port inside the URL (e.g.
  /// `https://example.com:8443`) that port is always used.
  ///
  /// When the URL has no explicit port, the [fallbackPort] is used.
  /// Callers should set [fallbackPort] to the value typed by the user in the
  /// Port field, so custom HTTPS ports (e.g. 8443) are preserved. A default
  /// port (9119 or 8642) is a placeholder rather than a deliberate choice, so
  /// an HTTPS URL replaces it with 443.
  static NormalizedConnectionHost normalizeHostAndPort(
    String input,
    int fallbackPort,
  ) {
    var raw = input.trim();
    final bool detectedHttps = raw.toLowerCase().startsWith('https://');
    if (raw.isEmpty) {
      return NormalizedConnectionHost(
        host: raw,
        port: fallbackPort,
        useHttps: detectedHttps,
      );
    }

    if (!raw.contains('://')) raw = 'http://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      return NormalizedConnectionHost(
        host: input.trim(),
        port: fallbackPort,
        useHttps: detectedHttps,
      );
    }

    final bool fallbackIsDefault =
        fallbackPort == defaultDashboardPort ||
        fallbackPort == defaultGatewayPort;
    final normalizedPort = uri.hasPort
        ? uri.port
        : detectedHttps && fallbackIsDefault
        ? 443
        : fallbackPort;

    return NormalizedConnectionHost(
      host: uri.host,
      port: normalizedPort,
      useHttps: detectedHttps || (uri.scheme == 'https'),
    );
  }

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{
      'id': id,
      'label': label,
      'host': host,
      'use_https': useHttps,
      'dashboard_port': dashboardPortOverride,
      // Stored under the legacy `port` key so connections saved before the
      // dashboard became primary keep their gateway.
      'port': gatewayPort,
      'api_key': apiKey,
    };
    if (gatewayPrefix != null && gatewayPrefix!.isNotEmpty) {
      m['gateway_prefix'] = gatewayPrefix;
    }
    if (dashboardPrefix != null && dashboardPrefix!.isNotEmpty) {
      m['dashboard_prefix'] = dashboardPrefix;
    }
    if (dashboardProxied) {
      m['dashboard_proxied'] = dashboardProxied;
    }
    if (dashboardUsername != null && dashboardUsername!.isNotEmpty) {
      m['dashboard_username'] = dashboardUsername;
    }
    if (dashboardPassword != null && dashboardPassword!.isNotEmpty) {
      m['dashboard_password'] = dashboardPassword;
    }
    return m;
  }

  factory SavedConnection.fromMap(Map<String, dynamic> map) {
    String? nonEmpty(Object? v) {
      final s = (v as String?)?.trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    return SavedConnection(
      id: map['id'] as String,
      label: map['label'] as String,
      host: map['host'] as String,
      useHttps: (map['use_https'] as bool?) ?? false,
      dashboardPortOverride: map['dashboard_port'] as int?,
      dashboardPrefix: map['dashboard_prefix'] as String?,
      dashboardProxied: (map['dashboard_proxied'] as bool?) ?? false,
      dashboardUsername: nonEmpty(map['dashboard_username']),
      dashboardPassword: nonEmpty(map['dashboard_password']),
      gatewayPort: map['port'] as int?,
      apiKey: (map['api_key'] as String?) ?? '',
      gatewayPrefix: map['gateway_prefix'] as String?,
    );
  }

  /// Returns a copy with the given fields replaced. Pass `clear*` flags to
  /// explicitly null out optional fields (since null args can't distinguish
  /// "leave unchanged" from "clear").
  SavedConnection copyWith({
    String? label,
    String? host,
    bool? useHttps,
    int? dashboardPortOverride,
    String? dashboardPrefix,
    bool? dashboardProxied,
    String? dashboardUsername,
    String? dashboardPassword,
    int? gatewayPort,
    String? apiKey,
    String? gatewayPrefix,
    bool clearDashboardPort = false,
    bool clearDashboardPrefix = false,
    bool clearDashboardUsername = false,
    bool clearDashboardPassword = false,
    bool clearGatewayPort = false,
    bool clearGatewayPrefix = false,
  }) {
    return SavedConnection(
      id: id,
      label: label ?? this.label,
      host: host ?? this.host,
      useHttps: useHttps ?? this.useHttps,
      dashboardPortOverride: clearDashboardPort
          ? null
          : (dashboardPortOverride ?? this.dashboardPortOverride),
      dashboardPrefix: clearDashboardPrefix
          ? null
          : (dashboardPrefix ?? this.dashboardPrefix),
      dashboardProxied: dashboardProxied ?? this.dashboardProxied,
      dashboardUsername: clearDashboardUsername
          ? null
          : (dashboardUsername ?? this.dashboardUsername),
      dashboardPassword: clearDashboardPassword
          ? null
          : (dashboardPassword ?? this.dashboardPassword),
      gatewayPort: clearGatewayPort ? null : (gatewayPort ?? this.gatewayPort),
      apiKey: apiKey ?? this.apiKey,
      gatewayPrefix: clearGatewayPrefix
          ? null
          : (gatewayPrefix ?? this.gatewayPrefix),
    );
  }
}
