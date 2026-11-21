import 'package:flutter/material.dart';

import '../theme/responsive.dart';

import 'package:iconsax/iconsax.dart';

import '../services/sos_service.dart';

class ManageContactsScreen extends StatefulWidget {
  const ManageContactsScreen({super.key});

  @override
  State<ManageContactsScreen> createState() => _ManageContactsScreenState();
}

class _ManageContactsScreenState extends State<ManageContactsScreen> {
  final SosService _sosService = SosService();
  List<Map<String, String>> _contacts = [];

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    await _sosService.loadContacts();
    if (!mounted) return;
    setState(() {
      _contacts = List.from(_sosService.trustedContacts);
    });
  }

  static const int _maxContacts = 10;

  /// Returns an error message for an invalid / duplicate phone, or null.
  String? _phoneError(String phone, {int? exceptIndex}) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length < 7 || digits.length > 15) {
      return 'Enter a valid phone number (e.g. 03001234567)';
    }
    String norm(String p) {
      var d = p.replaceAll(RegExp(r'[^\d]'), '');
      if (d.startsWith('92') && d.length > 10) d = d.substring(2);
      if (d.startsWith('0')) d = d.substring(1);
      return d;
    }

    for (var i = 0; i < _contacts.length; i++) {
      if (i == exceptIndex) continue;
      if (norm(_contacts[i]['phone'] ?? '') == norm(phone)) {
        return 'This number is already saved as ${_contacts[i]['name']}';
      }
    }
    return null;
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.orange),
    );
  }

  Future<void> _addContact() async {
    if (_contacts.length >= _maxContacts) {
      _showError('You can save up to $_maxContacts trusted contacts');
      return;
    }
    TextEditingController nameController = TextEditingController();
    TextEditingController phoneController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Add Trusted Contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(Iconsax.user),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: phoneController,
              decoration: const InputDecoration(
                labelText: 'Phone Number',
                prefixIcon: Icon(Iconsax.call),
              ),
              keyboardType: TextInputType.phone,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.trim().isNotEmpty &&
                  phoneController.text.trim().isNotEmpty) {
                final error = _phoneError(phoneController.text.trim());
                if (error != null) {
                  _showError(error);
                  return;
                }
                await _sosService.addContact(
                  nameController.text.trim(),
                  phoneController.text.trim(),
                );
                await _loadContacts();
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _editContact(int index) async {
    final contact = _contacts[index];
    final nameController = TextEditingController(text: contact['name']);
    final phoneController = TextEditingController(text: contact['phone']);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Edit Trusted Contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(Iconsax.user),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: phoneController,
              decoration: const InputDecoration(
                labelText: 'Phone Number',
                prefixIcon: Icon(Iconsax.call),
                hintText: '03xxxxxxxxx',
              ),
              keyboardType: TextInputType.phone,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.trim().isNotEmpty &&
                  phoneController.text.trim().isNotEmpty) {
                final error = _phoneError(
                  phoneController.text.trim(),
                  exceptIndex: index,
                );
                if (error != null) {
                  _showError(error);
                  return;
                }
                await _sosService.updateContact(
                  index,
                  nameController.text.trim(),
                  phoneController.text.trim(),
                );
                await _loadContacts();
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteContact(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove contact?'),
        content: Text(
          '${_contacts[index]['name']} will no longer receive your SOS alerts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _sosService.removeContact(index);
    await _loadContacts();
  }

  void _reorderContacts(int oldIndex, int newIndex) {
    setState(() {
      if (oldIndex < newIndex) {
        newIndex -= 1;
      }
      final item = _contacts.removeAt(oldIndex);
      _contacts.insert(newIndex, item);
    });
    _sosService.reorderContacts(oldIndex, newIndex);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage SOS Contacts'),
        actions: [
          IconButton(icon: const Icon(Iconsax.add), onPressed: _addContact),
        ],
      ),
      body: ContentWidth(
        maxWidth: 640,
        child: _contacts.isEmpty
            ? Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Iconsax.user_add,
                          size: 56,
                          color: Color(0xFF1D4ED8),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'No Trusted Contacts Yet',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add your family or trusted friends. They will receive your live location and automated emergency calls when you need help.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _addContact,
                        icon: const Icon(Iconsax.add),
                        label: const Text('Add Contact'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1D4ED8),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : ReorderableListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _contacts.length,
                // ignore: deprecated_member_use
                onReorder: _reorderContacts,
                itemBuilder: (context, index) {
                  final contact = _contacts[index];
                  final phone = contact['phone'] ?? '';
                  final hasPhone = phone
                      .replaceAll(RegExp(r'[^\d+]'), '')
                      .isNotEmpty;

                  return Card(
                    key: ValueKey('${contact['name']}|$phone|$index'),
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: ListTile(
                      onTap: () => _editContact(index),
                      leading: CircleAvatar(
                        backgroundColor: hasPhone
                            ? Colors.blue.shade100
                            : Colors.orange.shade100,
                        child: Text(
                          contact['name']!.isNotEmpty
                              ? contact['name']![0].toUpperCase()
                              : '?',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: hasPhone
                                ? const Color(0xFF1D4ED8)
                                : Colors.deepOrange,
                          ),
                        ),
                      ),
                      title: Text(
                        contact['name']!,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        hasPhone ? phone : '⚠️ Tap to add phone number',
                        style: TextStyle(
                          color: hasPhone
                              ? Colors.grey.shade700
                              : Colors.deepOrange,
                          fontSize: 12,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.edit_outlined,
                              size: 20,
                              color: Color(0xFF1D4ED8),
                            ),
                            onPressed: () => _editContact(index),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: Colors.red,
                            ),
                            onPressed: () => _deleteContact(index),
                          ),
                          const Icon(Icons.drag_handle, color: Colors.grey),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
