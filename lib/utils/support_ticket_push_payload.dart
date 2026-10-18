/// Payload helpers for admin "support ticket" pushes.
///
/// The `onSupportTicketCreated` / `onSupportCommentCreated` Cloud Functions
/// send FCM data `{type: 'support_ticket', requestId, kind}`. On Android the
/// foreground copy is a local notification whose payload is
/// [localPayloadFor]; both forms resolve to the ticket id to open.
class SupportTicketPushPayload {
  SupportTicketPushPayload._();

  static const type = 'support_ticket';
  static const _localPrefix = '$type:';

  /// Ticket id from FCM `data`, or null when it is not a support ticket push.
  static String? requestIdFromData(Map<String, dynamic> data) {
    if (data['type'] != type) return null;
    final id = data['requestId'];
    if (id is! String) return null;
    final trimmed = id.trim();
    return trimmed.isEmpty || trimmed.contains('/') ? null : trimmed;
  }

  /// Local notification payload for a ticket id.
  static String localPayloadFor(String requestId) => '$_localPrefix$requestId';

  /// Ticket id from a local notification payload, or null.
  static String? requestIdFromLocalPayload(String? payload) {
    if (payload == null || !payload.startsWith(_localPrefix)) return null;
    return requestIdFromData({
      'type': type,
      'requestId': payload.substring(_localPrefix.length),
    });
  }
}
