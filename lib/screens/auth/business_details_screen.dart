import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/user_profile.dart';
import '../../user_state.dart';

class BusinessDetailsScreen extends StatefulWidget {
  final String userId;
  final String phone;

  const BusinessDetailsScreen({
    super.key,
    required this.userId,
    required this.phone,
  });

  @override
  State<BusinessDetailsScreen> createState() => _BusinessDetailsScreenState();
}

class _BusinessDetailsScreenState extends State<BusinessDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ownerCtrl = TextEditingController();
  final _pharmacyCtrl = TextEditingController();
  final _gstinCtrl = TextEditingController();
  final _dlCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _pincodeCtrl = TextEditingController();

  bool _saving = false;
  String? _saveError;

  @override
  void dispose() {
    _ownerCtrl.dispose();
    _pharmacyCtrl.dispose();
    _gstinCtrl.dispose();
    _dlCtrl.dispose();
    _addressCtrl.dispose();
    _cityCtrl.dispose();
    _pincodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final phone = widget.phone.isNotEmpty
          ? widget.phone
          : '+91${_pincodeCtrl.text}'; // fallback
      final profile = UserProfile(
        id: widget.userId,
        fullName: _ownerCtrl.text.trim(),
        businessName: _pharmacyCtrl.text.trim(),
        phone: phone,
        gstin: _gstinCtrl.text.trim().toUpperCase(),
        drugLicense: _dlCtrl.text.trim(),
        addressLine: _addressCtrl.text.trim(),
        city: _cityCtrl.text.trim(),
        pincode: _pincodeCtrl.text.trim(),
      );
      await UserState.read(context).saveProfile(profile);
      // AuthNotifier sets needsProfile=false → root auto-switches to HomeShell
    } catch (e) {
      if (mounted) setState(() => _saveError = 'Failed to save. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.store_rounded,
                              color: Color(0xFF1B5E20), size: 28),
                          SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Complete your profile',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Required to place orders on mediBO',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF374151),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Owner name
                    _Field(
                      label: 'Owner / Contact Name',
                      required: true,
                      controller: _ownerCtrl,
                      hint: 'Dr. Ramesh Kumar',
                      validator: (v) =>
                          (v == null || v.trim().isEmpty)
                              ? 'Owner name is required'
                              : null,
                    ),
                    const SizedBox(height: 16),
                    // Pharmacy name
                    _Field(
                      label: 'Pharmacy / Clinic Name',
                      required: true,
                      controller: _pharmacyCtrl,
                      hint: 'Apollo Pharmacy',
                      validator: (v) =>
                          (v == null || v.trim().isEmpty)
                              ? 'Business name is required'
                              : null,
                    ),
                    const SizedBox(height: 16),
                    // GSTIN
                    _Field(
                      label: 'GSTIN',
                      controller: _gstinCtrl,
                      hint: '27AAPFU0939F1ZV',
                      maxLength: 15,
                      capitalization: TextCapitalization.characters,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return null;
                        final gstin = v.trim().toUpperCase();
                        if (!RegExp(
                                r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$')
                            .hasMatch(gstin)) {
                          return 'Invalid GSTIN format';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    // Drug License
                    _Field(
                      label: 'Drug License Number',
                      controller: _dlCtrl,
                      hint: 'MH-MUM-123456',
                    ),
                    const SizedBox(height: 16),
                    // Address
                    _Field(
                      label: 'Full Address',
                      required: true,
                      controller: _addressCtrl,
                      hint: 'Shop 12, Medical Complex, MG Road',
                      maxLines: 2,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty)
                              ? 'Address is required'
                              : null,
                    ),
                    const SizedBox(height: 16),
                    // City + Pincode in a Row
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: _Field(
                            label: 'City',
                            required: true,
                            controller: _cityCtrl,
                            hint: 'Mumbai',
                            validator: (v) =>
                                (v == null || v.trim().isEmpty)
                                    ? 'City is required'
                                    : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
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
                              if (v.trim().length != 6) {
                                return '6 digits';
                              }
                              return null;
                            },
                          ),
                        ),
                      ],
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
                    // Save button
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
                            : const Text('Save & Continue'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Your details are used for order processing only.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 11, color: Color(0xFF9CA3AF)),
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

// ─── Reusable form field ──────────────────────────────────────────────────────

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
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF111827),
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(
              color: Color(0xFF9CA3AF),
              fontSize: 14,
            ),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 13),
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
            counterText: '',
            filled: true,
            fillColor: const Color(0xFFFAFAFA),
          ),
        ),
      ],
    );
  }
}
