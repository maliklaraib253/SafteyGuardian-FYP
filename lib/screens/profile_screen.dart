import 'package:cloud_firestore/cloud_firestore.dart';

import '../theme/responsive.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';

/// User profile: view account details, edit display name and change password.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const _primary = Color(0xFF1D4ED8);

  final _nameFormKey = GlobalKey<FormState>();
  final _passwordFormKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _loading = true;
  bool _savingName = false;
  bool _savingPassword = false;
  bool _showCurrent = false;
  bool _showNew = false;

  String _email = '';
  String _cnic = '';
  DateTime? _createdAt;
  bool _identityVerified = false;

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = _user;
    if (user == null) return;
    _email = user.email ?? '';
    _nameController.text = user.displayName ?? '';
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = doc.data() ?? {};
      _nameController.text = (data['name'] ?? user.displayName ?? '')
          .toString();
      _cnic = (data['cnic'] ?? '').toString();
      _identityVerified = data['isIdentityVerified'] == true;
      final created = data['createdAt'];
      if (created is Timestamp) _createdAt = created.toDate();
    } catch (e) {
      debugPrint('[Profile] load failed: $e');
    }
    _createdAt ??= user.metadata.creationTime;
    if (mounted) setState(() => _loading = false);
  }

  String get _maskedCnic {
    final digits = _cnic.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 4) return _cnic.isEmpty ? '—' : _cnic;
    return '•••••-•••••••-${digits.substring(digits.length - 1)}';
  }

  String get _initials {
    final parts = _nameController.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty);
    if (parts.isEmpty) return _email.isNotEmpty ? _email[0].toUpperCase() : '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }

  Future<void> _saveName() async {
    if (!_nameFormKey.currentState!.validate()) return;
    final user = _user;
    if (user == null) return;
    final name = _nameController.text.trim();
    setState(() => _savingName = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'name': name,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await user.updateDisplayName(name);
      _toast('Name updated', Colors.green);
    } catch (e) {
      _toast('Could not update name: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  Future<void> _changePassword() async {
    if (!_passwordFormKey.currentState!.validate()) return;
    final user = _user;
    if (user == null || _email.isEmpty) return;
    setState(() => _savingPassword = true);
    try {
      // Firebase requires a recent login before changing the password.
      final credential = EmailAuthProvider.credential(
        email: _email,
        password: _currentPasswordController.text,
      );
      await user.reauthenticateWithCredential(credential);
      await user.updatePassword(_newPasswordController.text);
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
      if (mounted) FocusScope.of(context).unfocus();
      _toast('Password changed successfully', Colors.green);
    } on FirebaseAuthException catch (e) {
      _toast(_authError(e), Colors.red);
    } catch (e) {
      _toast('Could not change password: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _savingPassword = false);
    }
  }

  Future<void> _sendResetEmail() async {
    if (_email.isEmpty) return;
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: _email);
      _toast('Password reset link sent to $_email', Colors.green);
    } on FirebaseAuthException catch (e) {
      _toast(_authError(e), Colors.red);
    }
  }

  String _authError(FirebaseAuthException e) {
    switch (e.code) {
      case 'wrong-password':
      case 'invalid-credential':
        return 'Current password is incorrect';
      case 'weak-password':
        return 'New password is too weak (use at least 6 characters)';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later';
      case 'requires-recent-login':
        return 'Please log out and log in again, then retry';
      case 'network-request-failed':
        return 'No internet connection';
      default:
        return e.message ?? 'Something went wrong (${e.code})';
    }
  }

  void _toast(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Profile')),
      body: ContentWidth(
        maxWidth: 640,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 20),
                    _buildNameCard(),
                    const SizedBox(height: 16),
                    _buildPasswordCard(),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1D4ED8), Color(0xFF1E3A8A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: Colors.white,
            child: Text(
              _initials,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _primary,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _nameController.text.trim().isEmpty
                      ? 'Citizen'
                      : _nameController.text.trim(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  _email,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  'CNIC: $_maskedCnic',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      _identityVerified ? Icons.verified : Icons.info_outline,
                      size: 16,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _identityVerified
                          ? 'Identity verified'
                          : 'Identity not verified',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    if (_createdAt != null) ...[
                      const Text(
                        '  •  ',
                        style: TextStyle(color: Colors.white70),
                      ),
                      Text(
                        'Since ${_createdAt!.day}/${_createdAt!.month}/${_createdAt!.year}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: _primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildNameCard() {
    return _card(
      title: 'Edit Name',
      icon: Iconsax.edit,
      child: Form(
        key: _nameFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('profile_name_field'),
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Full name',
                prefixIcon: Icon(Iconsax.user),
              ),
              onChanged: (_) => setState(() {}),
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.length < 3) {
                  return 'Name must be at least 3 characters';
                }
                if (value.length > 50) return 'Name is too long';
                return null;
              },
            ),
            const SizedBox(height: 14),
            ElevatedButton(
              key: const Key('profile_save_name_button'),
              onPressed: _savingName ? null : _saveName,
              child: _savingName
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Save Name'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPasswordCard() {
    return _card(
      title: 'Change Password',
      icon: Iconsax.lock,
      child: Form(
        key: _passwordFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('profile_current_password_field'),
              controller: _currentPasswordController,
              obscureText: !_showCurrent,
              decoration: InputDecoration(
                labelText: 'Current password',
                prefixIcon: const Icon(Icons.key),
                suffixIcon: IconButton(
                  icon: Icon(_showCurrent ? Iconsax.eye_slash : Iconsax.eye),
                  onPressed: () => setState(() => _showCurrent = !_showCurrent),
                ),
              ),
              validator: (v) => (v == null || v.isEmpty)
                  ? 'Enter your current password'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('profile_new_password_field'),
              controller: _newPasswordController,
              obscureText: !_showNew,
              decoration: InputDecoration(
                labelText: 'New password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_showNew ? Iconsax.eye_slash : Iconsax.eye),
                  onPressed: () => setState(() => _showNew = !_showNew),
                ),
              ),
              validator: (v) {
                final value = v ?? '';
                if (value.length < 8) return 'Use at least 8 characters';
                if (!RegExp(r'[A-Za-z]').hasMatch(value) ||
                    !RegExp(r'\d').hasMatch(value)) {
                  return 'Use letters and numbers';
                }
                if (value == _currentPasswordController.text) {
                  return 'New password must be different';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('profile_confirm_password_field'),
              controller: _confirmPasswordController,
              obscureText: !_showNew,
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              validator: (v) => v != _newPasswordController.text
                  ? 'Passwords do not match'
                  : null,
            ),
            const SizedBox(height: 14),
            ElevatedButton(
              key: const Key('profile_change_password_button'),
              onPressed: _savingPassword ? null : _changePassword,
              child: _savingPassword
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Update Password'),
            ),
            TextButton(
              onPressed: _sendResetEmail,
              child: const Text(
                'Forgot current password? Email me a reset link',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
