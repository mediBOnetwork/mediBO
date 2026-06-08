import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/user_profile.dart';
import '../../user_state.dart';

// ─── Role enum ───────────────────────────────────────────────────────────────

enum _Role { pharmacy, supplier, mr, company, deliveryPartner }

extension _RoleX on _Role {
  String get label {
    switch (this) {
      case _Role.pharmacy: return 'Pharmacy';
      case _Role.supplier: return 'Supplier';
      case _Role.mr: return 'MR';
      case _Role.company: return 'Company';
      case _Role.deliveryPartner: return 'Delivery';
    }
  }

  IconData get icon {
    switch (this) {
      case _Role.pharmacy: return Icons.local_pharmacy;
      case _Role.supplier: return Icons.inventory_2_outlined;
      case _Role.mr: return Icons.person_outline;
      case _Role.company: return Icons.business_outlined;
      case _Role.deliveryPartner: return Icons.local_shipping;
    }
  }
}

enum _CodeStatus { idle, invalid, checking, available, taken }

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
  _Role _role = _Role.pharmacy;
  final _formKey = GlobalKey<FormState>();

  // ── Pharmacy fields ──────────────────────────────────────────────────────
  final _customerNameCtrl = TextEditingController();
  final _pharmacyCtrl = TextEditingController();
  String? _storeType;
  String? _rangeZone;
  final _addressCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _pincodeCtrl = TextEditingController();
  final _storeLocationCtrl = TextEditingController();
  final _whatsappCtrl = TextEditingController();
  final _otherContactCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _dl20bCtrl = TextEditingController();
  final _dl21bCtrl = TextEditingController();
  final _gstCtrl = TextEditingController();
  String? _paymentTerm;
  final _customerCodeCtrl = TextEditingController();
  _CodeStatus _codeStatus = _CodeStatus.idle;
  Timer? _codeDebounce;

  // ── Supplier fields ──────────────────────────────────────────────────────
  final _supCompanyCtrl = TextEditingController();
  final _supContactCtrl = TextEditingController();
  final _supPhoneCtrl = TextEditingController();
  final _supEmailCtrl = TextEditingController();
  final _supCityCtrl = TextEditingController();
  final _supStateCtrl = TextEditingController();
  final _supAddressCtrl = TextEditingController();
  final _supGstCtrl = TextEditingController();
  final _supDlCtrl = TextEditingController();
  final _supCategoriesCtrl = TextEditingController();

  // ── MR fields ────────────────────────────────────────────────────────────
  final _mrNameCtrl = TextEditingController();
  final _mrPhoneCtrl = TextEditingController();
  final _mrEmailCtrl = TextEditingController();
  final _mrCompanyCtrl = TextEditingController();
  final _mrTerritoryCtrl = TextEditingController();
  final _mrCityCtrl = TextEditingController();
  final _mrStateCtrl = TextEditingController();
  final _mrAddressCtrl = TextEditingController();
  String? _mrIdProofType;

  // ── Company fields ───────────────────────────────────────────────────────
  final _coNameCtrl = TextEditingController();
  final _coContactCtrl = TextEditingController();
  final _coPhoneCtrl = TextEditingController();
  final _coEmailCtrl = TextEditingController();
  final _coGstCtrl = TextEditingController();
  final _coDlCtrl = TextEditingController();
  final _coCategoriesCtrl = TextEditingController();
  final _coAddressCtrl = TextEditingController();
  final _coCityCtrl = TextEditingController();
  final _coStateCtrl = TextEditingController();
  final _coWebsiteCtrl = TextEditingController();

  // ── Delivery Partner fields ──────────────────────────────────────────────
  final _dpNameCtrl = TextEditingController();
  final _dpPhoneCtrl = TextEditingController();
  final _dpEmailCtrl = TextEditingController();
  String? _dpVehicleType;
  final _dpZoneCtrl = TextEditingController();
  final _dpCityCtrl = TextEditingController();
  final _dpStateCtrl = TextEditingController();
  final _dpAddressCtrl = TextEditingController();
  String? _dpIdProofType;

  bool _saving = false;
  String? _saveError;

  // ── Static option lists ──────────────────────────────────────────────────
  static const _storeTypes = ['Retail Pharmacy', 'Hospital Pharmacy', 'Clinic', 'Wholesale Distributor', 'Other'];
  static const _rangeZones = ['Local (0–25 km)', 'City (25–50 km)', 'District (50–100 km)', 'Regional (100+ km)'];
  static const _paymentTerms = ['Advance Payment', 'COD'];
  static const _idProofTypes = ['Aadhaar Card', 'PAN Card', 'Driving Licence', 'Passport', 'Voter ID'];
  static const _vehicleTypes = ['Two-Wheeler (Bike/Scooter)', 'Three-Wheeler (Auto)', 'Four-Wheeler (Car/Van)', 'Bicycle'];

  @override
  void initState() {
    super.initState();
    final stripped = widget.phone.replaceAll('+91', '').trim();
    if (stripped.length == 10) {
      _whatsappCtrl.text = stripped;
      _supPhoneCtrl.text = stripped;
      _mrPhoneCtrl.text = stripped;
      _coPhoneCtrl.text = stripped;
      _dpPhoneCtrl.text = stripped;
    }
    if (widget.email.isNotEmpty) {
      _emailCtrl.text = widget.email;
      _supEmailCtrl.text = widget.email;
      _mrEmailCtrl.text = widget.email;
      _coEmailCtrl.text = widget.email;
      _dpEmailCtrl.text = widget.email;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _customerNameCtrl, _pharmacyCtrl, _addressCtrl, _cityCtrl, _stateCtrl,
      _pincodeCtrl, _storeLocationCtrl, _whatsappCtrl, _otherContactCtrl,
      _emailCtrl, _dl20bCtrl, _dl21bCtrl, _gstCtrl, _customerCodeCtrl,
      _supCompanyCtrl, _supContactCtrl, _supPhoneCtrl, _supEmailCtrl,
      _supCityCtrl, _supStateCtrl, _supAddressCtrl, _supGstCtrl, _supDlCtrl,
      _supCategoriesCtrl, _mrNameCtrl, _mrPhoneCtrl, _mrEmailCtrl,
      _mrCompanyCtrl, _mrTerritoryCtrl, _mrCityCtrl, _mrStateCtrl, _mrAddressCtrl,
      _coNameCtrl, _coContactCtrl, _coPhoneCtrl, _coEmailCtrl, _coGstCtrl,
      _coDlCtrl, _coCategoriesCtrl, _coAddressCtrl, _coCityCtrl, _coStateCtrl,
      _coWebsiteCtrl, _dpNameCtrl, _dpPhoneCtrl, _dpEmailCtrl, _dpZoneCtrl,
      _dpCityCtrl, _dpStateCtrl, _dpAddressCtrl,
    ]) c.dispose();
    _codeDebounce?.cancel();
    super.dispose();
  }

  // ── Pharmacy code check ──────────────────────────────────────────────────
  void _onCodeChanged(String value) {
    final raw = value.trim().toUpperCase();
    if (raw.isEmpty) { _codeDebounce?.cancel(); setState(() => _codeStatus = _CodeStatus.idle); return; }
    if (!RegExp(r'^[A-Za-z]{3}[0-9]{3}$').hasMatch(raw)) { _codeDebounce?.cancel(); setState(() => _codeStatus = _CodeStatus.invalid); return; }
    setState(() => _codeStatus = _CodeStatus.checking);
    _codeDebounce?.cancel();
    _codeDebounce = Timer(const Duration(milliseconds: 350), () => _checkCode(raw));
  }

  Future<void> _checkCode(String code) async {
    try {
      final taken = await Supabase.instance.client.rpc('is_customer_code_taken', params: {'p_code': code}) as bool;
      if (!mounted) return;
      if (_customerCodeCtrl.text.trim().toUpperCase() != code) return;
      setState(() => _codeStatus = taken ? _CodeStatus.taken : _CodeStatus.available);
    } catch (_) { if (mounted) setState(() => _codeStatus = _CodeStatus.idle); }
  }

  bool get _blockedByCode {
    if (_customerCodeCtrl.text.trim().isEmpty) return false;
    return _codeStatus == _CodeStatus.invalid || _codeStatus == _CodeStatus.checking || _codeStatus == _CodeStatus.taken;
  }

  // ── Submit routing ───────────────────────────────────────────────────────
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _saveError = null; });
    try {
      switch (_role) {
        case _Role.pharmacy: await _savePharmacy(); break;
        case _Role.supplier: await _saveSupplier(); break;
        case _Role.mr: await _saveMr(); break;
        case _Role.company: await _saveCompany(); break;
        case _Role.deliveryPartner: await _saveDeliveryPartner(); break;
      }
      if (mounted) Navigator.of(context).pop();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      if (e.code == '23505') setState(() => _codeStatus = _CodeStatus.taken);
      else setState(() => _saveError = '[${e.code}] ${e.message}');
    } catch (e) { if (mounted) setState(() => _saveError = e.toString()); }
    finally { if (mounted) setState(() => _saving = false); }
  }

  Future<void> _savePharmacy() async {
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
      storeLocationLink: _storeLocationCtrl.text.trim().isNotEmpty ? _storeLocationCtrl.text.trim() : null,
      whatsappNo: _whatsappCtrl.text.trim(),
      otherContactNo: _otherContactCtrl.text.trim(),
      email: _emailCtrl.text.trim(),
      dl20b: _dl20bCtrl.text.trim(),
      dl21b: _dl21bCtrl.text.trim().isNotEmpty ? _dl21bCtrl.text.trim() : null,
      gstNo: _gstCtrl.text.trim().isNotEmpty ? _gstCtrl.text.trim().toUpperCase() : null,
      paymentTerm: _paymentTerm!,
      customerCode: _customerCodeCtrl.text.trim().toUpperCase(),
    );
    await UserState.read(context).saveProfile(profile);
  }

  Future<void> _saveSupplier() async {
    await Supabase.instance.client.from('supplier_profiles').insert({
      'user_id': widget.userId,
      'supplier_name': _supCompanyCtrl.text.trim(),
      'contact_name': _supContactCtrl.text.trim(),
      'phone': _supPhoneCtrl.text.trim(),
      'whatsapp_no': _supPhoneCtrl.text.trim(),
      'email': _supEmailCtrl.text.trim(),
      'city': _supCityCtrl.text.trim(),
      'state': _supStateCtrl.text.trim(),
      'address': _supAddressCtrl.text.trim(),
      'gstin': _supGstCtrl.text.trim().isNotEmpty ? _supGstCtrl.text.trim().toUpperCase() : null,
      'drug_license': _supDlCtrl.text.trim().isNotEmpty ? _supDlCtrl.text.trim() : null,
      'notes': _supCategoriesCtrl.text.trim().isNotEmpty ? 'Product Categories: ${_supCategoriesCtrl.text.trim()}' : null,
      'status': 'pending',
      'approved': false,
    });
  }

  Future<void> _saveMr() async {
    await Supabase.instance.client.from('mr_registrations').insert({
      'user_id': widget.userId,
      'full_name': _mrNameCtrl.text.trim(),
      'phone': _mrPhoneCtrl.text.trim(),
      'email': _mrEmailCtrl.text.trim(),
      'company_represented': _mrCompanyCtrl.text.trim(),
      'territory_zone': _mrTerritoryCtrl.text.trim(),
      'city': _mrCityCtrl.text.trim(),
      'state': _mrStateCtrl.text.trim(),
      'address': _mrAddressCtrl.text.trim().isNotEmpty ? _mrAddressCtrl.text.trim() : null,
      'id_proof_type': _mrIdProofType,
      'status': 'pending',
    });
  }

  Future<void> _saveCompany() async {
    await Supabase.instance.client.from('company_profiles').insert({
      'user_id': widget.userId,
      'company_name': _coNameCtrl.text.trim(),
      'contact_person': _coContactCtrl.text.trim(),
      'phone': _coPhoneCtrl.text.trim(),
      'email': _coEmailCtrl.text.trim(),
      'gst_no': _coGstCtrl.text.trim().isNotEmpty ? _coGstCtrl.text.trim().toUpperCase() : null,
      'drug_license': _coDlCtrl.text.trim().isNotEmpty ? _coDlCtrl.text.trim() : null,
      'product_categories': _coCategoriesCtrl.text.trim().isNotEmpty ? _coCategoriesCtrl.text.trim() : null,
      'registered_address': _coAddressCtrl.text.trim(),
      'city': _coCityCtrl.text.trim(),
      'state': _coStateCtrl.text.trim(),
      'website': _coWebsiteCtrl.text.trim().isNotEmpty ? _coWebsiteCtrl.text.trim() : null,
      'status': 'pending',
    });
  }

  Future<void> _saveDeliveryPartner() async {
    await Supabase.instance.client.from('delivery_partner_registrations').insert({
      'user_id': widget.userId,
      'full_name': _dpNameCtrl.text.trim(),
      'phone': _dpPhoneCtrl.text.trim(),
      'email': _dpEmailCtrl.text.trim(),
      'vehicle_type': _dpVehicleType!,
      'delivery_zone': _dpZoneCtrl.text.trim(),
      'city': _dpCityCtrl.text.trim(),
      'state': _dpStateCtrl.text.trim(),
      'address': _dpAddressCtrl.text.trim().isNotEmpty ? _dpAddressCtrl.text.trim() : null,
      'id_proof_type': _dpIdProofType,
      'status': 'pending',
    });
  }

  // ── Pharmacy code status widget ──────────────────────────────────────────
  Widget _buildCodeStatus() {
    switch (_codeStatus) {
      case _CodeStatus.idle: return Padding(padding: const EdgeInsets.only(top: 6), child: Text('Format: 3 letters + 3 digits (e.g. ABC123). Must be unique.', style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))));
      case _CodeStatus.invalid: return _codeStatusRow(icon: Icons.error_outline, color: const Color(0xFFDC2626), text: '3 letters + 3 digits (e.g. ABC123)');
      case _CodeStatus.checking: return const Padding(padding: EdgeInsets.only(top: 6), child: Row(children: [SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF6B7280))), SizedBox(width: 6), Text('Checking availability…', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)))]));
      case _CodeStatus.available: return _codeStatusRow(icon: Icons.check_circle_outline, color: const Color(0xFF16A34A), text: 'Available');
      case _CodeStatus.taken: return _codeStatusRow(icon: Icons.cancel_outlined, color: const Color(0xFFDC2626), text: 'Already taken — choose a different code');
    }
  }

  Widget _codeStatusRow({required IconData icon, required Color color, required String text}) {
    return Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [Icon(icon, size: 14, color: color), const SizedBox(width: 4), Flexible(child: Text(text, style: TextStyle(fontSize: 12, color: color)))]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.close, color: Color(0xFF1B5E20)), onPressed: () => Navigator.of(context).pop()),
        title: const Text('Complete Registration', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
        centerTitle: false,
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(height: 1, color: const Color(0xFFE5E7EB))),
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
                    // ── Role selector ─────────────────────────────────────
                    _buildRoleSelector(),
                    const SizedBox(height: 20),

                    // ── Info banner ───────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(10)),
                      child: Row(children: [
                        Icon(_role.icon, color: const Color(0xFF1B5E20), size: 22),
                        const SizedBox(width: 10),
                        Expanded(child: Text('Fill in your ${_role.label} details to register on mediBO.', style: const TextStyle(fontSize: 13, color: Color(0xFF065F46)))),
                      ]),
                    ),
                    const SizedBox(height: 24),

                    // ── Role-specific form ────────────────────────────────
                    if (_role == _Role.pharmacy) ..._buildPharmacyForm(),
                    if (_role == _Role.supplier) ..._buildSupplierForm(),
                    if (_role == _Role.mr) ..._buildMrForm(),
                    if (_role == _Role.company) ..._buildCompanyForm(),
                    if (_role == _Role.deliveryPartner) ..._buildDeliveryForm(),

                    if (_saveError != null) ...[
                      const SizedBox(height: 16),
                      Text(_saveError!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Color(0xFFDC2626))),
                    ],
                    const SizedBox(height: 28),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: (_saving || (_role == _Role.pharmacy && _blockedByCode)) ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1B5E20),
                          disabledBackgroundColor: const Color(0xFF1B5E20).withValues(alpha: 0.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        child: _saving
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                            : const Text('Submit Registration'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Your details are reviewed by our team. You will be approved within 24 hours.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Role selector ──────────────────────────────────────────────────────
  Widget _buildRoleSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _Role.values.map((r) {
          final selected = _role == r;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setState(() {
                _role = r;
                _saveError = null;
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFF1B5E20) : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: selected ? const Color(0xFF1B5E20) : const Color(0xFFE5E7EB)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(r.icon, size: 16, color: selected ? Colors.white : const Color(0xFF6B7280)),
                  const SizedBox(width: 6),
                  Text(r.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? Colors.white : const Color(0xFF374151))),
                ]),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Pharmacy form (unchanged) ──────────────────────────────────────────
  List<Widget> _buildPharmacyForm() => [
    const _SectionHeader(icon: Icons.storefront_outlined, title: 'Business Details'),
    const SizedBox(height: 14),
    _Field(label: 'Customer / Contact Name', required: true, controller: _customerNameCtrl, hint: 'Dr. Ramesh Kumar', validator: (v) => (v == null || v.trim().isEmpty) ? 'Name is required' : null),
    const SizedBox(height: 14),
    _Field(label: 'Pharmacy / Clinic Name', required: true, controller: _pharmacyCtrl, hint: 'Apollo Pharmacy', validator: (v) => (v == null || v.trim().isEmpty) ? 'Business name is required' : null),
    const SizedBox(height: 14),
    _Dropdown(label: 'Store Type', required: true, value: _storeType, items: _storeTypes, onChanged: (v) => setState(() => _storeType = v), validator: (v) => v == null ? 'Select store type' : null),
    const SizedBox(height: 14),
    _Dropdown(label: 'Delivery Range / Zone', required: true, value: _rangeZone, items: _rangeZones, onChanged: (v) => setState(() => _rangeZone = v), validator: (v) => v == null ? 'Select delivery range' : null),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.location_on_outlined, title: 'Address'),
    const SizedBox(height: 14),
    _Field(label: 'Local Address', required: true, controller: _addressCtrl, hint: 'Shop 12, Medical Complex, MG Road', maxLines: 2, validator: (v) => (v == null || v.trim().isEmpty) ? 'Address is required' : null),
    const SizedBox(height: 14),
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _Field(label: 'City', required: true, controller: _cityCtrl, hint: 'Mumbai', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null)),
      const SizedBox(width: 12),
      Expanded(child: _Field(label: 'State', required: true, controller: _stateCtrl, hint: 'Maharashtra', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null)),
    ]),
    const SizedBox(height: 14),
    Row(children: [SizedBox(width: 160, child: _Field(label: 'Pincode', required: true, controller: _pincodeCtrl, hint: '400001', keyboardType: TextInputType.number, maxLength: 6, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)], validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (v.trim().length != 6) return '6 digits'; return null; }))]),
    const SizedBox(height: 14),
    _Field(label: 'Store Location Link', controller: _storeLocationCtrl, hint: 'Google Maps link (optional)', keyboardType: TextInputType.url, capitalization: TextCapitalization.none),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.phone_outlined, title: 'Contact'),
    const SizedBox(height: 14),
    _Field(label: 'WhatsApp Number', required: true, controller: _whatsappCtrl, hint: '9876543210', keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (v.trim().length != 10) return '10-digit number required'; return null; }),
    const SizedBox(height: 14),
    _Field(label: 'Other Contact Number', controller: _otherContactCtrl, hint: '9876543210 (optional)', keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return null; if (v.trim().length != 10) return '10-digit number required'; return null; }),
    const SizedBox(height: 14),
    _Field(label: 'Email Address', required: widget.email.isEmpty, controller: _emailCtrl, hint: 'pharmacy@example.com', keyboardType: TextInputType.emailAddress, capitalization: TextCapitalization.none, readOnly: widget.email.isNotEmpty, validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (!v.trim().contains('@')) return 'Invalid email'; return null; }),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.verified_outlined, title: 'Drug Licenses'),
    const SizedBox(height: 14),
    _Field(label: 'DL 20B', required: true, controller: _dl20bCtrl, hint: 'MH-MUM-123456', validator: (v) => (v == null || v.trim().isEmpty) ? 'DL 20B is required' : null),
    const SizedBox(height: 14),
    _Field(label: 'DL 21B', controller: _dl21bCtrl, hint: 'MH-MUM-654321 (optional)'),
    const SizedBox(height: 14),
    _Field(label: 'GST Number', controller: _gstCtrl, hint: '27AAPFU0939F1ZV (optional)', maxLength: 15, capitalization: TextCapitalization.characters, validator: (v) { if (v == null || v.trim().isEmpty) return null; final gst = v.trim().toUpperCase(); if (!RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$').hasMatch(gst)) return 'Invalid GSTIN format'; return null; }),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.manage_accounts_outlined, title: 'Account Setup'),
    const SizedBox(height: 14),
    _Dropdown(label: 'Payment Term', required: true, value: _paymentTerm, items: _paymentTerms, onChanged: (v) => setState(() => _paymentTerm = v), validator: (v) => v == null ? 'Select payment term' : null),
    const SizedBox(height: 14),
    _Field(label: 'Customer Code', required: true, controller: _customerCodeCtrl, hint: 'ABC123', maxLength: 6, capitalization: TextCapitalization.characters, onChanged: _onCodeChanged, inputFormatters: [LengthLimitingTextInputFormatter(6)], validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (!RegExp(r'^[A-Za-z]{3}[0-9]{3}$').hasMatch(v.trim())) return '3 letters + 3 digits (e.g. ABC123)'; return null; }),
    _buildCodeStatus(),
  ];

  // ── Supplier form ──────────────────────────────────────────────────────
  List<Widget> _buildSupplierForm() => [
    const _SectionHeader(icon: Icons.business_outlined, title: 'Company Details'),
    const SizedBox(height: 14),
    _Field(label: 'Company / Business Name', required: true, controller: _supCompanyCtrl, hint: 'Medico Pharma Ltd.', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 14),
    _Field(label: 'Contact Name', required: true, controller: _supContactCtrl, hint: 'Rajesh Sharma', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 14),
    _Field(label: 'Phone / WhatsApp', required: true, controller: _supPhoneCtrl, hint: '9876543210', keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (v.trim().length != 10) return '10-digit required'; return null; }),
    const SizedBox(height: 14),
    _Field(label: 'Email Address', required: widget.email.isEmpty, controller: _supEmailCtrl, hint: 'contact@company.com', keyboardType: TextInputType.emailAddress, capitalization: TextCapitalization.none, readOnly: widget.email.isNotEmpty, validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (!v.trim().contains('@')) return 'Invalid email'; return null; }),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.location_on_outlined, title: 'Address'),
    const SizedBox(height: 14),
    _Field(label: 'Address', required: true, controller: _supAddressCtrl, hint: 'Plot 5, Industrial Area, Phase 2', maxLines: 2, validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 14),
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _Field(label: 'City', required: true, controller: _supCityCtrl, hint: 'Ahmedabad', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null)),
      const SizedBox(width: 12),
      Expanded(child: _Field(label: 'State', required: true, controller: _supStateCtrl, hint: 'Gujarat', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null)),
    ]),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.verified_outlined, title: 'Compliance (Optional)'),
    const SizedBox(height: 14),
    _Field(label: 'GST Number', controller: _supGstCtrl, hint: '24AAPFU0939F1ZV (optional)', maxLength: 15, capitalization: TextCapitalization.characters),
    const SizedBox(height: 14),
    _Field(label: 'Drug License Number', controller: _supDlCtrl, hint: 'GJ-AHM-123456 (optional)'),
    const SizedBox(height: 14),
    _Field(label: 'Product Categories Supplied', controller: _supCategoriesCtrl, hint: 'e.g. Antibiotics, Cardiovascular, OTC…', maxLines: 2),
  ];

  // ── MR form ────────────────────────────────────────────────────────────
  List<Widget> _buildMrForm() => [
    const _SectionHeader(icon: Icons.person_outlined, title: 'Personal Details'),
    const SizedBox(height: 14),
    _Field(label: 'Full Name', required: true, controller: _mrNameCtrl, hint: 'Amit Verma', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 14),
    _Field(label: 'Phone', required: true, controller: _mrPhoneCtrl, hint: '9876543210', keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (v.trim().length != 10) return '10-digit required'; return null; }),
    const SizedBox(height: 14),
    _Field(label: 'Email Address', required: widget.email.isEmpty, controller: _mrEmailCtrl, hint: 'mr@company.com', keyboardType: TextInputType.emailAddress, capitalization: TextCapitalization.none, readOnly: widget.email.isNotEmpty, validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (!v.trim().contains('@')) return 'Invalid email'; return null; }),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.work_outlined, title: 'Professional Details'),
    const SizedBox(height: 14),
    _Field(label: 'Company / Pharma Represented', required: true, controller: _mrCompanyCtrl, hint: 'Sun Pharma, Cipla, etc.', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 14),
    _Field(label: 'Territory / Zone', required: true, controller: _mrTerritoryCtrl, hint: 'e.g. Mumbai West, Gujarat North', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.location_on_outlined, title: 'Location'),
    const SizedBox(height: 14),
    _Field(label: 'Address', controller: _mrAddressCtrl, hint: 'Residential / Office address (optional)', maxLines: 2),
    const SizedBox(height: 14),
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _Field(label: 'City', required: true, controller: _mrCityCtrl, hint: 'Mumbai', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null)),
      const SizedBox(width: 12),
      Expanded(child: _Field(label: 'State', required: true, controller: _mrStateCtrl, hint: 'Maharashtra', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null)),
    ]),
    const SizedBox(height: 14),
    _Dropdown(label: 'ID Proof Type', value: _mrIdProofType, items: _idProofTypes, onChanged: (v) => setState(() => _mrIdProofType = v)),
  ];

  // ── Company form ───────────────────────────────────────────────────────
  List<Widget> _buildCompanyForm() => [
    const _SectionHeader(icon: Icons.business_outlined, title: 'Company Details'),
    const SizedBox(height: 14),
    _Field(label: 'Company Name', required: true, controller: _coNameCtrl, hint: 'ABC Pharmaceuticals Pvt. Ltd.', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 14),
    _Field(label: 'Contact Person', required: true, controller: _coContactCtrl, hint: 'Priya Gupta', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 14),
    _Field(label: 'Phone', required: true, controller: _coPhoneCtrl, hint: '9876543210', keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (v.trim().length != 10) return '10-digit required'; return null; }),
    const SizedBox(height: 14),
    _Field(label: 'Email Address', required: widget.email.isEmpty, controller: _coEmailCtrl, hint: 'info@company.com', keyboardType: TextInputType.emailAddress, capitalization: TextCapitalization.none, readOnly: widget.email.isNotEmpty, validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (!v.trim().contains('@')) return 'Invalid email'; return null; }),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.verified_outlined, title: 'Compliance'),
    const SizedBox(height: 14),
    _Field(label: 'GST Number', controller: _coGstCtrl, hint: '27AAPFU0939F1ZV (optional)', maxLength: 15, capitalization: TextCapitalization.characters),
    const SizedBox(height: 14),
    _Field(label: 'Drug License', controller: _coDlCtrl, hint: 'MH-MUM-123456 (optional)'),
    const SizedBox(height: 14),
    _Field(label: 'Product Categories', controller: _coCategoriesCtrl, hint: 'e.g. OTC, Prescription, Surgical, Diagnostic…', maxLines: 2),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.location_on_outlined, title: 'Registered Address'),
    const SizedBox(height: 14),
    _Field(label: 'Registered Address', required: true, controller: _coAddressCtrl, hint: 'Plot 12, Pharma Zone, MIDC', maxLines: 2, validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 14),
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _Field(label: 'City', required: true, controller: _coCityCtrl, hint: 'Pune', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null)),
      const SizedBox(width: 12),
      Expanded(child: _Field(label: 'State', required: true, controller: _coStateCtrl, hint: 'Maharashtra', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null)),
    ]),
    const SizedBox(height: 14),
    _Field(label: 'Website', controller: _coWebsiteCtrl, hint: 'https://company.com (optional)', keyboardType: TextInputType.url, capitalization: TextCapitalization.none),
  ];

  // ── Delivery Partner form ──────────────────────────────────────────────
  List<Widget> _buildDeliveryForm() => [
    const _SectionHeader(icon: Icons.person_outlined, title: 'Personal Details'),
    const SizedBox(height: 14),
    _Field(label: 'Full Name', required: true, controller: _dpNameCtrl, hint: 'Suresh Kumar', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 14),
    _Field(label: 'Phone', required: true, controller: _dpPhoneCtrl, hint: '9876543210', keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (v.trim().length != 10) return '10-digit required'; return null; }),
    const SizedBox(height: 14),
    _Field(label: 'Email Address', required: widget.email.isEmpty, controller: _dpEmailCtrl, hint: 'partner@email.com', keyboardType: TextInputType.emailAddress, capitalization: TextCapitalization.none, readOnly: widget.email.isNotEmpty, validator: (v) { if (v == null || v.trim().isEmpty) return 'Required'; if (!v.trim().contains('@')) return 'Invalid email'; return null; }),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.delivery_dining_outlined, title: 'Delivery Details'),
    const SizedBox(height: 14),
    _Dropdown(label: 'Vehicle Type', required: true, value: _dpVehicleType, items: _vehicleTypes, onChanged: (v) => setState(() => _dpVehicleType = v), validator: (v) => v == null ? 'Select vehicle type' : null),
    const SizedBox(height: 14),
    _Field(label: 'Delivery Zone / Area', required: true, controller: _dpZoneCtrl, hint: 'e.g. South Mumbai, Andheri-Kurla', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null),
    const SizedBox(height: 28),
    const _SectionHeader(icon: Icons.location_on_outlined, title: 'Location'),
    const SizedBox(height: 14),
    _Field(label: 'Address', controller: _dpAddressCtrl, hint: 'Residential address (optional)', maxLines: 2),
    const SizedBox(height: 14),
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _Field(label: 'City', required: true, controller: _dpCityCtrl, hint: 'Mumbai', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null)),
      const SizedBox(width: 12),
      Expanded(child: _Field(label: 'State', required: true, controller: _dpStateCtrl, hint: 'Maharashtra', validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null)),
    ]),
    const SizedBox(height: 14),
    _Dropdown(label: 'ID Proof Type', value: _dpIdProofType, items: _idProofTypes, onChanged: (v) => setState(() => _dpIdProofType = v)),
  ];
}

