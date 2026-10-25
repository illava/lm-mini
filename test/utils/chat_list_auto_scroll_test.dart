import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/utils/chat_list_auto_scroll.dart';

void main() {
  ScrollMetrics metrics({double pixels = 0}) => FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 800,
        pixels: pixels,
        viewportDimension: 400,
        axisDirection: AxisDirection.up,
        devicePixelRatio: 1,
      );

  Future<BuildContext> contextOf(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(builder: (context) {
      ctx = context;
      return const SizedBox.shrink();
    }));
    return ctx;
  }

  testWidgets('outer list pointer drag pauses follow', (tester) async {
    final ctx = await contextOf(tester);
    final start = ScrollStartNotification(
      metrics: metrics(),
      context: ctx,
      dragDetails: DragStartDetails(globalPosition: Offset.zero),
    );
    expect(isUserDragOnChatList(start), isTrue);

    final update = ScrollUpdateNotification(
      metrics: metrics(pixels: 80),
      context: ctx,
      dragDetails: DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: const Offset(0, -12),
      ),
    );
    expect(isUserDragOnChatList(update), isTrue);
  });

  testWidgets(
      'content-size correction without a drag does not pause follow',
      (tester) async {
    final ctx = await contextOf(tester);
    final metricsOnly = ScrollUpdateNotification(
      metrics: metrics(pixels: 120),
      context: ctx,
    );
    expect(isUserDragOnChatList(metricsOnly), isFalse);
  });

  test('repins when follow is on and reverse list drifted from 0', () {
    expect(
      shouldRepinToLatest(
        autoScrollEnabled: true,
        userScrolled: false,
        pixels: 80,
      ),
      isTrue,
    );
    expect(
      shouldRepinToLatest(
        autoScrollEnabled: true,
        userScrolled: false,
        pixels: 0,
      ),
      isFalse,
    );
    expect(
      shouldRepinToLatest(
        autoScrollEnabled: true,
        userScrolled: true,
        pixels: 80,
      ),
      isFalse,
    );
    expect(
      shouldRepinToLatest(
        autoScrollEnabled: false,
        userScrolled: false,
        pixels: 80,
      ),
      isFalse,
    );
  });

  group('holdViewShift (follow new replies off)', () {
    double shift({
      bool follow = false,
      bool streaming = true,
      bool sameCount = true,
      double prevExtent = 1000,
      double extent = 1040,
      double prevPixels = 0,
      double pixels = 0,
    }) =>
        holdViewShift(
          autoScrollEnabled: follow,
          streaming: streaming,
          sameMessageCount: sameCount,
          previousMaxExtent: prevExtent,
          maxExtent: extent,
          previousPixels: prevPixels,
          pixels: pixels,
        );

    test('moves by the growth so the view stays still', () {
      expect(shift(), 40);
    });

    test('never moves when following is on', () {
      expect(shift(follow: true), 0);
    });

    test('no move when not streaming or a message was added', () {
      expect(shift(streaming: false), 0);
      expect(shift(sameCount: false), 0);
    });

    test('no move when nothing grew or it was already corrected', () {
      expect(shift(extent: 1000), 0);
      expect(shift(pixels: 40), 0);
    });
  });
}

