import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/utils/support_ticket_push_payload.dart';

void main() {
  group('SupportTicketPushPayload.requestIdFromData', () {
    test('reads the ticket id from a support push', () {
      expect(
        SupportTicketPushPayload.requestIdFromData({
          'type': 'support_ticket',
          'requestId': 'abc123',
          'kind': 'comment',
        }),
        'abc123',
      );
    });

    test('trims whitespace', () {
      expect(
        SupportTicketPushPayload.requestIdFromData(
            {'type': 'support_ticket', 'requestId': '  abc  '}),
        'abc',
      );
    });

    test('ignores other push types', () {
      expect(
        SupportTicketPushPayload.requestIdFromData(
            {'type': 'ops_alert', 'requestId': 'abc'}),
        isNull,
      );
      expect(SupportTicketPushPayload.requestIdFromData({}), isNull);
    });

    test('rejects missing, empty, non-string or path-like ids', () {
      for (final id in <Object?>[null, '', '   ', 42, 'a/b']) {
        expect(
          SupportTicketPushPayload.requestIdFromData(
              {'type': 'support_ticket', 'requestId': id}),
          isNull,
          reason: 'id: $id',
        );
      }
    });
  });

  group('SupportTicketPushPayload local payload', () {
    test('round-trips a ticket id', () {
      final payload = SupportTicketPushPayload.localPayloadFor('xyz');
      expect(payload, 'support_ticket:xyz');
      expect(SupportTicketPushPayload.requestIdFromLocalPayload(payload), 'xyz');
    });

    test('ignores unrelated or empty payloads', () {
      expect(SupportTicketPushPayload.requestIdFromLocalPayload(null), isNull);
      expect(SupportTicketPushPayload.requestIdFromLocalPayload(''), isNull);
      expect(
          SupportTicketPushPayload.requestIdFromLocalPayload('premium'), isNull);
      expect(
        SupportTicketPushPayload.requestIdFromLocalPayload('support_ticket:'),
        isNull,
      );
    });
  });
}