// ─── Section header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _SectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 16, color: const Color(0xFF1B5E20)),
      const SizedBox(width: 8),
      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF1B5E20))),
      const SizedBox(width: 12),
      const Expanded(child: Divider(color: Color(0xFFD1FAE5), thickness: 1)),
    ]);
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
  final bool readOnly;
  final void Function(String)? onChanged;

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
    this.readOnly = false,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      RichText(text: TextSpan(children: [
        TextSpan(text: label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
        if (required) const TextSpan(text: ' *', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFDC2626))),
      ])),
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
        onChanged: onChanged,
        style: TextStyle(fontSize: 14, color: readOnly ? const Color(0xFF6B7280) : const Color(0xFF111827)),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
          suffixIcon: readOnly ? const Icon(Icons.lock_outline, size: 16, color: Color(0xFF9CA3AF)) : null,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: readOnly ? const BorderSide(color: Color(0xFFD1D5DB)) : const BorderSide(color: Color(0xFF1B5E20), width: 1.5)),
          errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFDC2626))),
          focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFDC2626), width: 1.5)),
          counterText: '',
          filled: true,
          fillColor: readOnly ? const Color(0xFFF3F4F6) : const Color(0xFFFAFAFA),
        ),
      ),
    ]);
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      RichText(text: TextSpan(children: [
        TextSpan(text: label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
        if (required) const TextSpan(text: ' *', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFDC2626))),
      ])),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B5E20), width: 1.5)),
          errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFDC2626))),
          focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFDC2626), width: 1.5)),
          filled: true,
          fillColor: const Color(0xFFFAFAFA),
        ),
        hint: const Text('Select…', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 14)),
        items: items.map((item) => DropdownMenuItem(value: item, child: Text(item, style: const TextStyle(fontSize: 14)))).toList(),
        onChanged: onChanged,
        validator: validator,
      ),
    ]);
  }
}
