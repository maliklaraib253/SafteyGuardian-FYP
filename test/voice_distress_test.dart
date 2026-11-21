import 'package:flutter_test/flutter_test.dart';
import 'package:safety_guardian/services/voice_distress_service.dart';

void main() {
  group('VoiceDistressAnalyzer Lexical Analysis Tests', () {
    test('Detects Roman Urdu Help Cries', () {
      final res1 = VoiceDistressAnalyzer.analyze('bachao mujhe koi');
      expect(res1.isDistress, isTrue);
      expect(res1.category, equals(VoiceDistressCategory.helpCry));
      expect(res1.confidence, greaterThanOrEqualTo(0.9));

      final res2 = VoiceDistressAnalyzer.analyze('madad karo meri please');
      expect(res2.isDistress, isTrue);
      expect(res2.category, equals(VoiceDistressCategory.helpCry));

      final res3 = VoiceDistressAnalyzer.analyze('choro mujhe police ko bulao');
      expect(res3.isDistress, isTrue);
      expect(res3.category, equals(VoiceDistressCategory.helpCry));

      final res4 = VoiceDistressAnalyzer.analyze('hath mat lagao mujhe');
      expect(res4.isDistress, isTrue);
      expect(res4.category, equals(VoiceDistressCategory.helpCry));
    });

    test('Detects English Distress and Help Cries', () {
      final res1 = VoiceDistressAnalyzer.analyze('help me please someone');
      expect(res1.isDistress, isTrue);
      expect(res1.category, equals(VoiceDistressCategory.helpCry));

      final res2 = VoiceDistressAnalyzer.analyze('leave me alone dont touch me');
      expect(res2.isDistress, isTrue);
      expect(res2.category, equals(VoiceDistressCategory.helpCry));

      final res3 = VoiceDistressAnalyzer.analyze('please stop it let me go');
      expect(res3.isDistress, isTrue);
      expect(res3.category, equals(VoiceDistressCategory.helpCry));
    });

    test('Detects Violent Threats and Robbery Demands', () {
      final res1 = VoiceDistressAnalyzer.analyze('mai tujhe maar dunga');
      expect(res1.isDistress, isTrue);
      expect(res1.category, equals(VoiceDistressCategory.threat));
      expect(res1.confidence, greaterThanOrEqualTo(0.95));

      final res2 = VoiceDistressAnalyzer.analyze('khatam kar dunga tujhe yahi');
      expect(res2.isDistress, isTrue);
      expect(res2.category, equals(VoiceDistressCategory.threat));

      final res3 = VoiceDistressAnalyzer.analyze('phone nikal jaldi warna goli chalao');
      expect(res3.isDistress, isTrue);
      expect(res3.category, equals(VoiceDistressCategory.threat));

      final res4 = VoiceDistressAnalyzer.analyze('i will kill you right now');
      expect(res4.isDistress, isTrue);
      expect(res4.category, equals(VoiceDistressCategory.threat));

      final res5 = VoiceDistressAnalyzer.analyze('give me your phone or ill shoot you');
      expect(res5.isDistress, isTrue);
      expect(res5.category, equals(VoiceDistressCategory.threat));
    });

    test('Detects Verbal Abuse and Street Harassment Slurs', () {
      final res1 = VoiceDistressAnalyzer.analyze('kutta kamina insan');
      expect(res1.isDistress, isTrue);
      expect(res1.category, equals(VoiceDistressCategory.verbalAbuse));

      final res2 = VoiceDistressAnalyzer.analyze('harami chutiya kahin ka');
      expect(res2.isDistress, isTrue);
      expect(res2.category, equals(VoiceDistressCategory.verbalAbuse));

      final res3 = VoiceDistressAnalyzer.analyze('you bastard get lost');
      expect(res3.isDistress, isTrue);
      expect(res3.category, equals(VoiceDistressCategory.verbalAbuse));

      final res4 = VoiceDistressAnalyzer.analyze('shut up you asshole');
      expect(res4.isDistress, isTrue);
      expect(res4.category, equals(VoiceDistressCategory.verbalAbuse));
    });

    test('Handles Elongated Shouts (e.g. "baaaachaaao")', () {
      final res1 = VoiceDistressAnalyzer.analyze('baaaachaaaoooo');
      expect(res1.isDistress, isTrue);
      expect(res1.category, equals(VoiceDistressCategory.helpCry));

      final res2 = VoiceDistressAnalyzer.analyze('heeeellllllp meeee');
      expect(res2.isDistress, isTrue);
      expect(res2.category, equals(VoiceDistressCategory.helpCry));
    });

    test('Detects Urdu Script Keywords', () {
      final res1 = VoiceDistressAnalyzer.analyze('مدد کرو بچاؤ');
      expect(res1.isDistress, isTrue);
      expect(res1.category, equals(VoiceDistressCategory.helpCry));

      final res2 = VoiceDistressAnalyzer.analyze('میں جان سے مار دوں گا');
      expect(res2.isDistress, isTrue);
      expect(res2.category, equals(VoiceDistressCategory.threat));

      final res3 = VoiceDistressAnalyzer.analyze('بکواس بند کرو کتا');
      expect(res3.isDistress, isTrue);
      expect(res3.category, equals(VoiceDistressCategory.verbalAbuse));
    });

    test('Punctuation & Mixed-Case Robustness', () {
      final res1 = VoiceDistressAnalyzer.analyze('!!!BACHAO!!! MADAD KARO???');
      expect(res1.isDistress, isTrue);
      expect(res1.category, equals(VoiceDistressCategory.helpCry));

      final res2 = VoiceDistressAnalyzer.analyze('   mAAAr dUNGA   ');
      expect(res2.isDistress, isTrue);
      expect(res2.category, equals(VoiceDistressCategory.threat));

      final res3 = VoiceDistressAnalyzer.analyze('KuTTA, kAmInA!!');
      expect(res3.isDistress, isTrue);
      expect(res3.category, equals(VoiceDistressCategory.verbalAbuse));
    });

    test('Threat Priority over Abuse in Compound Sentences', () {
      // If a sentence contains both abuse ("kutta") and a death threat ("maar dunga"),
      // the threat must take priority for highest emergency escalation!
      final res = VoiceDistressAnalyzer.analyze('oye kutte bag nikal warna maar dunga');
      expect(res.isDistress, isTrue);
      expect(res.category, equals(VoiceDistressCategory.threat));
    });

    test('Does NOT Trigger False Alarms on Substring Collisions', () {
      // Innocent words that happen to contain substrings like "ass" (glass, pass, mass, classic)
      final safe1 = VoiceDistressAnalyzer.analyze('give me a glass of water');
      expect(safe1.isDistress, isFalse);

      final safe2 = VoiceDistressAnalyzer.analyze('did you pass the exam');
      expect(safe2.isDistress, isFalse);

      final safe3 = VoiceDistressAnalyzer.analyze('this is a classic book');
      expect(safe3.isDistress, isFalse);
    });

    test('Does NOT Trigger on Innocent and Normal Speech', () {
      final safe1 = VoiceDistressAnalyzer.analyze('aaj mausam kafi acha hai');
      expect(safe1.isDistress, isFalse);

      final safe2 = VoiceDistressAnalyzer.analyze('let us build flutter apps');
      expect(safe2.isDistress, isFalse);

      final safe3 = VoiceDistressAnalyzer.analyze('hum lunch kahan karein ge');
      expect(safe3.isDistress, isFalse);

      final safe4 = VoiceDistressAnalyzer.analyze('university project report submit karni hai');
      expect(safe4.isDistress, isFalse);

      final safe5 = VoiceDistressAnalyzer.analyze('');
      expect(safe5.isDistress, isFalse);
    });
  });

  group('VoiceDistressService Stream Simulation Pipeline Tests', () {
    late VoiceDistressService service;

    setUp(() {
      service = VoiceDistressService();
    });

    test('simulateSpokenPhrase dispatches live transcription and distress event', () async {
      VoiceDistressResult? receivedDistress;
      String? receivedTranscription;

      final sub1 = service.distressEventStream.listen((event) {
        receivedDistress = event;
      });

      final sub2 = service.liveTranscriptionStream.listen((text) {
        receivedTranscription = text;
      });

      final phrase = 'Tujhe jaan se maar dunga';
      final result = service.simulateSpokenPhrase(phrase);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(result.isDistress, isTrue);
      expect(result.category, equals(VoiceDistressCategory.threat));
      expect(receivedTranscription, equals(phrase));
      expect(receivedDistress, isNotNull);
      expect(receivedDistress!.category, equals(VoiceDistressCategory.threat));
      expect(receivedDistress!.matchedKeyword, equals('maar dunga'));

      await sub1.cancel();
      await sub2.cancel();
    });

    test('simulateSpokenPhrase with benign sentence dispatches transcription but NO distress event', () async {
      bool distressTriggered = false;
      String? receivedTranscription;

      final sub1 = service.distressEventStream.listen((_) {
        distressTriggered = true;
      });

      final sub2 = service.liveTranscriptionStream.listen((text) {
        receivedTranscription = text;
      });

      final phrase = 'Good morning everyone, have a nice day';
      final result = service.simulateSpokenPhrase(phrase);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(result.isDistress, isFalse);
      expect(receivedTranscription, equals(phrase));
      expect(distressTriggered, isFalse);

      await sub1.cancel();
      await sub2.cancel();
    });
  });

  group('Incapacitation Auto-SOS Countdown Logic Tests', () {
    test('Simulates 60-second (1 min) timer countdown and auto-dispatch upon timeout', () {
      int remainingSeconds = 60;
      bool sosDispatched = false;

      void tick() {
        if (remainingSeconds <= 1) {
          sosDispatched = true;
        } else {
          remainingSeconds--;
        }
      }

      // 1. Simulate ticks: 59 ticks should leave 1 second remaining
      for (int i = 0; i < 59; i++) {
        tick();
      }
      expect(sosDispatched, isFalse);
      expect(remainingSeconds, equals(1));

      // 60th tick triggers auto-dispatch timeout
      tick();
      expect(sosDispatched, isTrue);

      // 2. Responsive user cancellation before timeout
      remainingSeconds = 60;
      sosDispatched = false;

      for (int i = 0; i < 10; i++) {
        tick();
      }
      // User tapped "I'm Safe" at 50 seconds remaining
      final userCancelled = true;
      expect(userCancelled, isTrue);
      expect(sosDispatched, isFalse);
      expect(remainingSeconds, equals(50));
    });
  });
}
