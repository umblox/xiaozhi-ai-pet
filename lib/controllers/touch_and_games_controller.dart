import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/pet_models.dart';

class TouchAndGamesController {
  final VoidCallback onStateChanged;
  final void Function(String sfxType) onPlaySfx;
  final void Function(String symbol, Color color) onSpawnParticle;
  final void Function(XiaoZhiEmotion emo, {HandGesture? gesture}) onSetEmotion;
  final void Function(
    String prompt, {
    XiaoZhiEmotion? lockEmotion,
    HandGesture? lockGesture,
    int lockSeconds,
  }) onRequestVoiceReaction;
  final void Function(String subtitle) onSetSubtitle;
  final void Function(int seconds) onLockEmotion;
  final XiaoZhiEmotion Function() getCurrentEmotion;
  final MusicianMode Function() getCurrentMusicianMode;
  final VoidCallback onCycleMusicianStyle;
  final VoidCallback onTapCenterFace;

  bool isCrossEyed = false;
  double cheekStretchX = 1.0;
  double tickleShakeOffset = 0.0;
  bool isScreenCracked = false;
  double shootFlashOpacity = 0.0;
  Offset crackOrigin = const Offset(180, 300);
  final List<List<Offset>> crackBranches = [];
  Offset gazeOffset = Offset.zero;

  int _rubCounter = 0;
  int _tickleCounter = 0;
  Timer? _reviveTimer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime _lastShakeTime = DateTime.now();
  DateTime _lastTouchSpeechTime = DateTime.fromMillisecondsSinceEpoch(0);

  TouchAndGamesController({
    required this.onStateChanged,
    required this.onPlaySfx,
    required this.onSpawnParticle,
    required this.onSetEmotion,
    required this.onRequestVoiceReaction,
    required this.onSetSubtitle,
    required this.onLockEmotion,
    required this.getCurrentEmotion,
    required this.getCurrentMusicianMode,
    required this.onCycleMusicianStyle,
    required this.onTapCenterFace,
  });

