import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/gemini_service.dart';
import '../theme/app_theme.dart';

class LegalResourceHubScreen extends StatefulWidget {
  const LegalResourceHubScreen({super.key});

  @override
  State<LegalResourceHubScreen> createState() => _LegalResourceHubScreenState();
}

class _LegalResourceHubScreenState extends State<LegalResourceHubScreen>
    with SingleTickerProviderStateMixin {
  // Tab controller
  late TabController _tabController;

  // Search controller
  final TextEditingController _searchController = TextEditingController();

  // Selected category
  String _selectedCategory = 'All';

  // Chatbot messages
  late final List<Map<String, dynamic>> _chatMessages = _welcomeMessages();

  final TextEditingController _chatController = TextEditingController();

  // Legal categories
  final List<Map<String, dynamic>> _legalCategories = [
    {'name': 'All', 'icon': Iconsax.category, 'color': Colors.blue},
    {'name': 'Rights', 'icon': Iconsax.shield_tick, 'color': Colors.green},
    {'name': 'Complaints', 'icon': Iconsax.document, 'color': Colors.orange},
    {'name': 'Self-Defense', 'icon': Iconsax.activity, 'color': Colors.purple},
    {'name': 'Evidence', 'icon': Iconsax.camera, 'color': Colors.red},
    {'name': 'Laws', 'icon': Iconsax.book, 'color': Colors.teal},
  ];

  // Legal resources data
  final List<Map<String, dynamic>> _legalResources = [
    {
      'title': 'Your Rights During Arrest',
      'category': 'Rights',
      'description': 'Know what to do if you are arrested by police. Learn about your fundamental rights under the law.',
      'icon': Iconsax.shield_tick,
      'color': Colors.green,
      'content': '''
• Right to remain silent
• Right to know the reason for arrest
• Right to legal representation
• Right to inform family/friend
• Right to medical examination
• Right to be produced before magistrate within 24 hours
• Protection against self-incrimination
• Right to bail for bailable offenses
      ''',
      'steps': [
        'Stay calm and cooperative',
        'Ask for the reason of arrest',
        'Request to call your lawyer',
        'Inform your family members',
        'Do not sign anything without lawyer',
        'Remember the officer\'s name and badge number',
      ],
    },
    {
      'title': 'How to File an FIR',
      'category': 'Complaints',
      'description': 'Step-by-step guide to filing a First Information Report (FIR) at the police station.',
      'icon': Iconsax.document,
      'color': Colors.orange,
      'content': '''
• FIR is the written document prepared by police when they receive information about a cognizable offense
• It is your right to have an FIR registered
• Free of cost service
• You are entitled to a free copy of the FIR
      ''',
      'steps': [
        'Go to the nearest police station',
        'Inform the officer in charge about the incident',
        'Provide all details: date, time, location, description',
        'The officer will write the FIR as you dictate',
        'Read it carefully before signing',
        'Ask for a free copy of the FIR',
        'If police refuse, contact a lawyer or higher authorities',
      ],
    },
    {
      'title': 'Self-Defense Basics',
      'category': 'Self-Defense',
      'description': 'Essential self-defense techniques for personal safety in threatening situations.',
      'icon': Iconsax.activity,
      'color': Colors.purple,
      'content': '''
• Self-defense is a legal right to protect yourself from harm
• Use only reasonable force necessary
• Aim for vulnerable areas: eyes, nose, throat, groin
• Create distance and run to safety
• Attract attention by shouting
      ''',
      'steps': [
        'Stay aware of your surroundings',
        'Trust your instincts - if it feels wrong, leave',
        'Keep distance from suspicious individuals',
        'Learn basic strikes: palm strike, knee strike, elbow strike',
        'Target vulnerable areas: eyes, nose, throat, groin',
        'Use everyday objects as defense: keys, umbrella, bag',
        'Run to populated areas and shout for help',
      ],
    },
    {
      'title': 'Collecting Evidence',
      'category': 'Evidence',
      'description':
          'How to properly collect and preserve evidence after an incident.',
      'icon': Iconsax.camera,
      'color': Colors.red,
      'content': '''
• Evidence is crucial for legal proceedings
• Preserve all physical evidence
• Take photographs immediately
• Note down witness information
• Keep medical reports if injured
      ''',
      'steps': [
        'Take photos/videos of the scene',
        'Preserve any physical evidence',
        'Get contact details of witnesses',
        'Visit doctor for medical examination',
        'Keep all documents safe',
        'Note down exact date and time',
        'Save any CCTV footage locations',
      ],
    },
    {
      'title': 'Women Safety Laws',
      'category': 'Laws',
      'description': 'Important legal protections and rights for women under Pakistani law.',
      'icon': Iconsax.book,
      'color': Colors.teal,
      'content': '''
• Protection against harassment at workplace
• Laws against domestic violence
• Right to equal pay
• Maternity benefits
• Protection against forced marriage
      ''',
      'steps': [
        'Workplace Harassment Law 2010',
        'Domestic Violence Prevention Act',
        'Acid Control and Acid Crime Prevention Act',
        'Women in Distress and Detention Fund',
        'Anti-Women Practices Act',
        'Honor Killing Laws',
      ],
    },
    {
      'title': 'Cyber Crime Reporting',
      'category': 'Complaints',
      'description':
          'How to report online harassment, fraud, and other cyber crimes.',
      'icon': Iconsax.mobile,
      'color': Colors.blue,
      'content': '''
• Cyber crimes include online harassment, fraud, identity theft
• Report to FIA Cyber Crime Wing
• Preserve all digital evidence
• Take screenshots of all communication
• Do not delete any messages
      ''',
      'steps': [
        'Save all evidence: screenshots, messages, emails',
        'Note down URLs and profiles',
        'Report to FIA Cyber Crime Wing',
        'Visit website: https://fia.gov.pk',
        'Call helpline: 1991',
        'Visit nearest FIA office',
        'Block the person on all platforms',
      ],
    },
    {
      'title': 'Traffic Violations',
      'category': 'Laws',
      'description': 'Understanding traffic laws, fines, and your rights during traffic stops.',
      'icon': Iconsax.car,
      'color': Colors.amber,
      'content': '''
• Always carry driving license and documents
• Know traffic fines and penalties
• Rights during police traffic stop
• How to challenge unfair challans
• Insurance requirements
      ''',
      'steps': [
        'Keep license, registration, and documents handy',
        'Know speed limits in different areas',
        'Understand traffic signs',
        'Never drink and drive',
        'Wear seatbelt at all times',
        'Use indicators when turning',
        'Respect pedestrian crossings',
      ],
    },
    {
      'title': 'Emergency Contacts',
      'category': 'Rights',
      'description':
          'Important helpline numbers for emergencies and legal assistance.',
      'icon': Iconsax.call,
      'color': Colors.red,
      'content': '''
• Keep these numbers handy
• Save in your phone
• Share with family members
• Call immediately in emergency
      ''',
      'steps': [
        'Police Emergency: 15',
        'Ambulance: 115',
        'Fire Brigade: 16',
        'Women Helpline: 1099',
        'Child Protection: 1121',
        'Cyber Crime: 1991',
        'Anti-Narcotics: 111-555-555',
      ],
    },
  ];

  // Self-defense techniques: steps shown in the app, videos open in YouTube.
  final List<Map<String, dynamic>> _selfDefenseVideos = [
    {
      'title': 'Palm strike',
      'level': 'Beginner',
      'icon': Iconsax.flash_1,
      'query': 'palm strike self defense for women',
      'steps': [
        'Stand side-on, feet shoulder-width apart, hands up near your face.',
        'Bend your wrist back and keep your fingers pulled in.',
        'Push the heel of your palm hard into the nose or chin, driving from your hips.',
        'Pull your hand back fast, then run and shout for help.',
      ],
    },
    {
      'title': 'Escape a wrist grab',
      'level': 'Beginner',
      'icon': Iconsax.arrow_swap_horizontal,
      'query': 'escape wrist grab self defense',
      'steps': [
        "Don't pull straight back: find the gap between their thumb and fingers.",
        'Turn your wrist towards their thumb.',
        'Pull out sharply through that gap, using your whole arm.',
        'Step away immediately and move to a crowded place.',
      ],
    },
    {
      'title': 'Defense against a choke',
      'level': 'Intermediate',
      'icon': Iconsax.shield_cross,
      'query': 'front choke escape self defense women',
      'steps': [
        'Tuck your chin down to protect your throat.',
        'Raise one arm straight up and turn your body sharply to that side.',
        'This breaks their grip: strike back with an elbow or knee if needed.',
        'Get away and call 15 or press SOS.',
      ],
    },
    {
      'title': 'Using everyday objects',
      'level': 'Beginner',
      'icon': Iconsax.key,
      'query': 'everyday objects self defense keys bag',
      'steps': [
        'Keep keys, a pen or a phone in your hand when walking alone.',
        'Hold keys firmly in a fist, one key sticking out from the side.',
        'Aim for the face or hands only to create space to escape.',
        'A bag or umbrella can also block and push an attacker away.',
      ],
    },
    {
      'title': 'Getting up from the ground',
      'level': 'Advanced',
      'icon': Iconsax.arrow_up_3,
      'query': 'ground self defense technical stand up',
      'steps': [
        'Stay on your back, knees bent, feet towards the attacker.',
        'Kick at their knees or shins if they come close.',
        'Post one hand behind you and the opposite foot on the ground.',
        'Lift your hips and swing your leg back to stand up facing them, then run.',
      ],
    },
    {
      'title': 'Escape a bear hug',
      'level': 'Intermediate',
      'icon': Iconsax.user_remove,
      'query': 'bear hug escape self defense',
      'steps': [
        'Drop your weight by bending your knees so you are harder to lift.',
        'Stamp on their foot or kick back at their shin.',
        'Drive an elbow back into their ribs or face.',
        'Turn out of their arms as the grip loosens, then run.',
      ],
    },
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadAdminContent();
  }

  /// Guides and videos published from the admin portal
  /// (app_content/legal_hub), shown after the built-in items.
  Future<void> _loadAdminContent() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('app_content')
          .doc('legal_hub')
          .get();
      final data = doc.data();
      if (data == null || !mounted) return;
      final guides = (data['guides'] is List)
          ? (data['guides'] as List).whereType<Map>().toList()
          : <Map>[];
      final videos = (data['videos'] is List)
          ? (data['videos'] as List).whereType<Map>().toList()
          : <Map>[];
      const colors = {
        'Rights': Colors.green,
        'Complaints': Colors.orange,
        'Self-Defense': Colors.purple,
        'Evidence': Colors.red,
        'Laws': Colors.teal,
      };
      setState(() {
        for (final g in guides) {
          final category = (g['category'] ?? 'Laws').toString();
          final points = (g['points'] is List)
              ? (g['points'] as List).map((e) => e.toString()).toList()
              : <String>[];
          _legalResources.add({
            'title': (g['title'] ?? '').toString(),
            'category': category,
            'description': (g['description'] ?? '').toString(),
            'icon': Iconsax.document_text,
            'color': colors[category] ?? Colors.teal,
            'content': points.map((p) => '• $p').join('\n'),
            'steps': (g['steps'] is List)
                ? (g['steps'] as List).map((e) => e.toString()).toList()
                : <String>[],
          });
        }
        for (final v in videos) {
          final url = (v['url'] ?? '').toString();
          if (url.isEmpty) continue;
          _selfDefenseVideos.add({
            'title': (v['title'] ?? '').toString(),
            'level': (v['level'] ?? 'Beginner').toString(),
            'icon': Iconsax.video,
            // A full link opens that exact video (see _openYouTube).
            'query': url,
            'steps': (v['steps'] is List)
                ? (v['steps'] as List).map((e) => e.toString()).toList()
                : <String>[],
          });
        }
      });
    } catch (e) {
      debugPrint('[LegalHub] admin content not loaded: $e');
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _chatController.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Legal assistant (Gemini, with an offline fallback)
  // ---------------------------------------------------------------------------

  final ScrollController _chatScroll = ScrollController();
  final GeminiService _gemini = GeminiService();
  bool _botTyping = false;

  static String _now() {
    final t = TimeOfDay.now();
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
  }

  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScroll.hasClients) return;
      _chatScroll.animateTo(
        _chatScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  static const String _assistantBrief = '''
You are "Safety Guardian Legal Assistant", a helpful assistant inside a Pakistani citizen-safety app.
Answer questions about Pakistani law, citizens' rights and procedures: filing an FIR (CrPC s.154) and what to do if police refuse,
harassment (PPC s.509, Protection against Harassment of Women at the Workplace Act 2010, Ombudsperson),
cyber crime and online harassment (PECA 2016, FIA Cyber Crime Wing, 1991), domestic violence, arrest rights (Constitution Art. 10),
evidence collection, medico-legal reports, free legal aid, and personal safety.
Rules:
- Reply in the same language the user writes in (English, Urdu, or Roman Urdu).
- Be practical and complete but focused: usually under 250 words, use short numbered steps or bullet points, no markdown headings, no bold.
- Mention the relevant law or section when you are confident; never invent section numbers.
- Give the right helpline when useful: Police 15, Rescue 1122, Ambulance 115, Women helpline 1043 (Punjab), FIA Cyber Crime 1991,
  Madadgaar 1098 (children/women), Edhi 115.
- If the user seems to be in immediate danger, tell them first to press SOS in the app or call 15.
- You are not a lawyer: for serious cases, suggest consulting a lawyer or the district legal aid committee.
- Politely decline questions that are not about safety, law or rights.
''';

  Future<void> _sendMessage([String? preset]) async {
    final text = (preset ?? _chatController.text).trim();
    if (text.isEmpty || _botTyping) return;

    setState(() {
      _chatMessages.add({'sender': 'user', 'message': text, 'time': _now()});
      _chatController.clear();
      _botTyping = true;
    });
    _scrollChatToEnd();

    String reply;
    var offline = false;
    String? offlineReason;
    try {
      if (!_gemini.hasApiKey) throw const GeminiAuthException('AI key not set');
      // Last few turns so follow-up questions make sense.
      final history = _chatMessages
          .where((m) => m['local'] != true)
          .toList()
          .reversed
          .take(8)
          .toList()
          .reversed
          .map(
            (m) =>
                '${m['sender'] == 'bot' ? 'Assistant' : 'User'}: ${m['message']}',
          )
          .join('\n');
      final prompt =
          '$_assistantBrief\nConversation so far:\n$history\n\nAssistant:';

      var res = await _gemini.generateContent(
        prompt,
        generationConfig: {'temperature': 0.3, 'maxOutputTokens': 8192},
      );
      reply = res.text;
      // If the answer was cut off, ask the model to carry on (up to twice).
      for (var i = 0; i < 2 && res.wasCutOff; i++) {
        res = await _gemini.generateContent(
          '$prompt $reply\n\n(Continue exactly where the answer above stopped. '
          'Do not repeat anything.)',
          generationConfig: {'temperature': 0.3, 'maxOutputTokens': 8192},
        );
        reply = '$reply${res.text.startsWith(' ') ? '' : ' '}${res.text}';
      }
      reply = reply
          .replaceAll('**', '')
          .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
          .trim();
      if (reply.isEmpty) throw const GeminiException('empty reply');
    } catch (e) {
      debugPrint('[LegalAssistant] Gemini unavailable: $e');
      offline = true;
      offlineReason = switch (e) {
        GeminiAuthException() => 'AI key missing or invalid',
        GeminiQuotaException() => 'AI daily limit reached',
        GeminiNetworkException() => 'no internet or the AI took too long',
        _ => 'AI service error',
      };
      reply = _getBotResponse(text);
    }

    if (!mounted) return;
    setState(() {
      _botTyping = false;
      _chatMessages.add({
        'sender': 'bot',
        'message': reply,
        'time': _now(),
        if (offline) 'offline': offlineReason,
      });
    });
    _scrollChatToEnd();
  }

  void _clearChat() {
    setState(() {
      _chatMessages
        ..clear()
        ..addAll(_welcomeMessages());
    });
  }

  List<Map<String, dynamic>> _welcomeMessages() => [
    {
      'sender': 'bot',
      'local': true,
      'message': "Assalam-o-Alaikum! I'm your legal assistant. Ask me anything about your rights, FIRs, harassment, cyber crime or collecting evidence, in English or Urdu.",
      'time': _now(),
    },
  ];

  /// Offline answers when the AI can't be reached.
  String _getBotResponse(String message) {
    final m = message.toLowerCase();
    bool has(List<String> words) => words.any(m.contains);

    if (has(['fir', 'report', 'complaint', 'shikayat', 'parcha'])) {
      return 'To file an FIR (CrPC section 154):\n1. Go to the police station where the incident happened.\n2. Tell the duty officer what happened; it must be written down.\n3. Read it, sign it, and get a free copy.\n4. If police refuse, apply to the SSP/DPO, or to the Sessions Court (justice of peace) under section 22-A CrPC.\nYou can also report through this app: Home → Report incident.';
    }
    if (has(['arrest', 'giraftar', 'custody'])) {
      return 'If you are arrested (Constitution Article 10):\n• You must be told the reason.\n• You can contact and be defended by a lawyer.\n• You must be produced before a magistrate within 24 hours.\n• Ask for a medical examination if you were hurt.\n• Inform your family.';
    }
    if (has([
      'cyber',
      'online',
      'blackmail',
      'facebook',
      'whatsapp',
      'photos leak',
      'hack',
    ])) {
      return 'Online harassment or blackmail (PECA 2016):\n1. Don\'t delete anything. Take screenshots with dates and profile links.\n2. Don\'t pay or negotiate.\n3. Report to FIA Cyber Crime: helpline 1991 or complaint.fia.gov.pk.\n4. Report and block the account on the platform.';
    }
    if (has(['harass', 'tang', 'workplace', 'office'])) {
      return 'For harassment:\n• Street or public harassment is an offence under PPC section 509; report to police (15).\n• At work: complain to your office inquiry committee or the Federal/Provincial Ombudsperson under the 2010 Act.\n• Keep evidence: messages, witnesses, dates.\n• Women helpline (Punjab): 1043.';
    }
    if (has(['evidence', 'proof', 'saboot'])) {
      return 'Collecting evidence:\n• Photos and videos (Evidence capture in this app saves them with location).\n• Screenshots of messages with date and number.\n• Names and numbers of witnesses.\n• A medico-legal report from a government hospital for any injury.\n• Keep originals; share copies.';
    }
    if (has(['domestic', 'husband', 'ghar', 'family violence'])) {
      return 'Domestic violence:\n• If in danger now, press SOS or call 15.\n• You can file an FIR for hurt (PPC 332-337).\n• Provinces have protection laws and shelters (Dar-ul-Aman); Punjab: Violence Against Women Centres, helpline 1043.\n• Get a medico-legal report for injuries.';
    }
    if (has(['self defense', 'self-defence', 'defend', 'attack'])) {
      return 'Self-defence:\n• Pakistani law (PPC 96-106) lets you use reasonable force to protect yourself.\n• Your goal is to escape: create distance, shout, run to a crowded place.\n• Use SOS in this app to alert your contacts.';
    }
    if (has(['helpline', 'number', 'contact', 'call'])) {
      return 'Emergency numbers:\nPolice 15 · Rescue 1122 · Ambulance 115\nWomen helpline (Punjab) 1043 · FIA Cyber Crime 1991 · Madadgaar 1098';
    }
    if (has(['lawyer', 'wakeel', 'legal aid', 'free'])) {
      return 'Free legal help:\n• District Legal Empowerment Committees at every district court give free lawyers to people who can\'t afford one.\n• Bar council legal aid cells.\n• NGOs like Legal Aid Society (Karachi) and AGHS (Lahore).';
    }
    return 'I couldn\'t reach the online assistant just now, so here are topics I can help with offline:\n• Filing an FIR\n• Arrest rights\n• Harassment\n• Cyber crime and blackmail\n• Evidence\n• Emergency numbers\nTry asking about one of these.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Legal Resource Hub'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF1D4ED8),
          labelColor: const Color(0xFF1D4ED8),
          unselectedLabelColor: const Color(0xFF475569),
          indicatorWeight: 3,
          tabs: const [
            Tab(text: 'Resources'),
            Tab(text: 'Self-Defense'),
            Tab(text: 'Legal Assistant'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Resources Tab
          _buildResourcesTab(),

          // Self-Defense Tab
          _buildSelfDefenseTab(),

          // Legal Assistant Tab
          _buildLegalAssistantTab(),
        ],
      ),
    );
  }

  // Tab 1: Legal Resources
  Widget _buildResourcesTab() {
    return Column(
      children: [
        // Search Bar
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search legal resources...',
              prefixIcon: const Icon(Iconsax.search_normal),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _searchController.clear();
                        });
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.grey.shade100,
            ),
            onChanged: (value) => setState(() {}),
          ),
        ),

        // Categories
        SizedBox(
          height: 50,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _legalCategories.length,
            itemBuilder: (context, index) {
              final category = _legalCategories[index];
              final isSelected = _selectedCategory == category['name'];

              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(category['name']),
                  selected: isSelected,
                  onSelected: (selected) {
                    setState(() {
                      _selectedCategory = category['name'];
                    });
                  },
                  backgroundColor: Colors.grey.shade100,
                  selectedColor: category['color'].withOpacity(0.2),
                  checkmarkColor: category['color'],
                  avatar: Icon(
                    category['icon'],
                    color: isSelected ? category['color'] : Colors.grey,
                    size: 16,
                  ),
                  labelStyle: TextStyle(
                    color: isSelected
                        ? category['color']
                        : Colors.grey.shade700,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 10),

        // Resources List
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _legalResources
                .where(
                  (r) =>
                      _selectedCategory == 'All' ||
                      r['category'] == _selectedCategory,
                )
                .length,
            itemBuilder: (context, index) {
              final filteredResources = _legalResources
                  .where(
                    (r) =>
                        _selectedCategory == 'All' ||
                        r['category'] == _selectedCategory,
                  )
                  .toList();

              final resource = filteredResources[index];

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                child: Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: InkWell(
                    onTap: () => _showResourceDetails(resource),
                    borderRadius: BorderRadius.circular(15),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: resource['color'].withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              resource['icon'],
                              color: resource['color'],
                              size: 24,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  resource['title'],
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  resource['description'],
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: resource['color'].withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    resource['category'],
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: resource['color'],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.arrow_forward_ios,
                            size: 14,
                            color: Colors.grey.shade400,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // Tab 2: Self-Defense
  Widget _buildSelfDefenseTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Material(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.xl),
            onTap: () => _openYouTube('self defense basics for women'),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Self-defense basics',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'The goal is always to break free and get to safety, not to fight.',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow,
                      color: AppColors.primary,
                      size: 30,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Techniques',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        const Text(
          'Tap one to see the steps. Videos open in YouTube.',
          style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= 600 ? 3 : 2;
            const gap = 12.0;
            final w = (c.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final v in _selfDefenseVideos)
                  SizedBox(width: w, child: _techniqueCard(v)),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.warningSoft,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Iconsax.info_circle, size: 18, color: AppColors.warning),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Practise with a trained instructor. In real danger, press SOS and run to a crowded place.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.warning,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _techniqueCard(Map<String, dynamic> v) {
    final level = v['level'] as String;
    final (bg, fg) = switch (level) {
      'Beginner' => (AppColors.successSoft, AppColors.success),
      'Intermediate' => (AppColors.warningSoft, AppColors.warning),
      _ => (AppColors.dangerSoft, AppColors.dangerDark),
    };
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showTechnique(v),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      v['icon'] as IconData,
                      size: 20,
                      color: AppColors.primary,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      level,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                v['title'] as String,
                maxLines: 2,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${(v['steps'] as List).length} steps',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTechnique(Map<String, dynamic> v) {
    final steps = (v['steps'] as List).cast<String>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                v['title'] as String,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: AppColors.primarySoft,
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          steps[i],
                          style: const TextStyle(fontSize: 14, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _openYouTube(v['query'] as String);
                  },
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Watch on YouTube'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens YouTube (app if installed, otherwise the browser) with tutorial
  /// videos for [query].
  Future<void> _openYouTube(String query) async {
    // Admin-published items carry a full video link; built-in ones a search.
    final uri = query.startsWith('http')
        ? Uri.parse(query)
        : Uri.parse(
            'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(query)}',
          );
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Couldn't open YouTube. Check your internet connection.",
          ),
        ),
      );
    }
  }

  // Tab 3: Legal Assistant Chatbot
  Widget _buildLegalAssistantTab() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Iconsax.judge,
                  color: AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Legal assistant',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _gemini.hasApiKey
                          ? 'AI help with Pakistani law · not a lawyer'
                          : 'Offline answers · AI key not set',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'New chat',
                onPressed: _botTyping ? null : _clearChat,
                icon: const Icon(Iconsax.refresh, size: 20),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _chatScroll,
            padding: const EdgeInsets.all(16),
            itemCount: _chatMessages.length + (_botTyping ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _chatMessages.length) return _typingBubble();
              return _chatBubble(_chatMessages[index]);
            },
          ),
        ),
        if (_chatMessages.length <= 2)
          SizedBox(
            height: 48,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              children: [
                _buildSuggestionChip('How do I file an FIR?'),
                _buildSuggestionChip('Police refused my FIR'),
                _buildSuggestionChip('Someone is blackmailing me online'),
                _buildSuggestionChip('Harassment at work'),
                _buildSuggestionChip('My rights if arrested'),
                _buildSuggestionChip('Free legal help'),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatController,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: 'Ask about your rights…',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: _botTyping ? AppColors.border : AppColors.primary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _botTyping ? null : () => _sendMessage(),
                    child: const SizedBox(
                      width: 46,
                      height: 46,
                      child: Icon(
                        Iconsax.send_1,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _chatBubble(Map<String, dynamic> message) {
    final isBot = message['sender'] == 'bot';
    final maxW = MediaQuery.sizeOf(context).width * 0.78;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: isBot
            ? MainAxisAlignment.start
            : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (isBot) ...[
            const CircleAvatar(
              radius: 14,
              backgroundColor: AppColors.primarySoft,
              child: Icon(Iconsax.judge, size: 14, color: AppColors.primary),
            ),
            const SizedBox(width: 8),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxW.clamp(200.0, 560.0).toDouble(),
            ),
            child: GestureDetector(
              onLongPress: () {
                Clipboard.setData(
                  ClipboardData(text: message['message'] as String),
                );
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Copied')));
              },
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                decoration: BoxDecoration(
                  color: isBot ? AppColors.surface : AppColors.primary,
                  border: isBot ? Border.all(color: AppColors.border) : null,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isBot ? 4 : 16),
                    bottomRight: Radius.circular(isBot ? 16 : 4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message['offline'] != null) ...[
                      Text(
                        'Offline answer · ${message['offline']}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.warning,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    SelectableText(
                      message['message'] as String,
                      style: TextStyle(
                        color: isBot ? AppColors.text : Colors.white,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      (message['time'] ?? '') as String,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: isBot ? AppColors.textSubtle : Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _typingBubble() {
    return const Padding(
      padding: EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: AppColors.primarySoft,
            child: Icon(Iconsax.judge, size: 14, color: AppColors.primary),
          ),
          SizedBox(width: 8),
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text(
            'Thinking…',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionChip(String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 12.5)),
        onPressed: _botTyping ? null : () => _sendMessage(label),
      ),
    );
  }

  void _showResourceDetails(Map<String, dynamic> resource) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          return Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: resource['color'].withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        resource['icon'],
                        color: resource['color'],
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            resource['title'],
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: resource['color'].withOpacity(0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              resource['category'],
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: resource['color'],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    children: [
                      const Text(
                        'Overview',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        resource['description'],
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Key Information',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          resource['content'],
                          style: const TextStyle(height: 1.5),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Step-by-Step Guide',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...List.generate(resource['steps'].length, (index) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: resource['color'].withOpacity(0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: resource['color'],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  resource['steps'][index],
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTipRow({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1D4ED8).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: const Color(0xFF1D4ED8), size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                description,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
