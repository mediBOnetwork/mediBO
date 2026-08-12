import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/user_profile.dart';
import '../../services/ui_copy.dart';
import '../../user_state.dart';
import '../../utils/render_log.dart';
import '../../widgets/code_field.dart';

// ─── Role enum ───────────────────────────────────────────────────────────────

enum _Role { pharmacy, supplier, mr, company, deliveryPartner }

extension _RoleX on _Role {
  String get label {
    switch (this) {
      case _Role.pharmacy: return c('business_details.role_pharmacy');
      case _Role.supplier: return c('business_details.role_supplier');
      case _Role.mr: return c('business_details.role_mr');
      case _Role.company: return c('business_details.role_company');
      case _Role.deliveryPartner: return c('business_details.role_delivery');
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
  CodeStatus _customerCodeStatus = CodeStatus.idle;

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
  final _supplierCodeCtrl = TextEditingController();
  CodeStatus _supplierCodeStatus = CodeStatus.idle;

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
  List<String> get _storeTypes => [
    c('business_details.store_type_retail'),
    c('business_details.store_type_hospital'),
    c('business_details.store_type_clinic'),
    c('business_details.store_type_wholesale'),
    c('business_details.store_type_other'),
  ];
  List<String> get _rangeZones => [
    c('business_details.range_local'),
    c('business_details.range_city'),
    c('business_details.range_district'),
    c('business_details.range_regional'),
  ];
  List<String> get _paymentTerms => [
    c('business_details.payment_advance'),
    c('business_details.payment_cod'),
  ];
  List<String> get _idProofTypes => [
    c('business_details.id_proof_aadhaar'),
    c('business_details.id_proof_pan'),
    c('business_details.id_proof_dl'),
    c('business_details.id_proof_passport'),
    c('business_details.id_proof_voter'),
  ];
  List<String> get _vehicleTypes => [
    c('business_details.vehicle_two_wheeler'),
    c('business_details.vehicle_three_wheeler'),
    c('business_details.vehicle_four_wheeler'),
    c('business_details.vehicle_bicycle'),
  ];

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
      _supCategoriesCtrl, _supplierCodeCtrl, _mrNameCtrl, _mrPhoneCtrl, _mrEmailCtrl,
      _mrCompanyCtrl, _mrTerritoryCtrl, _mrCityCtrl, _mrStateCtrl, _mrAddressCtrl,
      _coNameCtrl, _coContactCtrl, _coPhoneCtrl, _coEmailCtrl, _coGstCtrl,
      _coDlCtrl, _coCategoriesCtrl, _coAddressCtrl, _coCityCtrl, _coStateCtrl,
      _coWebsiteCtrl, _dpNameCtrl, _dpPhoneCtrl, _dpEmailCtrl, _dpZoneCtrl,
      _dpCityCtrl, _dpStateCtrl, _dpAddressCtrl,
    ]) c.dispose();
    super.dispose();
  }

  // ── Code availability helpers ────────────────────────────────────────────
  bool get _blockedByCode {
    if (_customerCodeCtrl.text.trim().isEmpty) return false;
    return _customerCodeStatus == CodeStatus.invalid ||
        _customerCodeStatus == CodeStatus.checking ||
        _customerCodeStatus == CodeStatus.taken;
  }

  bool get _blockedBySupCode {
    if (_supplierCodeCtrl.text.trim().isEmpty) return false;
    return _supplierCodeStatus == CodeStatus.invalid ||
        _supplierCodeStatus == CodeStatus.checking ||
        _supplierCodeStatus == CodeStatus.taken;
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
      if (e.code == '23505') {
        if (_role == _Role.pharmacy) setState(() => _customerCodeStatus = CodeStatus.taken);
        else if (_role == _Role.supplier) setState(() => _supplierCodeStatus = CodeStatus.taken);
      } else {
        setState(() => _saveError = '[${e.code}] ${e.message}');
      }
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
    // #571 — goes through save_customer_profile(), which keys the write to the
    // ACCOUNT and refuses any client-supplied approval flag.
    await UserState.read(context).saveProfile(profile.toInsertJson());
  }

  Future<void> _saveSupplier() async {
    final code = _supplierCodeCtrl.text.trim().toUpperCase();
    try { RenderLog.write('c307_saved_code', 'code=$code'); } catch (_) {}
    // CHANGE #579 — submit_registration() writes the row.
    //
    // This INSERTed into supplier_profiles directly with
    // {'status':'pending','approved':false} sent FROM THE CLIENT. The values
    // happened to be the safe ones, but nothing stopped a caller sending
    // approved:true straight into the table — and `approved` is what
    // my_session().can_place_order reads. The RPC sets status and approved
    // itself, keys the row to auth.uid() rather than a widget-supplied
    // user_id, and reports any privilege key it refused.
    await Supabase.instance.client.rpc('submit_registration', params: {
      'p_kind': 'supplier',
      'p_payload': <String, dynamic>{
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
      if (code.isNotEmpty) 'supplier_code': code,
      },
    });
  }

  Future<void> _saveMr() async {
    await Supabase.instance.client.rpc('submit_registration', params: {
      'p_kind': 'mr',
      'p_payload': <String, dynamic>{
      'full_name': _mrNameCtrl.text.trim(),
      'phone': _mrPhoneCtrl.text.trim(),
      'email': _mrEmailCtrl.text.trim(),
      'company_represented': _mrCompanyCtrl.text.trim(),
      'territory_zone': _mrTerritoryCtrl.text.trim(),
      'city': _mrCityCtrl.text.trim(),
      'state': _mrStateCtrl.text.trim(),
      'address': _mrAddressCtrl.text.trim().isNotEmpty ? _mrAddressCtrl.text.trim() : null,
      'id_proof_type': _mrIdProofType,
      },
    });
  }

  Future<void> _saveCompany() async {
    await Supabase.instance.client.rpc('submit_registration', params: {
      'p_kind': 'company',
      'p_payload': <String, dynamic>{
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
      },
    });
  }

  Future<void> _saveDeliveryPartner() async {
    await Supabase.instance.client.rpc('submit_registration', params: {
      'p_kind': 'delivery_partner',
      'p_payload': <String, dynamic>{
      'full_name': _dpNameCtrl.text.trim(),
      'phone': _dpPhoneCtrl.text.trim(),
      'email': _dpEmailCtrl.text.trim(),
      'vehicle_type': _dpVehicleType!,
      'delivery_zone': _dpZoneCtrl.text.trim(),
      'city': _dpCityCtrl.text.trim(),
      'state': _dpStateCtrl.text.trim(),
      'address': _dpAddressCtrl.text.trim().isNotEmpty ? _dpAddressCtrl.text.trim() : null,
      'id_proof_type': _dpIdProofType,
      },
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.close, color: Color(0xFF1B5E20)), onPressed: () => Navigator.of(context).pop()),
        title: Text(c('business_details.app_bar_title'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
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
                        Expanded(child: Text(cf('business_details.info_banner', {'role': _role.label}), style: const TextStyle(fontSize: 13, color: Color(0xFF065F46)))),
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
                        onPressed: (_saving || (_role == _Role.pharmacy && _blockedByCode) || (_role == _Role.supplier && _blockedBySupCode)) ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1B5E20),
                          disabledBackgroundColor: const Color(0xFF1B5E20).withValues(alpha: 0.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        child: _saving
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                            : Text(c('business_details.btn_submit')),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(c('business_details.review_note'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
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
    _SectionHeader(icon: Icons.storefront_outlined, title: c('business_details.sec_business')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.ph_customer_name_label'), required: true, controller: _customerNameCtrl, hint: c('business_details.ph_customer_name_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_name_required') : null),
    const SizedBox(height: 14),
    _Field(label: c('business_details.ph_pharmacy_name_label'), required: true, controller: _pharmacyCtrl, hint: c('business_details.ph_pharmacy_name_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_business_name_required') : null),
    const SizedBox(height: 14),
    _Dropdown(label: c('business_details.dd_store_type'), required: true, value: _storeType, items: _storeTypes, onChanged: (v) => setState(() => _storeType = v), validator: (v) => v == null ? c('business_details.err_select_store_type') : null),
    const SizedBox(height: 14),
    _Dropdown(label: c('business_details.dd_range_zone'), required: true, value: _rangeZone, items: _rangeZones, onChanged: (v) => setState(() => _rangeZone = v), validator: (v) => v == null ? c('business_details.err_select_range') : null),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.location_on_outlined, title: c('business_details.sec_address')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.ph_address_label'), required: true, controller: _addressCtrl, hint: c('business_details.ph_address_hint'), maxLines: 2, validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_address_required') : null),
    const SizedBox(height: 14),
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _Field(label: c('business_details.ph_city_label'), required: true, controller: _cityCtrl, hint: c('business_details.ph_city_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null)),
      const SizedBox(width: 12),
      Expanded(child: _Field(label: c('business_details.ph_state_label'), required: true, controller: _stateCtrl, hint: c('business_details.ph_state_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null)),
    ]),
    const SizedBox(height: 14),
    Row(children: [SizedBox(width: 160, child: _Field(label: c('business_details.ph_pincode_label'), required: true, controller: _pincodeCtrl, hint: c('business_details.ph_pincode_hint'), keyboardType: TextInputType.number, maxLength: 6, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)], validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (v.trim().length != 6) return c('business_details.err_6_digits'); return null; }))]),
    const SizedBox(height: 14),
    _Field(label: c('business_details.ph_store_link_label'), controller: _storeLocationCtrl, hint: c('business_details.ph_store_link_hint'), keyboardType: TextInputType.url, capitalization: TextCapitalization.none),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.phone_outlined, title: c('business_details.sec_contact')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.ph_whatsapp_label'), required: true, controller: _whatsappCtrl, hint: c('business_details.ph_whatsapp_hint'), keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (v.trim().length != 10) return c('business_details.err_10_digit_number'); return null; }),
    const SizedBox(height: 14),
    _Field(label: c('business_details.ph_other_contact_label'), controller: _otherContactCtrl, hint: c('business_details.ph_other_contact_hint'), keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return null; if (v.trim().length != 10) return c('business_details.err_10_digit_number'); return null; }),
    const SizedBox(height: 14),
    _Field(label: c('business_details.ph_email_label'), required: widget.email.isEmpty, controller: _emailCtrl, hint: c('business_details.ph_email_hint'), keyboardType: TextInputType.emailAddress, capitalization: TextCapitalization.none, readOnly: widget.email.isNotEmpty, validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (!v.trim().contains('@')) return c('business_details.err_invalid_email'); return null; }),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.verified_outlined, title: c('business_details.sec_drug_licenses')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.ph_dl20b_label'), required: true, controller: _dl20bCtrl, hint: c('business_details.ph_dl20b_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_dl20b_required') : null),
    const SizedBox(height: 14),
    _Field(label: c('business_details.ph_dl21b_label'), controller: _dl21bCtrl, hint: c('business_details.ph_dl21b_hint')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.ph_gst_label'), controller: _gstCtrl, hint: c('business_details.ph_gst_hint'), maxLength: 15, capitalization: TextCapitalization.characters, validator: (v) { if (v == null || v.trim().isEmpty) return null; final gst = v.trim().toUpperCase(); if (!RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$').hasMatch(gst)) return c('business_details.err_invalid_gstin'); return null; }),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.manage_accounts_outlined, title: c('business_details.sec_account_setup')),
    const SizedBox(height: 14),
    _Dropdown(label: c('business_details.dd_payment_term'), required: true, value: _paymentTerm, items: _paymentTerms, onChanged: (v) => setState(() => _paymentTerm = v), validator: (v) => v == null ? c('business_details.err_select_payment_term') : null),
    const SizedBox(height: 14),
    CodeField(
      controller: _customerCodeCtrl,
      label: c('business_details.ph_customer_code_label'),
      hint: c('business_details.ph_customer_code_hint'),
      isTaken: (code) async =>
          await Supabase.instance.client.rpc('is_customer_code_taken', params: {'p_code': code}) as bool,
      onStatusChanged: (s) => setState(() => _customerCodeStatus = s),
    ),
  ];

  // ── Supplier form ──────────────────────────────────────────────────────
  List<Widget> _buildSupplierForm() => [
    _SectionHeader(icon: Icons.business_outlined, title: c('business_details.sec_company')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.sup_company_label'), required: true, controller: _supCompanyCtrl, hint: c('business_details.sup_company_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 14),
    _Field(label: c('business_details.sup_contact_label'), required: true, controller: _supContactCtrl, hint: c('business_details.sup_contact_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 14),
    _Field(label: c('business_details.sup_phone_label'), required: true, controller: _supPhoneCtrl, hint: c('business_details.sup_phone_hint'), keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (v.trim().length != 10) return c('business_details.err_10_digit'); return null; }),
    const SizedBox(height: 14),
    _Field(label: c('business_details.sup_email_label'), required: widget.email.isEmpty, controller: _supEmailCtrl, hint: c('business_details.sup_email_hint'), keyboardType: TextInputType.emailAddress, capitalization: TextCapitalization.none, readOnly: widget.email.isNotEmpty, validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (!v.trim().contains('@')) return c('business_details.err_invalid_email'); return null; }),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.location_on_outlined, title: c('business_details.sec_address')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.sup_address_label'), required: true, controller: _supAddressCtrl, hint: c('business_details.sup_address_hint'), maxLines: 2, validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 14),
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _Field(label: c('business_details.sup_city_label'), required: true, controller: _supCityCtrl, hint: c('business_details.sup_city_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null)),
      const SizedBox(width: 12),
      Expanded(child: _Field(label: c('business_details.sup_state_label'), required: true, controller: _supStateCtrl, hint: c('business_details.sup_state_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null)),
    ]),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.verified_outlined, title: c('business_details.sec_compliance_optional')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.sup_gst_label'), controller: _supGstCtrl, hint: c('business_details.sup_gst_hint'), maxLength: 15, capitalization: TextCapitalization.characters),
    const SizedBox(height: 14),
    _Field(label: c('business_details.sup_dl_label'), controller: _supDlCtrl, hint: c('business_details.sup_dl_hint')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.sup_categories_label'), controller: _supCategoriesCtrl, hint: c('business_details.sup_categories_hint'), maxLines: 2),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.manage_accounts_outlined, title: c('business_details.sec_account_setup')),
    const SizedBox(height: 14),
    CodeField(
      controller: _supplierCodeCtrl,
      label: c('business_details.sup_supplier_code_label'),
      hint: c('business_details.sup_supplier_code_hint'),
      isTaken: (code) async =>
          await Supabase.instance.client.rpc('is_supplier_code_taken', params: {'p_code': code}) as bool,
      onStatusChanged: (s) => setState(() => _supplierCodeStatus = s),
    ),
  ];

  // ── MR form ────────────────────────────────────────────────────────────
  List<Widget> _buildMrForm() => [
    _SectionHeader(icon: Icons.person_outlined, title: c('business_details.sec_personal')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.mr_name_label'), required: true, controller: _mrNameCtrl, hint: c('business_details.mr_name_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 14),
    _Field(label: c('business_details.mr_phone_label'), required: true, controller: _mrPhoneCtrl, hint: c('business_details.mr_phone_hint'), keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (v.trim().length != 10) return c('business_details.err_10_digit'); return null; }),
    const SizedBox(height: 14),
    _Field(label: c('business_details.mr_email_label'), required: widget.email.isEmpty, controller: _mrEmailCtrl, hint: c('business_details.mr_email_hint'), keyboardType: TextInputType.emailAddress, capitalization: TextCapitalization.none, readOnly: widget.email.isNotEmpty, validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (!v.trim().contains('@')) return c('business_details.err_invalid_email'); return null; }),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.work_outlined, title: c('business_details.sec_professional')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.mr_company_label'), required: true, controller: _mrCompanyCtrl, hint: c('business_details.mr_company_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 14),
    _Field(label: c('business_details.mr_territory_label'), required: true, controller: _mrTerritoryCtrl, hint: c('business_details.mr_territory_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.location_on_outlined, title: c('business_details.sec_location')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.mr_address_label'), controller: _mrAddressCtrl, hint: c('business_details.mr_address_hint'), maxLines: 2),
    const SizedBox(height: 14),
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _Field(label: c('business_details.mr_city_label'), required: true, controller: _mrCityCtrl, hint: c('business_details.mr_city_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null)),
      const SizedBox(width: 12),
      Expanded(child: _Field(label: c('business_details.mr_state_label'), required: true, controller: _mrStateCtrl, hint: c('business_details.mr_state_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null)),
    ]),
    const SizedBox(height: 14),
    _Dropdown(label: c('business_details.dd_id_proof_type'), value: _mrIdProofType, items: _idProofTypes, onChanged: (v) => setState(() => _mrIdProofType = v)),
  ];

  // ── Company form ───────────────────────────────────────────────────────
  List<Widget> _buildCompanyForm() => [
    _SectionHeader(icon: Icons.business_outlined, title: c('business_details.sec_company')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.co_name_label'), required: true, controller: _coNameCtrl, hint: c('business_details.co_name_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 14),
    _Field(label: c('business_details.co_contact_label'), required: true, controller: _coContactCtrl, hint: c('business_details.co_contact_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 14),
    _Field(label: c('business_details.co_phone_label'), required: true, controller: _coPhoneCtrl, hint: c('business_details.co_phone_hint'), keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (v.trim().length != 10) return c('business_details.err_10_digit'); return null; }),
    const SizedBox(height: 14),
    _Field(label: c('business_details.co_email_label'), required: widget.email.isEmpty, controller: _coEmailCtrl, hint: c('business_details.co_email_hint'), keyboardType: TextInputType.emailAddress, capitalization: TextCapitalization.none, readOnly: widget.email.isNotEmpty, validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (!v.trim().contains('@')) return c('business_details.err_invalid_email'); return null; }),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.verified_outlined, title: c('business_details.sec_compliance')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.co_gst_label'), controller: _coGstCtrl, hint: c('business_details.co_gst_hint'), maxLength: 15, capitalization: TextCapitalization.characters),
    const SizedBox(height: 14),
    _Field(label: c('business_details.co_dl_label'), controller: _coDlCtrl, hint: c('business_details.co_dl_hint')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.co_categories_label'), controller: _coCategoriesCtrl, hint: c('business_details.co_categories_hint'), maxLines: 2),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.location_on_outlined, title: c('business_details.sec_registered_address')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.co_address_label'), required: true, controller: _coAddressCtrl, hint: c('business_details.co_address_hint'), maxLines: 2, validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 14),
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _Field(label: c('business_details.co_city_label'), required: true, controller: _coCityCtrl, hint: c('business_details.co_city_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null)),
      const SizedBox(width: 12),
      Expanded(child: _Field(label: c('business_details.co_state_label'), required: true, controller: _coStateCtrl, hint: c('business_details.co_state_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null)),
    ]),
    const SizedBox(height: 14),
    _Field(label: c('business_details.co_website_label'), controller: _coWebsiteCtrl, hint: c('business_details.co_website_hint'), keyboardType: TextInputType.url, capitalization: TextCapitalization.none),
  ];

  // ── Delivery Partner form ──────────────────────────────────────────────
  List<Widget> _buildDeliveryForm() => [
    _SectionHeader(icon: Icons.person_outlined, title: c('business_details.sec_personal')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.dp_name_label'), required: true, controller: _dpNameCtrl, hint: c('business_details.dp_name_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 14),
    _Field(label: c('business_details.dp_phone_label'), required: true, controller: _dpPhoneCtrl, hint: c('business_details.dp_phone_hint'), keyboardType: TextInputType.phone, maxLength: 10, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)], validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (v.trim().length != 10) return c('business_details.err_10_digit'); return null; }),
    const SizedBox(height: 14),
    _Field(label: c('business_details.dp_email_label'), required: widget.email.isEmpty, controller: _dpEmailCtrl, hint: c('business_details.dp_email_hint'), keyboardType: TextInputType.emailAddress, capitalization: TextCapitalization.none, readOnly: widget.email.isNotEmpty, validator: (v) { if (v == null || v.trim().isEmpty) return c('business_details.err_required'); if (!v.trim().contains('@')) return c('business_details.err_invalid_email'); return null; }),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.delivery_dining_outlined, title: c('business_details.sec_delivery')),
    const SizedBox(height: 14),
    _Dropdown(label: c('business_details.dd_vehicle_type'), required: true, value: _dpVehicleType, items: _vehicleTypes, onChanged: (v) => setState(() => _dpVehicleType = v), validator: (v) => v == null ? c('business_details.err_select_vehicle_type') : null),
    const SizedBox(height: 14),
    _Field(label: c('business_details.dp_zone_label'), required: true, controller: _dpZoneCtrl, hint: c('business_details.dp_zone_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null),
    const SizedBox(height: 28),
    _SectionHeader(icon: Icons.location_on_outlined, title: c('business_details.sec_location')),
    const SizedBox(height: 14),
    _Field(label: c('business_details.dp_address_label'), controller: _dpAddressCtrl, hint: c('business_details.dp_address_hint'), maxLines: 2),
    const SizedBox(height: 14),
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _Field(label: c('business_details.dp_city_label'), required: true, controller: _dpCityCtrl, hint: c('business_details.dp_city_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null)),
      const SizedBox(width: 12),
      Expanded(child: _Field(label: c('business_details.dp_state_label'), required: true, controller: _dpStateCtrl, hint: c('business_details.dp_state_hint'), validator: (v) => (v == null || v.trim().isEmpty) ? c('business_details.err_required') : null)),
    ]),
    const SizedBox(height: 14),
    _Dropdown(label: c('business_details.dd_id_proof_type'), value: _dpIdProofType, items: _idProofTypes, onChanged: (v) => setState(() => _dpIdProofType = v)),
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
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: readOnly ? const BorderSide(color: Color(0xFFD1D5DB)) : const BorderSide(color: Color(0xFFE5E7EB), width: 1.5)),
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
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB), width: 1.5)),
          errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFDC2626))),
          focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFDC2626), width: 1.5)),
          filled: true,
          fillColor: const Color(0xFFFAFAFA),
        ),
        hint: Text(c('business_details.dropdown_hint'), style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14)),
        items: items.map((item) => DropdownMenuItem(value: item, child: Text(item, style: const TextStyle(fontSize: 14)))).toList(),
        onChanged: onChanged,
        validator: validator,
      ),
    ]);
  }
}
