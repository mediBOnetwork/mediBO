import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/user_profile.dart';
import '../../user_state.dart';

class BusinessDetailsScreen extends StatefulWidget {
  final String userId;
  final String phone;
  final String email;

  const BusinessDetailsScreen({
    super.key,
    required this.userId,
    required this.phone,
    this.email = '',
  });

  @override
  State<BusinessDetailsScreen> createState() => _BusinessDetailsScreenState();
}

class _BusinessDetailsScreenState extends State<BusinessDetailsScreen> {
  final _formKey = GlobalKey<FormState>();

  // Business
  final _customerNameCtrl = TextEditingController();
  final _pharmacyCtrl = TextEditingController();
  String? _storeType;
  String? _rangeZone;

  // Address
  final _addressCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _pincodeCtrl = TextEditingController();
  final _storeLocationCtrl = TextEditingController();

  // Contact
  final _whatsappCtrl = TextEditingController();
  final _otherContactCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  // Licenses
  final _dl20bCtrl = TextEditingController();
  final _dl21bCtrl = TextEditingController();
  final _gstCtrl = TextEditingController();

  // Account
  String? _paymentTerm;
  final _customerCodeCtrl = TextEditingController();
  String? _customerCodeError;

  bool _saving = false;
  String? _saveError;

  static const _storeTypes = [
    'Retail Pharmacy',
    'Hospital Pharmacy',
    'Clinic',
    'Wholesale Distributor',
    'Other',
  ];

  static const _rangeZones = [
    'Local (0–25 km)',
    'City (25–50 km)',
    'District (50–100 km)',
    'Regional (100+ km)',
  ];

  static const _paymentTerms = ['Advance Payment', 'COD'];

  @override
  void initState() {
    super.initState();
    final stripped = widget.phone.replaceAll('+91', '').trim();
    if (stripped.length == 10) _whatsappCtrl.text = stripped;
    if (widget.email.isNotEmpty) _emailCtrl.text = widget.email;
    _customerCodeCtrl.addListener(() {
      if (_customerCodeError != null) {
        setState(() => _customerCodeError = null);
      }
    });
  }

