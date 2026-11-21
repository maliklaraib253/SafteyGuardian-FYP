import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_guardian/screens/admin/admin_widgets.dart';

void main() {
  group('Admin helpers', () {
    test('status is normalised', () {
      expect(adminStatusOf({'status': 'in_progress'}), 'in progress');
      expect(adminStatusOf({'status': 'Resolved'}), 'resolved');
      expect(adminStatusOf({}), 'pending');
    });

    test('priority is normalised', () {
      expect(adminPriorityOf({'priority': 'critical'}), 'CRITICAL');
      expect(adminPriorityOf({'priority': 'PENDING'}), 'UNRATED');
      expect(adminPriorityOf({}), 'UNRATED');
    });

    test('CNIC is masked except the last four digits', () {
      expect(adminMaskCnic('35202-1234567-1'), '*****-***4567-1');
      expect(adminMaskCnic('3520212345671'), '*****-***4567-1');
      expect(adminMaskCnic(''), '-');
      expect(adminMaskCnic('12345'), '*****');
    });

    test('dates are formatted from Firestore timestamps', () {
      final t = Timestamp.fromDate(DateTime(2026, 11, 21, 14, 5));
      expect(adminFormatDate(t), '21 Nov 2026, 2:05 PM');
      expect(adminFormatDate(t, withTime: false), '21 Nov 2026');
      expect(adminFormatDate(null), '-');
    });

    test('title case', () {
      expect(adminTitleCase('in progress'), 'In Progress');
    });
  });
}
