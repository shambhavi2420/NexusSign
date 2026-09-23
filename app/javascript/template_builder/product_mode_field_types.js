// Field types hidden from the builder tray in Standard (productized) mode.
// Mirrors the server-side list in lib/templates/product_mode_field_types.rb
// (candidate healthcare fields + signer name fields). See
// .kiro/specs/standard-productized-mode (Requirements 6 and 7).
export const STANDARD_MODE_HIDDEN_FIELD_TYPES = [
  // Candidate healthcare-specific types
  'candidatepermanentaddress1',
  'candidatepermanentcity',
  'candidatepermanentstate',
  'candidatepermanentzip',
  'candidatessn',
  'candidateprimaryprofession',
  'candidateprimaryspecialty',
  'candidateavailablefrom',
  'candidateavailablefromdate',
  'candidateprofession',
  'candidatespecialty',
  'candidateaddress',
  'candidatecity',
  'candidatestate',
  'candidatezip',
  // Signer fields (become plain text / hidden in standard mode)
  'signerfullname',
  'signerfirstname',
  'signerlastname',
  'signeremail',
  'signerprimaryphone'
]

// Removes the hidden types from a { type: icon } map when standard mode is on.
export function filterStandardModeFieldTypes (entries, standardMode) {
  if (!standardMode) return entries

  return Object.fromEntries(
    Object.entries(entries).filter(([type]) => !STANDARD_MODE_HIDDEN_FIELD_TYPES.includes(type))
  )
}
