import 'dart:math';
import 'package:flutter/material.dart';
import '../models/pet_models.dart';
import 'hands_and_stage_painter.dart';

class EmoRobotFaceAndHandsPainter extends CustomPainter {
  final XiaoZhiEmotion emotion;
  final HandGesture handGesture;
  final MusicianMode musicianMode;
  final double blinkValue;
  final bool isTalking;
  final double talkValue;
  final double handAnimValue;
  final double beatValue;
  final bool isCrossEyed;
  final Offset gazeOffset;
  final Color faceColor;

  EmoRobotFaceAndHandsPainter({
    required this.emotion,
    required this.handGesture,
    required this.musicianMode,
    required this.blinkValue,
    required this.isTalking,
    required this.talkValue,
    required this.handAnimValue,
    required this.beatValue,
    required this.isCrossEyed,
    required this.gazeOffset,
    required this.faceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.fill;

    final glowPaint = Paint()
      ..color = faceColor.withOpacity(0.32)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);

    double eyeWidth = 64;
    double eyeHeight = 76 * (1.0 - blinkValue * 0.92);

    final gazeShift = Offset(gazeOffset.dx * 16, gazeOffset.dy * 12);
    final Offset leftCross = isCrossEyed ? const Offset(22, 6) : Offset.zero;
    final Offset rightCross = isCrossEyed ? const Offset(-22, 6) : Offset.zero;

    final leftCenter =
        Offset(size.width * 0.30, size.height * 0.38) + gazeShift + leftCross;
    final rightCenter =
        Offset(size.width * 0.70, size.height * 0.38) + gazeShift + rightCross;

    if (musicianMode == MusicianMode.vocal) {
      HandsAndStagePainter.drawStageSpotlight(
        canvas,
        size,
        faceColor,
        beatValue,
      );
    }

    if (musicianMode == MusicianMode.dj) {
      HandsAndStagePainter.drawDjHeadphones(
        canvas,
        size,
        faceColor,
        paint,
        glowPaint,
        beatValue,
      );
    }

    if (emotion == XiaoZhiEmotion.dead) {
      final haloCenter = Offset(size.width * 0.5, size.height * 0.09);
      final haloGlow = Paint()
        ..color = Colors.amberAccent.withOpacity(0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      final haloStroke = Paint()
        ..color = Colors.amberAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5;
      canvas.drawOval(
        Rect.fromCenter(center: haloCenter, width: 110, height: 24),
        haloGlow,
      );
      canvas.drawOval(
        Rect.fromCenter(center: haloCenter, width: 110, height: 24),
        haloStroke,
      );
    }

    _drawEyebrows(canvas, leftCenter, rightCenter, eyeWidth);
    _drawCustomEye(
      canvas,
      leftCenter,
      eyeWidth,
      eyeHeight,
      paint,
      glowPaint,
      true,
    );
    _drawCustomEye(
      canvas,
      rightCenter,
      eyeWidth,
      eyeHeight,
      paint,
      glowPaint,
      false,
    );

    if (emotion == XiaoZhiEmotion.loving ||
        emotion == XiaoZhiEmotion.kissy ||
        emotion == XiaoZhiEmotion.happy ||
        emotion == XiaoZhiEmotion.embarrassed ||
        emotion == XiaoZhiEmotion.delicious) {
      final blushPaint = Paint()
        ..color = Colors.pinkAccent.withOpacity(0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      canvas.drawOval(
        Rect.fromCenter(
          center: leftCenter.translate(-18, 48),
          width: 34,
          height: 16,
        ),
        blushPaint,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: rightCenter.translate(18, 48),
          width: 34,
          height: 16,
        ),
        blushPaint,
      );
    }

    if (emotion == XiaoZhiEmotion.crying) {
      final tearPaint = Paint()..color = Colors.lightBlueAccent;
      final double tearOffset = handAnimValue * 10;
      canvas.drawOval(
        Rect.fromCenter(
          center: leftCenter.translate(-6, 50 + tearOffset),
          width: 12,
          height: 22,
        ),
        tearPaint,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: rightCenter.translate(6, 50 + tearOffset),
          width: 12,
          height: 22,
        ),
        tearPaint,
      );
    }

    if (emotion == XiaoZhiEmotion.cool ||
        musicianMode == MusicianMode.dj ||
        musicianMode == MusicianMode.guitar) {
      final bridgePaint = Paint()
        ..color = faceColor
        ..strokeWidth = 6
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        leftCenter.translate(30, -8),
        rightCenter.translate(-30, -8),
        bridgePaint,
      );
    }