  @override
  void dispose() {
    _customerNameCtrl.dispose();
    _pharmacyCtrl.dispose();
    _addressCtrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    _pincodeCtrl.dispose();
    _storeLocationCtrl.dispose();
    _whatsappCtrl.dispose();
    _otherContactCtrl.dispose();
    _emailCtrl.dispose();
    _dl20bCtrl.dispose();
    _dl21bCtrl.dispose();
    _gstCtrl.dispose();
    _customerCodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _customerCodeError = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final profile = UserProfile(
        userId: widget.userId,
        customerName: _customerNameCtrl.text.trim(),
        pharmacyName: _pharmacyCtrl.text.trim(),
        storeType: _storeType!,
        rangeZone: _rangeZone!,
        addressLocal: _addressCtrl.text.trim(),
        city: _cityCtrl.text.trim(),
        state: _stateCtrl.text.trim(),
        pincode: _pincodeCtrl.text.trim(),
        storeLocationLink: _storeLocationCtrl.text.trim().isNotEmpty
            ? _storeLocationCtrl.text.trim()
            : null,
        whatsappNo: _whatsappCtrl.text.trim(),
        otherContactNo: _otherContactCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        dl20b: _dl20bCtrl.text.trim(),
        dl21b: _dl21bCtrl.text.trim().isNotEmpty
            ? _dl21bCtrl.text.trim()
            : null,
        gstNo: _gstCtrl.text.trim().isNotEmpty
            ? _gstCtrl.text.trim().toUpperCase()
            : null,
        paymentTerm: _paymentTerm!,
        customerCode: _customerCodeCtrl.text.trim().toUpperCase(),
      );
      await UserState.read(context).saveProfile(profile);
      if (context.mounted) Navigator.of(context).pop();
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        if (mounted) {
          setState(() => _customerCodeError =
              'This customer code is already taken, please choose another');
        }
      } else {
        if (mounted) {
          setState(() => _saveError = 'Failed to save. Please try again.');
        }
      }
    } catch (_) {
      if (mounted) setState(() => _saveError = 'Failed to save. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Color(0xFF1B5E20)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Complete Registration',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
          ),
        ),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.store_rounded,
                              color: Color(0xFF1B5E20), size: 24),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Fill in your business details to start placing orders on mediBO.',
                              style: TextStyle(
                                  fontSize: 13, color: Color(0xFF065F46)),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 28),

                    // ── Section 1: Business Details ───────────────────────
                    const _SectionHeader(
                        icon: Icons.storefront_outlined,
                        title: 'Business Details'),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'Customer / Contact Name',
                      required: true,
                      controller: _customerNameCtrl,
                      hint: 'Dr. Ramesh Kumar',
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Name is required'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'Pharmacy / Clinic Name',
                      required: true,
                      controller: _pharmacyCtrl,
                      hint: 'Apollo Pharmacy',
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Business name is required'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    _Dropdown(
                      label: 'Store Type',
                      required: true,
                      value: _storeType,
                      items: _storeTypes,
                      onChanged: (v) => setState(() => _storeType = v),
                      validator: (v) =>
                          v == null ? 'Select store type' : null,
                    ),
                    const SizedBox(height: 14),
                    _Dropdown(
                      label: 'Delivery Range / Zone',
                      required: true,
                      value: _rangeZone,
                      items: _rangeZones,
                      onChanged: (v) => setState(() => _rangeZone = v),
                      validator: (v) =>
                          v == null ? 'Select delivery range' : null,
                    ),

                    const SizedBox(height: 28),

                    // ── Section 2: Address ────────────────────────────────
                    const _SectionHeader(
                        icon: Icons.location_on_outlined, title: 'Address'),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'Local Address',
                      required: true,
                      controller: _addressCtrl,
                      hint: 'Shop 12, Medical Complex, MG Road',
                      maxLines: 2,
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Address is required'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _Field(
                            label: 'City',
                            required: true,
                            controller: _cityCtrl,
                            hint: 'Mumbai',
                            validator: (v) =>
                                (v == null || v.trim().isEmpty)
                                    ? 'Required'
                                    : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _Field(
                            label: 'State',
                            required: true,
                            controller: _stateCtrl,
                            hint: 'Maharashtra',
                            validator: (v) =>
                                (v == null || v.trim().isEmpty)
                                    ? 'Required'
                                    : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        SizedBox(
                          width: 160,
                          child: _Field(
                            label: 'Pincode',
                            required: true,
                            controller: _pincodeCtrl,
                            hint: '400001',
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(6),
                            ],
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return 'Required';
                              }
                              if (v.trim().length != 6) return '6 digits';
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'Store Location Link',
                      controller: _storeLocationCtrl,
                      hint: 'Google Maps link (optional)',
                      keyboardType: TextInputType.url,
                      capitalization: TextCapitalization.none,
                    ),

                    const SizedBox(height: 28),

                    // ── Section 3: Contact ────────────────────────────────
                    const _SectionHeader(
                        icon: Icons.phone_outlined, title: 'Contact'),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'WhatsApp Number',
                      required: true,
                      controller: _whatsappCtrl,
                      hint: '9876543210',
                      keyboardType: TextInputType.phone,
                      maxLength: 10,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(10),
                      ],
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        if (v.trim().length != 10) {
                          return '10-digit number required';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'Other Contact Number',
                      controller: _otherContactCtrl,
                      hint: '9876543210 (optional)',
                      keyboardType: TextInputType.phone,
                      maxLength: 10,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(10),
                      ],
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return null;
                        if (v.trim().length != 10) {
                          return '10-digit number required';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'Email Address',
                      required: widget.email.isEmpty,
                      controller: _emailCtrl,
                      hint: 'pharmacy@example.com',
                      keyboardType: TextInputType.emailAddress,
                      capitalization: TextCapitalization.none,
                      readOnly: widget.email.isNotEmpty,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        if (!v.trim().contains('@')) return 'Invalid email';
                        return null;
                      },
                    ),

                    const SizedBox(height: 28),

                    // ── Section 4: Drug Licenses ──────────────────────────
                    const _SectionHeader(
                        icon: Icons.verified_outlined, title: 'Drug Licenses'),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'DL 20B',
                      required: true,
                      controller: _dl20bCtrl,
                      hint: 'MH-MUM-123456',
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'DL 20B is required'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'DL 21B',
                      controller: _dl21bCtrl,
                      hint: 'MH-MUM-654321 (optional)',
                    ),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'GST Number',
                      controller: _gstCtrl,
                      hint: '27AAPFU0939F1ZV (optional)',
                      maxLength: 15,
                      capitalization: TextCapitalization.characters,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return null;
                        final gst = v.trim().toUpperCase();
                        if (!RegExp(
                                r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$')
                            .hasMatch(gst)) {
                          return 'Invalid GSTIN format';
                        }
                        return null;
                      },
                    ),

                    const SizedBox(height: 28),

                    // ── Section 5: Account Setup ──────────────────────────
                    const _SectionHeader(
                        icon: Icons.manage_accounts_outlined,
                        title: 'Account Setup'),
                    const SizedBox(height: 14),
                    _Dropdown(
                      label: 'Payment Term',
                      required: true,
                      value: _paymentTerm,
                      items: _paymentTerms,
                      onChanged: (v) => setState(() => _paymentTerm = v),
                      validator: (v) =>
                          v == null ? 'Select payment term' : null,
                    ),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'Customer Code',
                      required: true,
                      controller: _customerCodeCtrl,
                      hint: 'ABC123',
                      maxLength: 6,
                      capitalization: TextCapitalization.characters,
                      externalError: _customerCodeError,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(6),
                      ],
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        if (!RegExp(r'^[A-Za-z]{3}[0-9]{3}$')
                            .hasMatch(v.trim())) {
                          return '3 letters + 3 digits (e.g. ABC123)';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Format: 3 letters + 3 digits (e.g. ABC123). Must be unique across all accounts.',
                      style:
                          TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                    ),

                    if (_saveError != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _saveError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFFDC2626)),
                      ),
                    ],
                    const SizedBox(height: 28),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1B5E20),
                          disabledBackgroundColor:
                              const Color(0xFF1B5E20).withValues(alpha: 0.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        child: _saving
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                            : const Text('Submit Registration'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Your details are reviewed by our team. You will be approved within 24 hours.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Section header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;

  const _SectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xFF1B5E20)),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1B5E20),
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Divider(color: Color(0xFFD1FAE5), thickness: 1),
        ),
      ],
    );
  }
}

