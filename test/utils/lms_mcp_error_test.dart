import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/utils/lms_mcp_error.dart';

void main() {
  const playwrightDump =
      "Unable to get plugin tools for 'mcp/playwright'. Unable to get plugin "
      "tools for plugin identifier 'mcp/playwright'. Error: Cannot find plugin "
      'handle for plugin: mcp/playwright';

  group('LmsMcpError', () {
    test('playwright plugin_connection_error is not Pro Search', () {
      expect(
        LmsMcpError.isUnrecognizedPlugin(
          playwrightDump,
          errorType: 'plugin_connection_error',
        ),
        isTrue,
      );
      expect(
        LmsMcpError.shouldWaitForChatEnd(
          playwrightDump,
          errorType: 'plugin_connection_error',
        ),
        isTrue,
      );
      expect(LmsMcpError.pluginIds(playwrightDump), ['playwright']);
      expect(LmsMcpError.displayName('mcp/playwright'), 'Playwright');
      final message = LmsMcpError.userMessage(
        playwrightDump,
        errorType: 'plugin_connection_error',
      );
      expect(
        message,
        'LM Studio rejected MCP/Playwright. Make sure this MCP is defined in LM Studio as well.',
      );
      expect(message.toLowerCase(), isNot(contains('pro search')));
    });

    test('keeps all-caps plugin ids', () {
      expect(LmsMcpError.displayName('mcp/TTS'), 'TTS');
      expect(
        LmsMcpError.unrecognizedUserMessageFor(
          'Cannot find plugin handle for plugin: mcp/TTS',
        ),
        contains('LM Studio rejected MCP/TTS.'),
      );
    });

    test('lists multiple missing plugins', () {
      const dump =
          "Unable to get plugin tools for 'mcp/playwright' and 'mcp/TTS'";
      expect(
        LmsMcpError.unrecognizedUserMessageFor(dump),
        'LM Studio rejected MCP/Playwright and MCP/TTS. Make sure these MCPs are defined in LM Studio as well.',
      );
    });

    test('permission denied plugin tells the user to define it in LM Studio',
        () {
      const dump =
          "Permission denied to use plugin 'mcp/filesystem'. Ensure that the "
          'server configuration allows plugin usage and, if using an API token, '
          'it has the necessary permissions.';
      expect(LmsMcpError.isUnrecognizedPlugin(dump), isTrue);
      expect(LmsMcpError.isProToolFailure(dump), isFalse);
      expect(
        LmsMcpError.userMessage(dump),
        'LM Studio rejected MCP/Filesystem. Make sure this MCP is defined in LM Studio as well.',
      );
      expect(
        LmsMcpError.userMessage(dump, lmStudio: false),
        'The server rejected MCP/Filesystem. Make sure this MCP is defined on the server as well.',
      );
      expect(LmsMcpError.matches(dump), isTrue);
      expect(LmsMcpError.matches(LmsMcpError.userMessage(dump)), isTrue);
    });

    test('ephemeral Pro Search is still Pro Search', () {
      const dump =
          'Failed to connect to remote MCP server lmmini-search (ephemeral_mcp)';
      expect(
        LmsMcpError.isUnrecognizedPlugin(
          dump,
          errorType: 'mcp_connection_error',
        ),
        isFalse,
      );
      expect(
        LmsMcpError.userMessage(dump, errorType: 'mcp_connection_error'),
        LmsMcpError.proSearchUserMessage,
      );
    });

    test('sandbox-only ephemeral error', () {
      const dump = 'lmmini-sandbox allowed_tools run_code failed';
      expect(
        LmsMcpError.userMessage(dump, errorType: 'mcp_connection_error'),
        LmsMcpError.sandboxUserMessage,
      );
    });

    test('named user MCP is not Pro Search', () {
      const dump = "Unable to connect to remote MCP server 'rss-reader' at url "
          "'https://your-rss-reader-api.com'. Error: getaddrinfo ENOTFOUND";
      expect(
        LmsMcpError.remoteServerName(dump),
        'rss-reader',
      );
      expect(
        LmsMcpError.userMessage(dump, errorType: 'mcp_connection_error'),
        contains('Can\'t reach MCP server "rss-reader"'),
      );
      expect(
        LmsMcpError.userMessage(dump, errorType: 'mcp_connection_error')
            .toLowerCase(),
        isNot(contains('pro search')),
      );
      expect(LmsMcpError.matches(dump), isTrue);
    });

    test('Pro Search and Code Sandbox stay reportable', () {
      expect(LmsMcpError.matches(LmsMcpError.proSearchUserMessage), isFalse);
      expect(LmsMcpError.matches(LmsMcpError.sandboxUserMessage), isFalse);
      expect(
        LmsMcpError.matches(
          'Failed to connect to remote MCP server lmmini-search (ephemeral_mcp)',
        ),
        isFalse,
      );
    });
  });

  group('LmsMcpError non-public MCP address', () {
    const raw = "Unable to connect to remote MCP server 'searxng' at url "
        "'http://searxng.h/mcp'. URL resolves to a non-public address. We "
        'only allow public addresses for dynamic remote MCP connections.';

    test('explains that LAN MCPs must be set up in LM Studio', () {
      final msg = LmsMcpError.userMessage(raw,
          errorType: LmsMcpError.mcpConnectionType);
      expect(msg, contains('"searxng"'));
      expect(msg, contains('mcp.json'));
      expect(msg, isNot(contains('Pro Search')));
    });

    test('streaming status reads as unreachable, not Pro Search', () {
      final msg = LmsMcpError.userMessage(raw,
          errorType: LmsMcpError.mcpConnectionType);
      expect(LmsMcpError.streamingStatus(msg), '⚠️ MCP server unreachable...');
    });
  });

  test('per-request MCPs turned off in LM Studio gets a setup hint', () {
    const raw = "Permission denied to use ephemeral MCP server 'lmmini-search' "
        "at URL 'https://mcp.example.com'. Ensure that the server "
        'configuration allows ephemeral MCP connections and, if using an API '
        'token, it has the necessary permissions.';
    expect(LmsMcpError.isPerRequestMcpsBlocked(raw), isTrue);
    expect(LmsMcpError.userMessage(raw), LmsMcpError.perRequestMcpsOffMessage);
    expect(LmsMcpError.userMessage("Remote MCP server 'lmmini-search' failed"),
        LmsMcpError.proSearchUserMessage);
  });
}

