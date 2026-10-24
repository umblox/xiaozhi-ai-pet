import 'dart:math';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class RobotSfxService {
  /// Memutar efek suara ekspresi robot secara sintetis (PCM 16-bit)
  /// tanpa memerlukan file MP3/WAV eksternal.
  static void play(
    String sfxType, {
    required int sampleRate,
    required bool enabled,
    required bool isBusySpeaking,
  }) {
    if (!enabled || isBusySpeaking) return;

    try {
      final int sr = sampleRate;
      final List<int> samples = [];

      void addTone(
        double fStart,
        double fEnd,
        int durationMs, {
        double volume = 0.26,
        bool square = false,
        bool noise = false,
      }) {
        final int count = (sr * durationMs) ~/ 1000;
        double phase = 0.0;
        final rand = Random();
        for (int i = 0; i < count; i++) {
          final double progress = i / count;
          final double freq = fStart + (fEnd - fStart) * progress;
          final double env = sin(progress * pi);
          phase += (2 * pi * freq) / sr;
          double val = sin(phase);
          if (square) val = val >= 0 ? 0.8 : -0.8;
          if (noise) val = (val * 0.4) + ((rand.nextDouble() * 2 - 1) * 0.6);
          samples.add(
            (val * env * volume * 32767).toInt().clamp(-32760, 32760),
          );
        }
      }

      switch (sfxType) {
        case 'shoot_and_die':
          // Suara tembakan laser + kaca pecah + power down
          addTone(1500, 180, 140, volume: 0.42, noise: true);
          addTone(2400, 900, 90, volume: 0.32, noise: true);
          addTone(680, 140, 480, volume: 0.32, square: true);
          break;
        case 'revive':
          // Suara bangkit hidup kembali
          addTone(320, 580, 110);
          addTone(580, 880, 130);
          addTone(880, 1320, 180);
          break;
        case 'boop':
          // Suara pencet hidung (Nose Boop)
          addTone(450, 980, 90);
          addTone(980, 620, 70);
          break;
        case 'high_five':
          // Suara tepukan Tos / High-Five
          addTone(1200, 400, 65, volume: 0.38, noise: true);
          addTone(700, 1350, 120);
          break;
        case 'happy':
        case 'laughing':
        case 'funny':
          addTone(520, 780, 80);
          addTone(680, 1050, 85);
          addTone(850, 1280, 100);
          break;
        case 'loving':
        case 'kissy':
          addTone(600, 950, 140);
          addTone(950, 1400, 200);
          break;
        case 'angry':
          addTone(220, 150, 160, square: true, volume: 0.30);
          addTone(190, 120, 220, square: true, volume: 0.30);
          break;
        case 'sad':
        case 'crying':
        case 'confused':
          addTone(620, 420, 220);
          addTone(410, 260, 300);
          break;
        case 'surprised':
        case 'shocked':
          addTone(400, 1450, 160);
          break;
        case 'sleepy':
          addTone(480, 240, 360, volume: 0.22);
          break;
        case 'dizzy':
          addTone(400, 800, 90);
          addTone(800, 350, 90);
          addTone(350, 750, 90);
          break;
        default:
          addTone(660, 880, 80, volume: 0.18);
          break;
      }

      if (samples.isNotEmpty) {
        FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
      }
    } catch (_) {}
  }
}