    _drawMouth(canvas, size, gazeShift * 0.5);

    if (musicianMode != MusicianMode.none) {
      HandsAndStagePainter.drawMusicianStageAndHands(
        canvas,
        size,
        musicianMode: musicianMode,
        faceColor: faceColor,
        fillPaint: paint,
        glowPaint: glowPaint,
        handAnimValue: handAnimValue,
        beatValue: beatValue,
      );
    } else {
      HandsAndStagePainter.drawExpressiveHands(
        canvas,
        size,
        handGesture: handGesture,
        handAnimValue: handAnimValue,
        fillPaint: paint,
        glowPaint: glowPaint,
      );
    }
  }

  void _drawEyebrows(
    Canvas canvas,
    Offset leftEye,
    Offset rightEye,
    double eyeW,
  ) {
    final browPaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7.5
      ..strokeCap = StrokeCap.round;

    double leftOuterY = -52;
    double leftInnerY = -52;
    double rightInnerY = -52;
    double rightOuterY = -52;

    switch (emotion) {
      case XiaoZhiEmotion.angry:
        leftOuterY = -60;
        leftInnerY = -38;
        rightInnerY = -38;
        rightOuterY = -60;
        break;
      case XiaoZhiEmotion.confident:
      case XiaoZhiEmotion.cool:
        leftOuterY = -54;
        leftInnerY = -44;
        rightInnerY = -50;
        rightOuterY = -64;
        break;
      case XiaoZhiEmotion.sad:
      case XiaoZhiEmotion.crying:
      case XiaoZhiEmotion.embarrassed:
        leftOuterY = -40;
        leftInnerY = -58;
        rightInnerY = -58;
        rightOuterY = -40;
        break;
      case XiaoZhiEmotion.thinking:
      case XiaoZhiEmotion.confused:
        leftOuterY = -48;
        leftInnerY = -48;
        rightInnerY = -66;
        rightOuterY = -62;
        break;
      case XiaoZhiEmotion.surprised:
      case XiaoZhiEmotion.shocked:
        leftOuterY = -66;
        leftInnerY = -70;
        rightInnerY = -70;
        rightOuterY = -66;
        break;
      case XiaoZhiEmotion.happy:
      case XiaoZhiEmotion.laughing:
      case XiaoZhiEmotion.loving:
      case XiaoZhiEmotion.winking:
        leftOuterY = -56;
        leftInnerY = -60;
        rightInnerY = -60;
        rightOuterY = -56;
        break;
      case XiaoZhiEmotion.sleepy:
      case XiaoZhiEmotion.dead:
        leftOuterY = -42;
        leftInnerY = -46;
        rightInnerY = -46;
        rightOuterY = -42;
        break;
      default:
        leftOuterY = -52;
        leftInnerY = -52;
        rightInnerY = -52;
        rightOuterY = -52;
        break;
    }

    final leftPath = Path()
      ..moveTo(leftEye.dx - eyeW * 0.48, leftEye.dy + leftOuterY)
      ..quadraticBezierTo(
        leftEye.dx,
        leftEye.dy + ((leftOuterY + leftInnerY) / 2) - 6,
        leftEye.dx + eyeW * 0.48,
        leftEye.dy + leftInnerY,
      );

    final rightPath = Path()
      ..moveTo(rightEye.dx - eyeW * 0.48, rightEye.dy + rightInnerY)
      ..quadraticBezierTo(
        rightEye.dx,
        rightEye.dy + ((rightInnerY + rightOuterY) / 2) - 6,
        rightEye.dx + eyeW * 0.48,
        rightEye.dy + rightOuterY,
      );

    canvas.drawPath(leftPath, browPaint);
    canvas.drawPath(rightPath, browPaint);
  }

  void _drawCustomEye(
    Canvas canvas,
    Offset center,
    double w,
    double h,
    Paint paint,
    Paint glowPaint,
    bool isLeft,
  ) {
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;

    if (emotion == XiaoZhiEmotion.dead || emotion == XiaoZhiEmotion.dizzy) {
      double r = 24;
      canvas.drawLine(
        center.translate(-r, -r),
        center.translate(r, r),
        strokePaint,
      );
      canvas.drawLine(
        center.translate(r, -r),
        center.translate(-r, r),
        strokePaint,
      );
      return;
    }

    if ((emotion == XiaoZhiEmotion.winking ||
            emotion == XiaoZhiEmotion.kissy ||
            emotion == XiaoZhiEmotion.silly) &&
        !isLeft &&
        !isCrossEyed) {
      canvas.drawArc(
        Rect.fromCenter(center: center, width: w, height: 25),
        pi,
        pi,
        false,
        strokePaint,
      );
      return;
    }

    if (emotion == XiaoZhiEmotion.happy ||
        emotion == XiaoZhiEmotion.laughing ||
        emotion == XiaoZhiEmotion.funny ||
        emotion == XiaoZhiEmotion.relaxed ||
        emotion == XiaoZhiEmotion.delicious) {
      canvas.drawArc(
        Rect.fromCenter(center: center.translate(0, 10), width: w, height: 50),
        pi,
        pi,
        false,
        strokePaint,
      );
      return;
    }

    if (emotion == XiaoZhiEmotion.loving) {
      final path = Path();
      double s = 32;
      path.moveTo(center.dx, center.dy + s * 0.8);
      path.cubicTo(
        center.dx - s * 1.4,
        center.dy,
        center.dx - s * 0.7,
        center.dy - s * 1.1,
        center.dx,
        center.dy - s * 0.3,
      );
      path.cubicTo(
        center.dx + s * 0.7,
        center.dy - s * 1.1,
        center.dx + s * 1.4,
        center.dy,
        center.dx,
        center.dy + s * 0.8,
      );
      canvas.drawPath(path, glowPaint);
      canvas.drawPath(path, paint);
      return;
    }

    if (emotion == XiaoZhiEmotion.sleepy) {
      h *= 0.22;
    } else if (emotion == XiaoZhiEmotion.surprised ||
        emotion == XiaoZhiEmotion.shocked) {
      w = 70;
      h = 70 * (1.0 - blinkValue * 0.9);
    } else if (emotion == XiaoZhiEmotion.confused && isLeft) {
      h *= 0.62;
    } else if (emotion == XiaoZhiEmotion.cool ||
        musicianMode == MusicianMode.dj ||
        musicianMode == MusicianMode.guitar) {
      h *= 0.66;
    }

    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: w, height: h),
      Radius.circular(
        (emotion == XiaoZhiEmotion.surprised ||
                emotion == XiaoZhiEmotion.shocked)
            ? 40
            : 22,
      ),
    );
    canvas.drawRRect(rect, glowPaint);
    canvas.drawRRect(rect, paint);

    final maskPaint = Paint()..color = Colors.black;
    if (emotion == XiaoZhiEmotion.angry ||
        emotion == XiaoZhiEmotion.confident) {
      final path = Path();
      if (isLeft) {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - 5);
        path.lineTo(center.dx - w, center.dy - h * 0.55);
      } else {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h * 0.55);
        path.lineTo(center.dx - w, center.dy - 5);
      }
      path.close();
      canvas.drawPath(path, maskPaint);
    } else if (emotion == XiaoZhiEmotion.sad ||
        emotion == XiaoZhiEmotion.crying ||
        emotion == XiaoZhiEmotion.embarrassed) {
      final path = Path();
      if (isLeft) {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h * 0.55);
        path.lineTo(center.dx - w, center.dy - 5);
      } else {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - 5);
        path.lineTo(center.dx - w, center.dy - h * 0.55);
      }
      path.close();
      canvas.drawPath(path, maskPaint);
    }
  }

  void _drawMouth(Canvas canvas, Size size, Offset shift) {
    final mouthCenter = Offset(size.width * 0.5, size.height * 0.66) + shift;
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.fill;

    if (isTalking && emotion != XiaoZhiEmotion.dead) {
      final double openHeight = 10.0 + (talkValue * 28.0);
      final double openWidth = 42.0 + (talkValue * 14.0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: mouthCenter,
            width: openWidth,
            height: openHeight,
          ),
          const Radius.circular(18),
        ),
        fillPaint,
      );
      return;
    }

    switch (emotion) {
      case XiaoZhiEmotion.dead:
        canvas.drawLine(
          mouthCenter.translate(-26, 2),
          mouthCenter.translate(26, -2),
          strokePaint,
        );
        final tonguePaint = Paint()..color = Colors.pinkAccent;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: mouthCenter.translate(8, 14),
              width: 18,
              height: 22,
            ),
            const Radius.circular(9),
          ),
          tonguePaint,
        );
        break;

      case XiaoZhiEmotion.laughing:
      case XiaoZhiEmotion.funny:
        final path = Path()
          ..moveTo(mouthCenter.dx - 32, mouthCenter.dy - 6)
          ..lineTo(mouthCenter.dx + 32, mouthCenter.dy - 6)
          ..arcToPoint(
            Offset(mouthCenter.dx - 32, mouthCenter.dy - 6),
            radius: const Radius.circular(32),
            clockwise: true,
          )
          ..close();
        canvas.drawPath(path, fillPaint);
        break;

      case XiaoZhiEmotion.happy:
      case XiaoZhiEmotion.loving:
      case XiaoZhiEmotion.winking:
      case XiaoZhiEmotion.relaxed:
      case XiaoZhiEmotion.confident:
      case XiaoZhiEmotion.cool:
        canvas.drawArc(
          Rect.fromCenter(
            center: mouthCenter.translate(0, -6),
            width: 58,
            height: 34,
          ),
          0,
          pi,
          false,
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.delicious:
      case XiaoZhiEmotion.silly:
        canvas.drawArc(
          Rect.fromCenter(
            center: mouthCenter.translate(0, -6),
            width: 56,
            height: 30,
          ),
          0,
          pi,
          false,
          strokePaint,
        );
        final tonguePaint = Paint()..color = Colors.pinkAccent;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: mouthCenter.translate(6, 12),
              width: 20,
              height: 22,
            ),
            const Radius.circular(10),
          ),
          tonguePaint,
        );
        break;

      case XiaoZhiEmotion.kissy:
        canvas.drawOval(
          Rect.fromCenter(center: mouthCenter, width: 20, height: 22),
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.angry:
      case XiaoZhiEmotion.sad:
      case XiaoZhiEmotion.crying:
        canvas.drawArc(
          Rect.fromCenter(
            center: mouthCenter.translate(0, 14),
            width: 50,
            height: 28,
          ),
          pi,
          pi,
          false,
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.surprised:
      case XiaoZhiEmotion.shocked:
      case XiaoZhiEmotion.dizzy:
        canvas.drawOval(
          Rect.fromCenter(center: mouthCenter, width: 30, height: 34),
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.thinking:
      case XiaoZhiEmotion.confused:
      case XiaoZhiEmotion.embarrassed:
        canvas.drawLine(
          mouthCenter.translate(-22, 4),
          mouthCenter.translate(22, -4),
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.sleepy:
        canvas.drawOval(
          Rect.fromCenter(center: mouthCenter, width: 16, height: 16),
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.neutral:
        canvas.drawArc(
          Rect.fromCenter(
            center: mouthCenter.translate(0, -4),
            width: 42,
            height: 18,
          ),
          0,
          pi,
          false,
          strokePaint,
        );
        break;
    }
  }

  @override
  bool shouldRepaint(covariant EmoRobotFaceAndHandsPainter oldDelegate) => true;
}

class ScreenCrackPainter extends CustomPainter {
  final Offset origin;
  final List<List<Offset>> branches;

  ScreenCrackPainter({required this.origin, required this.branches});

  @override
  void paint(Canvas canvas, Size size) {
    final glowPaint = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final crackPaint = Paint()
      ..color = Colors.white.withOpacity(0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(origin, 10, glowPaint);
    canvas.drawCircle(origin, 6, Paint()..color = Colors.white);

    canvas.drawCircle(origin, 28, crackPaint);
    canvas.drawCircle(origin, 58, crackPaint..strokeWidth = 1.4);

    for (final branch in branches) {
      if (branch.length < 2) continue;
      final path = Path()..moveTo(branch.first.dx, branch.first.dy);
      for (int i = 1; i < branch.length; i++) {
        path.lineTo(branch[i].dx, branch[i].dy);
      }
      canvas.drawPath(path, glowPaint);
      canvas.drawPath(path, crackPaint..strokeWidth = 2.2);
    }
  }

  @override
  bool shouldRepaint(covariant ScreenCrackPainter oldDelegate) => true;
}
