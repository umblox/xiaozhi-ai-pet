import 'dart:math';
import 'package:flutter/material.dart';
import '../models/pet_models.dart';

class HandsAndStagePainter {
  /// Menggambar sorotan lampu panggung (Spotlight) untuk mode Vokalis
  static void drawStageSpotlight(
    Canvas canvas,
    Size size,
    Color faceColor,
    double beatValue,
  ) {
    final spotPath = Path()
      ..moveTo(size.width * 0.35, 0)
      ..lineTo(size.width * 0.65, 0)
      ..lineTo(size.width * 0.92, size.height)
      ..lineTo(size.width * 0.08, size.height)
      ..close();
    canvas.drawPath(
      spotPath,
      Paint()..color = faceColor.withOpacity(0.08 + beatValue * 0.06),
    );
  }

  /// Menggambar Headphone Neon besar di kepala Pet saat mode DJ
  static void drawDjHeadphones(
    Canvas canvas,
    Size size,
    Color faceColor,
    Paint fillPaint,
    Paint glowPaint,
    double beatValue,
  ) {
    final bandPaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    final arcRect = Rect.fromCenter(
      center: Offset(size.width * 0.5, size.height * 0.36),
      width: size.width * 0.72,
      height: size.height * 0.55,
    );
    canvas.drawArc(arcRect, pi * 1.05, pi * 0.9, false, glowPaint);
    canvas.drawArc(arcRect, pi * 1.05, pi * 0.9, false, bandPaint);

    final double cupPulse = 4.0 * beatValue;
    final leftCup = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width * 0.12, size.height * 0.38),
        width: 26 + cupPulse,
        height: 64 + cupPulse,
      ),
      const Radius.circular(14),
    );
    final rightCup = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width * 0.88, size.height * 0.38),
        width: 26 + cupPulse,
        height: 64 + cupPulse,
      ),
      const Radius.circular(14),
    );
    canvas.drawRRect(leftCup, glowPaint);
    canvas.drawRRect(leftCup, fillPaint);
    canvas.drawRRect(rightCup, glowPaint);
    canvas.drawRRect(rightCup, fillPaint);
  }

  /// Menggambar instrumen musik (DJ / Gitar / Piano / Vokal) beserta gerakan tangan musisi
  static void drawMusicianStageAndHands(
    Canvas canvas,
    Size size, {
    required MusicianMode musicianMode,
    required Color faceColor,
    required Paint fillPaint,
    required Paint glowPaint,
    required double handAnimValue,
    required double beatValue,
  }) {
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;

    switch (musicianMode) {
      case MusicianMode.dj:
        final deckRect = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(size.width * 0.5, size.height * 0.88),
            width: size.width * 0.84,
            height: 58,
          ),
          const Radius.circular(16),
        );
        canvas.drawRRect(
          deckRect,
          Paint()..color = Colors.white.withOpacity(0.08),
        );
        canvas.drawRRect(deckRect, strokePaint);

        for (int i = 0; i < 7; i++) {
          final double barH =
              10.0 + ((sin((beatValue + i * 0.3) * pi * 2) + 1) * 14);
          final double bx = size.width * 0.38 + (i * 14.0);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(bx, size.height * 0.88),
                width: 8,
                height: barH,
              ),
              const Radius.circular(4),
            ),
            Paint()
              ..color = i.isEven ? Colors.cyanAccent : Colors.pinkAccent,
          );
        }

        final leftDisc = Offset(size.width * 0.24, size.height * 0.88);
        final rightDisc = Offset(size.width * 0.76, size.height * 0.88);
        canvas.drawCircle(leftDisc, 24, strokePaint);
        canvas.drawCircle(leftDisc, 8, fillPaint);
        canvas.drawCircle(rightDisc, 24, strokePaint);
        canvas.drawCircle(rightDisc, 8, fillPaint);

        drawPalmWithFingers(
          canvas,
          Offset(size.width * 0.14, size.height * 0.44),
          fillPaint,
          glowPaint,
          fingerAngles: [0.2, 0.5],
          fingerLengths: [18, 18],
        );
        final double scratchShift = (handAnimValue - 0.5) * 26;
        drawPalmWithFingers(
          canvas,
          Offset(size.width * 0.76 + scratchShift, size.height * 0.82),
          fillPaint,
          glowPaint,
          fingerAngles: [2.8, 3.1, 3.4],
          fingerLengths: [20, 22, 20],
        );
        break;

      case MusicianMode.guitar:
        final bodyCenter = Offset(size.width * 0.38, size.height * 0.84);
        final neckEnd = Offset(size.width * 0.88, size.height * 0.64);

        final neckPaint = Paint()
          ..color = faceColor
          ..strokeWidth = 16
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(bodyCenter, neckEnd, glowPaint);
        canvas.drawLine(bodyCenter, neckEnd, neckPaint);

        final guitarBody = RRect.fromRectAndRadius(
          Rect.fromCenter(center: bodyCenter, width: 96, height: 52),
          const Radius.circular(24),
        );
        canvas.drawRRect(guitarBody, glowPaint);
        canvas.drawRRect(guitarBody, fillPaint);
        canvas.drawCircle(
          bodyCenter,
          14,
          Paint()..color = Colors.black.withOpacity(0.7),
        );

        final double strumY = (beatValue - 0.5) * 28;
        drawPalmWithFingers(
          canvas,
          Offset(bodyCenter.dx - 10, bodyCenter.dy - 12 + strumY),
          fillPaint,
          glowPaint,
          fingerAngles: [2.6, 3.0, 3.3],
          fingerLengths: [20, 22, 18],
        );

        final double chordSlide = (handAnimValue - 0.5) * 24;
        drawPalmWithFingers(
          canvas,
          Offset(size.width * 0.72 + chordSlide, size.height * 0.70),
          fillPaint,
          glowPaint,
          fingerAngles: [-0.3, 0.0, 0.3],
          fingerLengths: [20, 22, 20],
        );
        break;

      case MusicianMode.piano:
        final double pianoTop = size.height * 0.82;
        final double pianoWidth = size.width * 0.84;
        final double startX = size.width * 0.08;
        const int keyCount = 10;
        final double keyW = pianoWidth / keyCount;

        for (int i = 0; i < keyCount; i++) {
          final bool isPressed =
              ((beatValue * keyCount).floor() % keyCount) == i ||
                  (((1.0 - handAnimValue) * keyCount).floor() % keyCount) == i;
          final keyRect = RRect.fromRectAndRadius(
            Rect.fromLTWH(
              startX + i * keyW + 2,
              pianoTop,
              keyW - 4,
              isPressed ? 42 : 48,
            ),
            const Radius.circular(6),
          );
          canvas.drawRRect(
            keyRect,
            Paint()
              ..color =
                  isPressed ? faceColor : Colors.white.withOpacity(0.85),
          );
        }

        final double leftHandX =
            size.width * 0.28 + sin(handAnimValue * pi * 2) * 38;
        final double rightHandX =
            size.width * 0.72 + cos(beatValue * pi * 2) * 38;
        drawPalmWithFingers(
          canvas,
          Offset(leftHandX, pianoTop - 10 + (beatValue * 8)),
          fillPaint,
          glowPaint,
          fingerAngles: [2.7, 3.0, 3.3, 3.6],
          fingerLengths: [20, 24, 24, 18],
        );
        drawPalmWithFingers(
          canvas,
          Offset(rightHandX, pianoTop - 10 + ((1 - beatValue) * 8)),
          fillPaint,
          glowPaint,
          fingerAngles: [2.7, 3.0, 3.3, 3.6],
          fingerLengths: [20, 24, 24, 18],
        );
        break;

      case MusicianMode.vocal:
        final micHead = Offset(size.width * 0.56, size.height * 0.78);
        final standBottom = Offset(size.width * 0.62, size.height * 0.98);
        canvas.drawLine(
          micHead,
          standBottom,
          Paint()
            ..color = Colors.white70
            ..strokeWidth = 6
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawOval(
          Rect.fromCenter(center: micHead, width: 28, height: 34),
          glowPaint,
        );
        canvas.drawOval(
          Rect.fromCenter(center: micHead, width: 28, height: 34),
          fillPaint,
        );

        drawPalmWithFingers(
          canvas,
          micHead.translate(18, 12),
          fillPaint,
          glowPaint,
          fingerAngles: [-1.2, -1.5],
          fingerLengths: [18, 18],
        );
        drawPalmWithFingers(
          canvas,
          Offset(
            size.width * 0.14,
            size.height * 0.52 + (beatValue - 0.5) * 24,
          ),
          fillPaint,
          glowPaint,
          fingerAngles: [-0.4, -0.1, 0.2, 0.45],
          fingerLengths: [22, 26, 25, 20],
          rotation: (handAnimValue - 0.5) * 0.5,
        );
        break;

      case MusicianMode.none:
        break;
    }
  }

  /// Menggambar tangan & jari robot ekspresif saat mode normal (non-konser)
  static void drawExpressiveHands(
    Canvas canvas,
    Size size, {
    required HandGesture handGesture,
    required double handAnimValue,
    required Paint fillPaint,
    required Paint glowPaint,
  }) {
    if (handGesture == HandGesture.none) return;

    final double bounce = (handAnimValue - 0.5) * 16;

    switch (handGesture) {
      case HandGesture.highFive:
        final palm = Offset(size.width * 0.5, size.height * 0.56);
        drawPalmWithFingers(
          canvas,
          palm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.65, -0.32, 0.0, 0.32, 0.65],
          fingerLengths: [28, 36, 40, 36, 28],
          palmScale: 1.45,
        );
        break;

      case HandGesture.wave:
        final palm = Offset(size.width * 0.88, size.height * 0.48 + bounce);
        drawPalmWithFingers(
          canvas,
          palm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.45, -0.15, 0.12, 0.38],
          fingerLengths: [22, 26, 25, 20],
          rotation: (handAnimValue - 0.5) * 0.45,
        );
        break;

      case HandGesture.peace:
        final palm =
            Offset(size.width * 0.88, size.height * 0.50 + bounce * 0.5);
        drawPalmWithFingers(
          canvas,
          palm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.24, 0.22],
          fingerLengths: [32, 32],
          rotation: -0.1,
        );
        break;

      case HandGesture.thumbsUp:
        final palm =
            Offset(size.width * 0.86, size.height * 0.52 + bounce * 0.4);
        drawPalmWithFingers(
          canvas,
          palm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.85],
          fingerLengths: [30],
        );
        break;

      case HandGesture.thinkingChin:
        final palm = Offset(
          size.width * 0.62,
          size.height * 0.80 + (handAnimValue * 5),
        );
        drawPalmWithFingers(
          canvas,
          palm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.35],
          fingerLengths: [26],
        );
        break;

      case HandGesture.angryFists:
        final shake = sin(handAnimValue * pi * 4) * 6;
        final leftFist = Offset(size.width * 0.12 + shake, size.height * 0.56);
        final rightFist = Offset(size.width * 0.88 - shake, size.height * 0.56);
        drawPalmWithFingers(
          canvas,
          leftFist,
          fillPaint,
          glowPaint,
          fingerAngles: [],
          fingerLengths: [],
        );
        drawPalmWithFingers(
          canvas,
          rightFist,
          fillPaint,
          glowPaint,
          fingerAngles: [],
          fingerLengths: [],
        );
        break;

      case HandGesture.coverCheeks:
        final leftPalm =
            Offset(size.width * 0.15, size.height * 0.54 + bounce * 0.3);
        final rightPalm =
            Offset(size.width * 0.85, size.height * 0.54 + bounce * 0.3);
        drawPalmWithFingers(
          canvas,
          leftPalm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.2, 0.0, 0.2],
          fingerLengths: [18, 20, 18],
        );
        drawPalmWithFingers(
          canvas,
          rightPalm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.2, 0.0, 0.2],
          fingerLengths: [18, 20, 18],
        );
        break;

      case HandGesture.handsUp:
        final leftUp =
            Offset(size.width * 0.12, size.height * 0.22 + bounce * 0.6);
        final rightUp =
            Offset(size.width * 0.88, size.height * 0.22 + bounce * 0.6);
        drawPalmWithFingers(
          canvas,
          leftUp,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.4, -0.12, 0.15, 0.4],
          fingerLengths: [22, 25, 25, 20],
        );
        drawPalmWithFingers(
          canvas,
          rightUp,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.4, -0.12, 0.15, 0.4],
          fingerLengths: [22, 25, 25, 20],
        );
        break;

      case HandGesture.deadDrop:
        final leftDead = Offset(size.width * 0.16, size.height * 0.78);
        final rightDead = Offset(size.width * 0.84, size.height * 0.78);
        drawPalmWithFingers(
          canvas,
          leftDead,
          fillPaint,
          glowPaint,
          fingerAngles: [2.8, 3.1, 3.4],
          fingerLengths: [18, 20, 18],
        );
        drawPalmWithFingers(
          canvas,
          rightDead,
          fillPaint,
          glowPaint,
          fingerAngles: [2.8, 3.1, 3.4],
          fingerLengths: [18, 20, 18],
        );
        break;

      case HandGesture.none:
        break;
    }
  }

  static void drawPalmWithFingers(
    Canvas canvas,
    Offset palmCenter,
    Paint fillPaint,
    Paint glowPaint, {
    required List<double> fingerAngles,
    required List<double> fingerLengths,
    double rotation = 0.0,
    double palmScale = 1.0,
  }) {
    canvas.save();
    canvas.translate(palmCenter.dx, palmCenter.dy);
    canvas.rotate(rotation);
    canvas.scale(palmScale);

    final palmRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 36, height: 32),
      const Radius.circular(14),
    );
    canvas.drawRRect(palmRect, glowPaint);
    canvas.drawRRect(palmRect, fillPaint);

    final fingerStroke = Paint()
      ..color = fillPaint.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8.5
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < fingerAngles.length; i++) {
      final double ang = fingerAngles[i] - (pi / 2);
      final double len = fingerLengths[i];
      final start = Offset(cos(ang) * 14, sin(ang) * 14);
      final end = Offset(cos(ang) * (14 + len), sin(ang) * (14 + len));
      canvas.drawLine(start, end, fingerStroke);
    }

    canvas.restore();
  }
}
