import 'package:flutter_test/flutter_test.dart';
import 'package:safety_guardian/services/face_service.dart';

void main() {
  test('Pure text analysis confirms valid Pakistani CNIC with matching number', () {
    final cardText = '''
    ISLAMIC REPUBLIC OF PAKISTAN
    National Identity Card
    Name: Muhammad Ali
    Father Name: Ahmad Ali
    Gender: M
    Identity Number: 35202-1234567-1
    Date of Birth: 01.01.1995
    Date of Issue: 10.02.2020
    Date of Expiry: 10.02.2030
    ''';

    // Matching CNIC
    final resMatch = FaceService.analyzeCNICText(cardText, expectedCnic: '35202-1234567-1');
    expect(resMatch.isValid, isTrue);
    expect(resMatch.isExpectedCnicMatched, isTrue);
    expect(resMatch.detectedCnic?.replaceAll(RegExp(r'[^0-9]'), ''), equals('3520212345671'));

    // Mismatched CNIC (Someone uploading another person's card)
    final resMismatch = FaceService.analyzeCNICText(cardText, expectedCnic: '37405-9876543-2');
    expect(resMismatch.isValid, isFalse);
    expect(resMismatch.isExpectedCnicMatched, isFalse);
    expect(resMismatch.message, contains('CNIC number mismatch'));

    // Random non-card text (e.g. street sign, selfie with no text, receipt)
    final resRandom = FaceService.analyzeCNICText('Just a photo with no official document text', expectedCnic: '35202-1234567-1');
    expect(resRandom.isValid, isFalse);
    expect(resRandom.message, contains('This is not an official NADRA CNIC picture'));
  });

  test('Validates authentic NADRA Smart CNIC with chip and holder details', () {
    final ashtarCnicText = '''
    PAKISTAN National Identity Card
    ISLAMIC REPUBLIC OF PAKISTAN
    Name: Muhammad Ashtar Husnain
    Father Name: Syed Muhammad Husnain Naqvi
    Gender: M
    Country of Stay: Pakistan
    Identity Number: 37104-2474303-1
    Date of Birth: 17.12.2004
    Date of Issue: 27.02.2025
    Date of Expiry: 27.02.2035
    Holder's Signature
    ''';

    // When Step 1 CNIC matches the card
    final res = FaceService.analyzeCNICText(ashtarCnicText, expectedCnic: '37104-2474303-1');
    expect(res.isValid, isTrue);
    expect(res.isExpectedCnicMatched, isTrue);
    expect(res.detectedCnic?.replaceAll(RegExp(r'[^0-9]'), ''), equals('3710424743031'));

    // When Step 1 has dummy CNIC 37104-4444444-4 and card has 37104-2474303-1
    final resMismatch = FaceService.analyzeCNICText(ashtarCnicText, expectedCnic: '37104-4444444-4');
    expect(resMismatch.isValid, isFalse);
    expect(resMismatch.isExpectedCnicMatched, isFalse);
    expect(resMismatch.message, contains('37104-4444444-4'));
    expect(resMismatch.message, contains('37104-2474303-1'));
  });

  test('Driving license with CNIC number is rejected as invalid document', () {
    final drivingLicenseText = '''
    DRIVING LICENSE
    TRAFFIC POLICE, PUNJAB.
    License No. AK-23-4851
    Name : MUHAMMAD ASHTAR HUSNAIN
    S/o W/o D/o : SYED MUHAMMAD HUSNAIN NAQVI
    Address : MITHYAL TEHSIL JAND DISTT ATTOCK
    Height : 5.8
    CNIC No. : 3710424743031
    Date of Birth : 17-Dec-04
    Blood Group : A+
    Issue Date : 17-Aug-23
    Expiry Date : 16-Aug-28
    Licensing Authority ATTOCK
    ''';

    final res = FaceService.analyzeCNICText(drivingLicenseText, expectedCnic: '37104-2474303-1');
    expect(res.isValid, isFalse);
    expect(res.message, contains('Only official NADRA National Identity Cards are accepted'));
  });

  test('Student cards, Passports, and other non-CNIC documents are rejected', () {
    final studentCardText = '''
    PUNJAB UNIVERSITY
    STUDENT IDENTITY CARD
    Name: Ali Khan
    CNIC No: 35202-1234567-1
    Session: 2022-2026
    ''';

    final resStudent = FaceService.analyzeCNICText(studentCardText, expectedCnic: '35202-1234567-1');
    expect(resStudent.isValid, isFalse);
    expect(resStudent.message, contains('Only official NADRA National Identity Cards are accepted'));
  });
}


