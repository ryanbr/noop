# Weight history

Record dated weights and view the last 30 days, 90 days or all history.
Open **More → Body → Weight history** on Android/iOS, or **Body → Weight history**
in the Mac sidebar.

On Android, tapping the Today Weight tile opens the log. With **Detailed tiles**
enabled, it also shows a mini graph when the selected window contains at least
two readings.

## Entries

- Add, edit or delete manual readings. Saving on an existing date replaces that
  date’s manual entry.
- Imported readings are read-only. For the same date, manual entries take priority,
  followed by Apple Health and Health Connect. Deleting a manual entry reveals the
  imported reading.
- Entry and display follow the metric/imperial setting. Decimal points and commas
  are accepted.

## Storage and limitations

Weights are stored in kilograms in `metricSeries`, using `noop-weight` as the
source and `weight` as the key. Older imports stored only in `appleDaily` are
included in the history.

Logged weights do not update profile weight or change analytics inputs.
Native `.noopbak` backups preserve the entries; WHOOP-format CSV exports do not.
Nutrition CSV weights are excluded because some older imports have ambiguous units.

Refs #763.