  void initShakeDetector() {
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      final double gForce =
          sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (gForce > 22.0) {
        final now = DateTime.now();
        if (now.difference(_lastShakeTime).inSeconds > 4) {
          _lastShakeTime = now;
          onSpawnParticle("💫", Colors.yellowAccent);
          onRequestVoiceReaction(
            "Aku barusan goyang-goyangin badan kamu sampai pusing, kamu ngeluh pusing dengan nada manja dong",
            lockEmotion: XiaoZhiEmotion.dizzy,
            lockGesture: HandGesture.handsUp,
            lockSeconds: 5,
          );
        }
      }
    });
  }

  void triggerShootAndDie({Offset? tapPosition, bool askAiToSpeak = true}) {
    _reviveTimer?.cancel();

    final rand = Random();
    final center = tapPosition ?? const Offset(180, 260);
    crackOrigin = center;
    crackBranches.clear();

    for (int i = 0; i < 9; i++) {
      final double baseAngle = (i * (2 * pi / 9)) + (rand.nextDouble() * 0.35);
      final List<Offset> branch = [center];
      Offset curr = center;
      for (int step = 0; step < 5; step++) {
        final double len = 28.0 + rand.nextDouble() * 48.0;
        final double jitter = (rand.nextDouble() - 0.5) * 0.55;
        curr = Offset(
          curr.dx + cos(baseAngle + jitter) * len,
          curr.dy + sin(baseAngle + jitter) * len,
        );
        branch.add(curr);
      }
      crackBranches.add(branch);
    }

    onLockEmotion(6);
    onPlaySfx('shoot_and_die');
    onSpawnParticle("💥", Colors.orangeAccent);

    isScreenCracked = true;
    shootFlashOpacity = 0.85;
    onSetEmotion(XiaoZhiEmotion.shocked, gesture: HandGesture.handsUp);
    onSetSubtitle("💥 DOR!! Aduh... aku tertembak!!");
    onStateChanged();

    if (askAiToSpeak) {
      onRequestVoiceReaction(
        "Dor! Aku barusan nembak kamu dalam permainan tembak-tembakan, kamu akting dramatis kaget ketembak lalu pura-pura mati dengan manja dong",
        lockEmotion: XiaoZhiEmotion.dead,
        lockGesture: HandGesture.deadDrop,
        lockSeconds: 6,
      );
    }

    Future.delayed(const Duration(milliseconds: 140), () {
      shootFlashOpacity = 0.0;
      onStateChanged();
    });

    Future.delayed(const Duration(milliseconds: 650), () {
      onSpawnParticle("👻", Colors.white70);
      onSetEmotion(XiaoZhiEmotion.dead, gesture: HandGesture.deadDrop);
      onSetSubtitle("💀 X_X ... Pura-pura mati... (Ketuk untuk bangunkan)");
      onStateChanged();
    });

    _reviveTimer = Timer(const Duration(milliseconds: 6500), () {
      if (getCurrentEmotion() == XiaoZhiEmotion.dead) {
        reviveFromDead();
      }
    });
  }

  void reviveFromDead() {
    _reviveTimer?.cancel();
    onLockEmotion(0);
    onPlaySfx('revive');
    onSpawnParticle("✨", Colors.greenAccent);
    isScreenCracked = false;
    crackBranches.clear();
    onSetEmotion(XiaoZhiEmotion.happy, gesture: HandGesture.peace);
    onSetSubtitle("Ketuk wajah atau langsung bicara...");
    onStateChanged();
  }

  void clearCracksIfNeeded() {
    if (isScreenCracked) {
      isScreenCracked = false;
      crackBranches.clear();
      onStateChanged();
    }
  }

  void onFaceTapDown(TapDownDetails details, Size faceAreaSize) {
    if (getCurrentEmotion() == XiaoZhiEmotion.dead) {
      reviveFromDead();
      return;
    }

    final local = details.localPosition;
    final centerX = faceAreaSize.width / 2;
    final centerY = faceAreaSize.height / 2;

    final leftEyeCenter = Offset(centerX - 72, centerY - 22);
    final rightEyeCenter = Offset(centerX + 72, centerY - 22);
    final noseCenter = Offset(centerX, centerY - 10);

    // 1. Colok Mata Kiri / Kanan
    if ((local - leftEyeCenter).distance < 42 ||
        (local - rightEyeCenter).distance < 42) {
      onSpawnParticle("💢", Colors.redAccent);
      onSetSubtitle("😠 Aduh! Jangan colok mataku dong!");
      onRequestVoiceReaction(
        "Aduh, aku barusan iseng nyolok mata kamu, kamu protes ngambek dan manja dong karena matamu perih",
        lockEmotion: XiaoZhiEmotion.angry,
        lockGesture: HandGesture.angryFists,
        lockSeconds: 5,
      );
      return;
    }

    // 2. Pencet Hidung (Nose Boop)
    if ((local - noseCenter).distance < 32) {
      onPlaySfx('boop');
      onSpawnParticle("😜", Colors.amberAccent);
      isCrossEyed = true;
      onSetEmotion(XiaoZhiEmotion.silly, gesture: HandGesture.peace);
      onSetSubtitle("😜 Boop! Hidungku dipencet jadi juling nih!");
      onStateChanged();

      Future.delayed(const Duration(seconds: 3), () {
        isCrossEyed = false;
        onStateChanged();
      });

      onRequestVoiceReaction(
        "Aku barusan mencet hidung kamu sampai mata kamu juling, kamu ketawa manja dan gemes dong",
        lockEmotion: XiaoZhiEmotion.silly,
        lockGesture: HandGesture.peace,
        lockSeconds: 4,
      );
      return;
    }

    // 3. Jika sedang konser musik: ketuk bawah untuk ganti alat musik, tengah untuk bicara
    if (getCurrentMusicianMode() != MusicianMode.none &&
        local.dy > centerY + 45) {
      onCycleMusicianStyle();
      return;
    }

    onTapCenterFace();
  }

  void onFaceLongPress() {
    if (getCurrentEmotion() == XiaoZhiEmotion.dead) return;
    onPlaySfx('sleepy');
    onSpawnParticle("💤", Colors.cyanAccent);
    onSetSubtitle("😴 Hoaaam... ngantuk sekali... Zzz...");
    onRequestVoiceReaction(
      "Kamu lagi ngantuk banget nih, menguap manja dan bilang mau bobo sebentar dong",
      lockEmotion: XiaoZhiEmotion.sleepy,
      lockGesture: HandGesture.none,
      lockSeconds: 5,
    );
  }

  void onFacePanUpdate(DragUpdateDetails details, Size faceAreaSize) {
    if (getCurrentEmotion() == XiaoZhiEmotion.dead) return;
    final local = details.localPosition;
    final dx = ((local.dx / faceAreaSize.width) - 0.5) * 2.0;
    final dy = ((local.dy / faceAreaSize.height) - 0.5) * 2.0;

    gazeOffset = Offset(dx.clamp(-1.0, 1.0), dy.clamp(-1.0, 1.0));
    onStateChanged();

    // 4. Elus Dahi / Kepala Atas
    if (dy < -0.18) {
      _rubCounter++;
      if (_rubCounter % 14 == 0) {
        onSpawnParticle("❤️", Colors.pinkAccent);
        onSetSubtitle("😍 Nyaman banget kepalaku dielus-elus...");
        if (DateTime.now().difference(_lastTouchSpeechTime).inSeconds > 6) {
          _lastTouchSpeechTime = DateTime.now();
          onRequestVoiceReaction(
            "Aku lagi elus-elus kepala kamu dengan lembut nih, kamu mendesah nyaman dan respon manja dong",
            lockEmotion: XiaoZhiEmotion.loving,
            lockGesture: HandGesture.coverCheeks,
            lockSeconds: 5,
          );
        } else {
          onSetEmotion(XiaoZhiEmotion.loving, gesture: HandGesture.coverCheeks);
        }
      }
      return;
    }

    // 5. Gelitik Dagu / Perut Bawah
    if (dy > 0.22 && details.delta.dx.abs() > 2.5) {
      _tickleCounter++;
      tickleShakeOffset = (_tickleCounter.isEven ? 9.0 : -9.0);
      onStateChanged();

      if (_tickleCounter % 12 == 0) {
        onSpawnParticle("😆", Colors.amberAccent);
        onSetSubtitle("😆 Hahaha geli tau! Jangan digelitikin!");
        if (DateTime.now().difference(_lastTouchSpeechTime).inSeconds > 6) {
          _lastTouchSpeechTime = DateTime.now();
          onRequestVoiceReaction(
            "Aku lagi gelitikin dagu dan perut kamu nih, kamu ketawa kegelian dan minta ampun dengan manja dong",
            lockEmotion: XiaoZhiEmotion.laughing,
            lockGesture: HandGesture.peace,
            lockSeconds: 5,
          );
        } else {
          onSetEmotion(XiaoZhiEmotion.laughing, gesture: HandGesture.peace);
        }
      }
      return;
    }

    // 6. Tarik Pipi Kiri / Kanan
    if (dx.abs() > 0.42 && dy.abs() < 0.25) {
      cheekStretchX = (1.0 + (dx.abs() - 0.42) * 0.45).clamp(1.0, 1.28);
      onSetEmotion(
        XiaoZhiEmotion.embarrassed,
        gesture: HandGesture.coverCheeks,
      );
      onSetSubtitle("😳 Uwaaa pipiku ditarik-tarik jadi melar!");
      onStateChanged();
    }
  }

  void onFacePanEnd(DragEndDetails details) {
    final bool wasStretchingCheek = cheekStretchX > 1.08;
    _rubCounter = 0;
    _tickleCounter = 0;

    final velocity = details.velocity.pixelsPerSecond.distance;
    if (velocity > 1100 && !wasStretchingCheek) {
      if (getCurrentMusicianMode() != MusicianMode.none) {
        onCycleMusicianStyle();
      } else {
        onPlaySfx('high_five');
        onSpawnParticle("🙌", Colors.cyanAccent);
        onSetSubtitle("🙌 TOS!! High-Five!");
        onRequestVoiceReaction(
          "Kita barusan tos high-five bareng, kamu bersorak senang dan manja dong",
          lockEmotion: XiaoZhiEmotion.happy,
          lockGesture: HandGesture.highFive,
          lockSeconds: 4,
        );
      }
    } else if (wasStretchingCheek &&
        DateTime.now().difference(_lastTouchSpeechTime).inSeconds > 5) {
      _lastTouchSpeechTime = DateTime.now();
      onRequestVoiceReaction(
        "Aku barusan cubit dan tarik pipi kamu sampai melar, kamu merajuk manja dong",
        lockEmotion: XiaoZhiEmotion.embarrassed,
        lockGesture: HandGesture.coverCheeks,
        lockSeconds: 4,
      );
    }

    cheekStretchX = 1.0;
    tickleShakeOffset = 0.0;
    onStateChanged();

    Future.delayed(const Duration(seconds: 1), () {
      gazeOffset = Offset.zero;
      onStateChanged();
    });
  }

  void updateIdleGaze() {
    final rand = Random();
    if (rand.nextBool()) {
      gazeOffset = Offset(
        (rand.nextDouble() - 0.5) * 0.45,
        (rand.nextDouble() - 0.5) * 0.25,
      );
    } else {
      gazeOffset = Offset.zero;
    }
  }

  void dispose() {
    _reviveTimer?.cancel();
    _accelSub?.cancel();
  }
}
