import 'package:flutter/widgets.dart';

/// Reverse ListView: offset 0 is the latest messages (visual bottom).
const double kChatPinnedToLatestEpsilon = 0.5;

/// Distance from offset 0 at which we treat the user as back on the latest
/// messages and resume following.
const double kChatResumeFollowPixels = 50;

bool isPinnedToLatest(double pixels) =>
    pixels.abs() <= kChatPinnedToLatestEpsilon;

/// True when the outer chat list — not a nested code block / thinking pane —
/// started a pointer drag. Android overscroll and child scrollables must not
/// count, or follow-new-replies stops for the rest of the stream.
bool isUserDragOnChatList(ScrollNotification notification) {
  if (notification.depth != 0) return false;
  if (notification is ScrollStartNotification) {
    return notification.dragDetails != null;
  }
  if (notification is ScrollUpdateNotification) {
    return notification.dragDetails != null;
  }
  return false;
}

/// Pin back to offset 0 when content growth (streaming markdown) corrects the
/// reverse list away from the latest tokens, unless the user scrolled away.
bool shouldRepinToLatest({
  required bool autoScrollEnabled,
  required bool userScrolled,
  required double pixels,
}) {
  return autoScrollEnabled && !userScrolled && !isPinnedToLatest(pixels);
}

/// "Follow new replies" off: how far to move the reverse list so the view
/// stays still while the newest reply grows. In a `reverse: true` list the
/// bottom edge is the anchor, so a growing reply pushes everything above it
/// up — the latest words stay in view whatever the setting. Shifting by the
/// growth keeps what the user is reading in place.
///
/// Returns 0 (don't move) when following is on, nothing is streaming, a
/// message was added or removed (keep the normal jump to new messages), or
/// the framework already corrected the offset by itself.
double holdViewShift({
  required bool autoScrollEnabled,
  required bool streaming,
  required bool sameMessageCount,
  required double previousMaxExtent,
  required double maxExtent,
  required double previousPixels,
  required double pixels,
}) {
  if (autoScrollEnabled || !streaming || !sameMessageCount) return 0;
  final grew = maxExtent - previousMaxExtent;
  if (grew <= 0.5) return 0;
  // Already compensated (e.g. offscreen growth corrected by the sliver).
  if ((pixels - previousPixels).abs() > 0.5) return 0;
  return grew;
}