// ─── Text field ───────────────────────────────────────────────────────────────

class _Field extends StatelessWidget {
  final String label;
  final bool required;
  final TextEditingController controller;
  final String hint;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final int? maxLength;
  final int maxLines;
  final TextCapitalization capitalization;
  final List<TextInputFormatter>? inputFormatters;
  final String? externalError;
  final bool readOnly;

  const _Field({
    required this.label,
    this.required = false,
    required this.controller,
    required this.hint,
    this.validator,
    this.keyboardType,
    this.maxLength,
    this.maxLines = 1,
    this.capitalization = TextCapitalization.words,
    this.inputFormatters,
    this.externalError,
    this.readOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF374151),
                ),
              ),
              if (required)
                const TextSpan(
                  text: ' *',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFDC2626),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          maxLength: maxLength,
          maxLines: maxLines,
          textCapitalization: capitalization,
          inputFormatters: inputFormatters,
          validator: validator,
          readOnly: readOnly,
          style: TextStyle(
            fontSize: 14,
            color: readOnly
                ? const Color(0xFF6B7280)
                : const Color(0xFF111827),
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle:
                const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
            suffixIcon: readOnly
                ? const Icon(Icons.lock_outline,
                    size: 16, color: Color(0xFF9CA3AF))
                : null,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: readOnly
                  ? const BorderSide(color: Color(0xFFD1D5DB))
                  : const BorderSide(color: Color(0xFF1B5E20), width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFDC2626)),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: Color(0xFFDC2626), width: 1.5),
            ),
            counterText: '',
            filled: true,
            fillColor: readOnly
                ? const Color(0xFFF3F4F6)
                : const Color(0xFFFAFAFA),
          ),
        ),
        if (externalError != null) ...[
          const SizedBox(height: 4),
          Text(
            externalError!,
            style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626)),
          ),
        ],
      ],
    );
  }
}

// ─── Dropdown field ───────────────────────────────────────────────────────────

class _Dropdown extends StatelessWidget {
  final String label;
  final bool required;
  final String? value;
  final List<String> items;
  final void Function(String?) onChanged;
  final String? Function(String?)? validator;

  const _Dropdown({
    required this.label,
    this.required = false,
    required this.value,
    required this.items,
    required this.onChanged,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF374151),
                ),
              ),
              if (required)
                const TextSpan(
                  text: ' *',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFDC2626),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          decoration: InputDecoration(
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: Color(0xFF1B5E20), width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFDC2626)),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: Color(0xFFDC2626), width: 1.5),
            ),
            filled: true,
            fillColor: const Color(0xFFFAFAFA),
          ),
          hint: Text(
            'Select…',
            style:
                const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
          ),
          items: items
              .map((item) => DropdownMenuItem(
                    value: item,
                    child: Text(item,
                        style: const TextStyle(fontSize: 14)),
                  ))
              .toList(),
          onChanged: onChanged,
          validator: validator,
        ),
      ],
    );
  }
}
