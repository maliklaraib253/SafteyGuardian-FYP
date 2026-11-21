import 'dart:io' show Platform;

import '../theme/responsive.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/call_handler_service.dart';
import '../services/sos_service.dart';
import 'manage_contacts_screen.dart';
import 'my_reports_screen.dart';
import 'profile_screen.dart';

/// Citizen settings: account, trusted contacts and safety preferences.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  /// SharedPreferences key read by the incident report screen.
  static const String blurFacesDefaultKey = 'blur_faces_default';

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _primary = Color(0xFF1D4ED8);

  final SosService _sosService = SosService();
  List<Map<String, String>> _contacts = [];
  bool _loadingContacts = true;
  bool _autoReject = true;
  bool _blurFaces = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final autoReject = await CallHandlerService.isEnabledInSettings();
    await _sosService.loadContacts();
    if (!mounted) return;
    setState(() {
      _autoReject = autoReject;
      _blurFaces = prefs.getBool(SettingsScreen.blurFacesDefaultKey) ?? true;
      _contacts = List.from(_sosService.trustedContacts);
      _loadingContacts = false;
    });
  }

  Future<void> _openContacts() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ManageContactsScreen()),
    );
    await _sosService.loadContacts();
    if (mounted) {
      setState(() => _contacts = List.from(_sosService.trustedContacts));
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'You will need to sign in again to send SOS alerts and reports.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Log out', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await FirebaseAuth.instance.signOut();
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ContentWidth(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            _sectionTitle('Account'),
            _tile(
              key: const Key('settings_profile_tile'),
              icon: Icons.person_outline,
              title: 'Profile',
              subtitle: 'Edit name, change password',
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                );
                if (mounted) setState(() {});
              },
            ),
            _tile(
              key: const Key('settings_my_reports_tile'),
              icon: Icons.description_outlined,
              title: 'My Reports',
              subtitle: 'Track the status of reports you submitted',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MyReportsScreen()),
              ),
            ),

            _sectionTitle('Trusted Contacts'),
            _buildContactsCard(),

            _sectionTitle('Emergency & Privacy'),
            SwitchListTile(
              key: const Key('settings_auto_reject_switch'),
              secondary: const Icon(
                Icons.phone_disabled_outlined,
                color: _primary,
              ),
              title: const Text('Auto-reject calls during SOS'),
              subtitle: Text(
                Platform.isAndroid
                    ? 'Keeps your line free. Trusted contacts can still call you.'
                    : 'Not available on iPhone (iOS does not allow apps to reject calls).',
              ),
              value: Platform.isAndroid && _autoReject,
              onChanged: Platform.isAndroid
                  ? (v) async {
                      if (v) await CallHandlerService.ensurePermissions();
                      await CallHandlerService.setEnabledInSettings(v);
                      setState(() => _autoReject = v);
                    }
                  : null,
            ),
            SwitchListTile(
              key: const Key('settings_blur_faces_switch'),
              secondary: const Icon(Icons.face_retouching_off, color: _primary),
              title: const Text('Blur my face in report photos'),
              subtitle: const Text(
                'Only your own face is blurred; other people stay visible',
              ),
              value: _blurFaces,
              onChanged: (v) async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool(SettingsScreen.blurFacesDefaultKey, v);
                setState(() => _blurFaces = v);
              },
            ),

            _sectionTitle('Session'),
            if (user?.email != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 4,
                ),
                child: Text(
                  'Signed in as ${user!.email}',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
              ),
            _tile(
              key: const Key('settings_logout_tile'),
              icon: Icons.logout,
              iconColor: Colors.red,
              title: 'Log out',
              onTap: _confirmLogout,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildContactsCard() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.contacts_outlined, color: _primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _loadingContacts
                        ? 'Loading…'
                        : _contacts.isEmpty
                        ? 'No trusted contacts yet'
                        : '${_contacts.length} trusted contact${_contacts.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  key: const Key('settings_manage_contacts_button'),
                  onPressed: _openContacts,
                  icon: Icon(
                    _contacts.isEmpty ? Icons.add : Icons.edit,
                    size: 18,
                  ),
                  label: Text(_contacts.isEmpty ? 'Add' : 'Manage'),
                ),
              ],
            ),
            if (_contacts.isEmpty && !_loadingContacts)
              Padding(
                padding: const EdgeInsets.fromLTRB(36, 0, 8, 8),
                child: Text(
                  'Add family or friends. They get your location by SMS and are called in order when you press SOS.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
            ..._contacts.take(5).toList().asMap().entries.map((e) {
              final c = e.value;
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 4, right: 8),
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: Colors.blue.shade50,
                  child: Text(
                    '${e.key + 1}',
                    style: const TextStyle(fontSize: 12, color: _primary),
                  ),
                ),
                title: Text(c['name'] ?? ''),
                subtitle: Text(c['phone'] ?? ''),
              );
            }),
            if (_contacts.length > 5)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 8),
                child: Text(
                  '+${_contacts.length - 5} more',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
            if (_contacts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 6),
                child: Text(
                  'Order matters: contact #1 is called first.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          letterSpacing: 0.8,
          fontWeight: FontWeight.bold,
          color: Colors.grey.shade600,
        ),
      ),
    );
  }

  Widget _tile({
    Key? key,
    required IconData icon,
    required String title,
    String? subtitle,
    Color iconColor = _primary,
    required VoidCallback onTap,
  }) {
    return ListTile(
      key: key,
      leading: Icon(icon, color: iconColor),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
