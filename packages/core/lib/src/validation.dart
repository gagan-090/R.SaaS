final _gstin = RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');

/// Shape check for a 15-character GSTIN (same rule as the API).
bool isValidGstin(String v) => _gstin.hasMatch(v);

/// A reason is mandatory for reversals, status changes and adjustments: at least 3 non-blank characters.
bool isValidReason(String? v) => v != null && v.trim().length >= 3;
