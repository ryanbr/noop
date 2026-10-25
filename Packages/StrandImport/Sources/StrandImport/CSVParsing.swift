import Foundation

// MARK: - UTF-8 BOM handling

enum BOM {
    /// Strip a leading UTF-8 byte-order-mark (EF BB BF) from raw bytes.
    static func stripUTF8(_ data: Data) -> Data {
        guard data.count >= 3,
              data[data.startIndex] == 0xEF,
              data[data.startIndex + 1] == 0xBB,
              data[data.startIndex + 2] == 0xBF
        else { return data }
        return data.subdata(in: (data.startIndex + 3)..<data.endIndex)
    }

    /// Strip a leading BOM from a decoded string (covers the case where the
    /// bytes were already decoded and the BOM survived as U+FEFF).
    static func stripString(_ s: String) -> String {
        if s.hasPrefix("\u{FEFF}") { return String(s.dropFirst()) }
        return s
    }
}

// MARK: - Header normalization

enum HeaderNorm {
    /// Normalize a CSV header to a stable lookup key.
    ///
    /// lowercase, `%`→`pct`, drop parens (keep inner content), collapse runs of
    /// non-alphanumerics to `_`, trim `_`. Mirrors the reference Python parser so
    /// the same field aliases apply.
    ///   "Heart rate variability (ms)" -> "heart_rate_variability_ms"
    ///   "Recovery score %"            -> "recovery_score_pct"
    static func normalize(_ header: String) -> String {
        // Fold diacritics first so localized headers normalize deterministically regardless of
        // NFC/NFD form (ä→a, ö→o, ü→u). English headers are unaffected. (issue #3)
        var s = header.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "%", with: "pct")
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasUnderscore = false
        for ch in s {
            if ch.isLetter || ch.isNumber, ch.isASCII {
                out.append(ch)
                lastWasUnderscore = false
            } else {
                // Any non-alphanumeric (including parens, spaces, slashes, etc.)
                // becomes a single underscore.
                if !lastWasUnderscore {
                    out.append("_")
                    lastWasUnderscore = true
                }
            }
        }
        // Trim leading/trailing underscores.
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        // Map localized column headers onto their canonical English keys so the parsers
        // (which look up English keys) find the values. (issue #3)
        return foreignAliases[out] ?? out
    }

    /// Localized WHOOP export column headers → canonical English normalized keys. Keys are the
    /// diacritic-folded normalized form of the foreign header. German added from a real export
    /// (issue #3, headers supplied by the reporter); more languages can be appended here.
    static let foreignAliases: [String: String] = [
        // — German (physiologische_zyklen / Schlaf / Trainings / logbuch_eintraege) —
        "startzeit_des_zyklus": "cycle_start_time",
        "endzeit_des_zyklus": "cycle_end_time",
        "zeitzone_des_zyklus": "cycle_timezone",
        "erholungswert_pct": "recovery_score_pct",
        "ruheherzfrequenz_schlage_pro_minute": "resting_heart_rate_bpm",
        "herzfrequenzvariabilitat_ms": "heart_rate_variability_ms",
        "hauttemperatur_celsius": "skin_temp_celsius",
        "blutsauerstoff_pct": "blood_oxygen_pct",
        "tagesbelastung": "day_strain",
        "verbrannte_energie_cal": "energy_burned_cal",
        "max_hf_schlage_pro_minute": "max_hr_bpm",
        "durchschnittliche_hf_schlage_pro_minute": "average_hr_bpm",
        "beginn_des_schlafs": "sleep_onset",
        "beginn_des_aufwachens": "wake_onset",
        "schlafleistung_pct": "sleep_performance_pct",
        "atemfrequenz_atemzuge_min": "respiratory_rate_rpm",
        "schlafdauer_min": "asleep_duration_min",
        "dauer_im_bett_min": "in_bed_duration_min",
        "dauer_des_leichtschlafs_min": "light_sleep_duration_min",
        "dauer_des_tiefschlafs_min": "deep_sws_duration_min",
        "dauer_des_rem_schlafs_min": "rem_duration_min",
        "dauer_des_aufwachens_min": "awake_duration_min",
        "schlafbedarf_min": "sleep_need_min",
        "schlafdefizit_min": "sleep_debt_min",
        "schlafeffizienz_pct": "sleep_efficiency_pct",
        "schlafbestandigkeit_pct": "sleep_consistency_pct",
        "nickerchen": "nap",
        "startzeit_des_trainings": "workout_start_time",
        "endzeit_des_trainings": "workout_end_time",
        "name_der_aktivitat": "activity_name",
        "aktivitatsbelastung": "activity_strain",
        "hf_zone_1_pct": "hr_zone_1_pct",
        "hf_zone_2_pct": "hr_zone_2_pct",
        "hf_zone_3_pct": "hr_zone_3_pct",
        "hf_zone_4_pct": "hr_zone_4_pct",
        "hf_zone_5_pct": "hr_zone_5_pct",
        "fragetext": "question_text",
        "beantwortet_mit_ja": "answered_yes_no",
        "anmerkungen": "notes",
        // — Spanish (physiological_cycles keeps its English filename but Spanish columns / sueño.csv /
        //   entrenamientos.csv). Headers supplied by a real export (issue #76). —
        "hora_de_inicio_del_ciclo": "cycle_start_time",
        "hora_de_finalizacion_del_ciclo": "cycle_end_time",
        "zona_horaria_del_ciclo": "cycle_timezone",
        "puntuacion_de_recuperacion_pct": "recovery_score_pct",
        "frecuencia_cardiaca_en_reposo_lpm": "resting_heart_rate_bpm",
        "variabilidad_de_la_frecuencia_cardiaca_ms": "heart_rate_variability_ms",
        "temp_cutanea_grados_centigrados": "skin_temp_celsius",
        "oxigeno_en_sangre_pct": "blood_oxygen_pct",
        "esfuerzo_del_dia": "day_strain",
        "energia_quemada_cal": "energy_burned_cal",
        "fc_max_lpm": "max_hr_bpm",
        "fc_promedio_lpm": "average_hr_bpm",
        "inicio_del_sueno": "sleep_onset",
        "inicio_de_la_vigilia": "wake_onset",
        "calificacion_del_sueno_pct": "sleep_performance_pct",
        "frecuencia_respiratoria_rpm": "respiratory_rate_rpm",
        "duracion_del_sueno_min": "asleep_duration_min",
        "tiempo_en_la_cama_min": "in_bed_duration_min",
        "duracion_de_sueno_ligero_min": "light_sleep_duration_min",
        "duracion_de_sueno_profundo_sws_min": "deep_sws_duration_min",
        "duracion_de_sueno_rem_min": "rem_duration_min",
        "tempo_despierto_a_min": "awake_duration_min",       // WHOOP's es export reads "Tempo despierto/a"
        "sueno_necesario_min": "sleep_need_min",
        "deuda_de_sueno_min": "sleep_debt_min",
        "eficiencia_del_sueno_pct": "sleep_efficiency_pct",
        "regularidad_del_sueno_pct": "sleep_consistency_pct",
        "siesta": "nap",
        // Workout columns inferred from WHOOP's consistent es naming (a real entrenamientos.csv header
        // would confirm); harmless if a name differs — an unmatched alias simply never fires.
        "hora_de_inicio_del_entrenamiento": "workout_start_time",
        "hora_de_finalizacion_del_entrenamiento": "workout_end_time",
        "nombre_de_la_actividad": "activity_name",
        "esfuerzo_de_la_actividad": "activity_strain",
        // — French (physiological_cycles keeps its English filename; sommeil.csv / entrainements.csv).
        //   Full header set incl. workouts, from a real export (issue #79). Apostrophes (' or ’) and the
        //   non-breaking space before % both fold to "_" in normalize, so these keys are exact. —
        "heure_de_debut_du_cycle": "cycle_start_time",
        "heure_de_fin_du_cycle": "cycle_end_time",
        "fuseau_horaire_du_cycle": "cycle_timezone",
        "score_de_recuperation_pct": "recovery_score_pct",
        "frequence_cardiaque_au_repos_bpm": "resting_heart_rate_bpm",
        "variabilite_de_la_frequence_cardiaque_ms": "heart_rate_variability_ms",
        "temperature_cutanee_celsius": "skin_temp_celsius",
        "niveau_d_oxygene_pct": "blood_oxygen_pct",
        "effort_du_jour": "day_strain",
        "depense_energetique_cal": "energy_burned_cal",
        "fc_max_bpm": "max_hr_bpm",
        "fc_moyenne_bpm": "average_hr_bpm",
        "premiers_signes_de_sommeil": "sleep_onset",
        "premiers_signes_de_reveil": "wake_onset",
        "performance_sommeil_pct": "sleep_performance_pct",
        "frequence_respiratoire_tr_min": "respiratory_rate_rpm",
        "duree_du_sommeil_min": "asleep_duration_min",
        "temps_passe_au_lit_min": "in_bed_duration_min",
        "duree_du_sommeil_leger_min": "light_sleep_duration_min",
        "duree_du_sommeil_profond_min": "deep_sws_duration_min",
        "duree_du_sommeil_paradoxal_min": "rem_duration_min",      // paradoxal = REM
        "temps_d_eveil_min": "awake_duration_min",
        "besoins_en_sommeil_min": "sleep_need_min",
        "dette_de_sommeil_min": "sleep_debt_min",
        "efficacite_du_sommeil_pct": "sleep_efficiency_pct",
        "regularite_du_sommeil_pct": "sleep_consistency_pct",
        "sieste": "nap",
        "heure_de_debut_de_l_entrainement": "workout_start_time",
        "heure_de_fin_de_l_entrainement": "workout_end_time",
        "nom_de_l_activite": "activity_name",
        "effort_activite": "activity_strain",
        "zone_fc_1_pct": "hr_zone_1_pct",
        "zone_fc_2_pct": "hr_zone_2_pct",
        "zone_fc_3_pct": "hr_zone_3_pct",
        "zone_fc_4_pct": "hr_zone_4_pct",
        "zone_fc_5_pct": "hr_zone_5_pct",
        // — Brazilian Portuguese (ciclos_fisiológicos / sonos / treinos / entradas_diário), issue #692.
        //   Full header set across cycles, sleeps, workouts and journal, from a real pt-BR export. Note
        //   "FC máx." folds to the same key as the French "FC max." alias above, and a Swift dictionary
        //   literal traps on a duplicate key, so it is deliberately NOT repeated here. —
        "hora_de_inicio_do_ciclo": "cycle_start_time",
        "hora_de_fim_do_ciclo": "cycle_end_time",
        "fuso_horario_do_ciclo": "cycle_timezone",
        "pontuacao_de_recuperacao_pct": "recovery_score_pct",
        "frequencia_cardiaca_em_repouso_bpm": "resting_heart_rate_bpm",
        "variabilidade_da_frequencia_cardiaca_ms": "heart_rate_variability_ms",
        "temp_da_pele_celsius": "skin_temp_celsius",
        "pct_de_oxigenio_no_sangue": "blood_oxygen_pct",   // "% de oxigênio no sangue" → leading % becomes pct_…
        "esforco_diario": "day_strain",
        "energia_queimada_cal": "energy_burned_cal",
        "fc_media_bpm": "average_hr_bpm",
        "inicio_do_sono": "sleep_onset",
        "inicio_da_vigilia": "wake_onset",
        "desempenho_do_sono_pct": "sleep_performance_pct",
        "frequencia_respiratoria_rpm": "respiratory_rate_rpm",
        "duracao_do_sono_min": "asleep_duration_min",
        "duracao_na_cama_min": "in_bed_duration_min",
        "duracao_do_sono_leve_min": "light_sleep_duration_min",
        "duracao_profundo_sono_min": "deep_sws_duration_min",   // "Duração profundo (Sono) (min)"
        "duracao_rem_min": "rem_duration_min",
        "duracao_de_vigilia_min": "awake_duration_min",
        "necessidade_de_sono_min": "sleep_need_min",
        "debito_de_sono_min": "sleep_debt_min",
        "eficacia_do_sono_pct": "sleep_efficiency_pct",
        "consistencia_do_sono_pct": "sleep_consistency_pct",
        "sesta": "nap",
        "hora_de_inicio_do_treino": "workout_start_time",
        "hora_de_fim_do_treino": "workout_end_time",
        "nome_da_atividade": "activity_name",
        "esforco_da_atividade": "activity_strain",
        "zona_1_de_fc_pct": "hr_zone_1_pct",
        "zona_2_de_fc_pct": "hr_zone_2_pct",
        "zona_3_de_fc_pct": "hr_zone_3_pct",
        "zona_4_de_fc_pct": "hr_zone_4_pct",
        "zona_5_de_fc_pct": "hr_zone_5_pct",
        "texto_de_pergunta": "question_text",
        "respondeu_sim": "answered_yes_no",
        "notas": "notes",
        // — Italian (cicli_fisiologici / sonno / allenamenti / voci_diario). Every header the importers read
        //   across cycles, sleeps, workouts and journal, from a real Italian export ("Durata (min)" and
        //   "GPS abilitato" are not read in any language). "FC max." and "FC media" fold to the same
        //   keys as the French and pt-BR aliases above, so they are deliberately NOT repeated here. The
        //   journal "Note" column is NOT aliased either: a global "note" key would rename the lift-program
        //   template's own "Note" column, so the journal parser reads "note" as a fallback instead. —
        "ora_di_inizio_ciclo": "cycle_start_time",
        "ora_di_fine_ciclo": "cycle_end_time",
        "fuso_orario_ciclo": "cycle_timezone",
        "punteggio_di_recupero_pct": "recovery_score_pct",
        "frequenza_cardiaca_a_riposo_bpm": "resting_heart_rate_bpm",
        "variabilita_della_frequenza_cardiaca_ms": "heart_rate_variability_ms",
        "temp_cutanea_c": "skin_temp_celsius",
        "ossigeno_nel_sangue_pct": "blood_oxygen_pct",
        "sforzo_giornaliero": "day_strain",
        "energia_bruciata_cal": "energy_burned_cal",
        "inizio_del_sonno": "sleep_onset",
        "inizio_del_risveglio": "wake_onset",
        "andamento_del_sonno_pct": "sleep_performance_pct",
        "frequenza_respiratoria_rpm": "respiratory_rate_rpm",
        "durata_del_sonno_min": "asleep_duration_min",
        "tempo_a_letto_min": "in_bed_duration_min",
        "durata_del_sonno_leggero_min": "light_sleep_duration_min",
        "durata_profondo_sws_min": "deep_sws_duration_min",
        "durata_rem_min": "rem_duration_min",
        "durata_del_risveglio_min": "awake_duration_min",
        "sonno_richiesto_min": "sleep_need_min",
        "sonno_arretrato_min": "sleep_debt_min",
        "efficienza_del_sonno_pct": "sleep_efficiency_pct",
        "regolarita_del_sonno_pct": "sleep_consistency_pct",
        "riposo_breve": "nap",
        "ora_di_inizio_allenamento": "workout_start_time",
        "ora_di_fine_allenamento": "workout_end_time",
        "nome_attivita": "activity_name",
        "sforzo_richiesto_dall_attivita": "activity_strain",
        "zona_fc_1_pct": "hr_zone_1_pct",
        "zona_fc_2_pct": "hr_zone_2_pct",
        "zona_fc_3_pct": "hr_zone_3_pct",
        "zona_fc_4_pct": "hr_zone_4_pct",
        "zona_fc_5_pct": "hr_zone_5_pct",
        "testo_domanda": "question_text",
        "risposta_affermativa": "answered_yes_no",
    ]
}

// MARK: - Tolerant CSV reader

/// A tolerant, header-name-driven CSV parser.
///
/// - Handles UTF-8 BOM, quoted fields with embedded commas/quotes/newlines
///   (RFC-4180 style with `""` escaping), and CRLF or LF line endings.
/// - Exposes rows as `[normalizedHeader: rawCellString]` so callers match
///   columns by name; missing columns simply return `nil`.
struct CSVTable {
    /// Original header strings, in file order.
    let headers: [String]
    /// Normalized header keys, parallel to `headers`.
    let normalizedHeaders: [String]
    /// Rows; each is a normalized-key → cell-value dictionary.
    let rows: [[String: String]]

    /// Parse CSV text (BOM already advisable to strip, but handled here too).
    init(text rawText: String) {
        let text = BOM.stripString(rawText)
        // Detect the field delimiter from the header line. WHOOP exports are comma-separated, but other
        // sources are not: a real Oura account-export CSV uses `;` (and some locales' spreadsheet exports
        // use `;` or a tab). Sniffing per file lets one parser read all of them; default stays `,` so the
        // WHOOP path is byte-for-byte unchanged. (issue #862)
        let delimiter = CSVTable.detectDelimiter(text)
        var records = CSVTable.parseRecords(text, delimiter: delimiter)
        guard !records.isEmpty else {
            self.headers = []
            self.normalizedHeaders = []
            self.rows = []
            return
        }
        let headerRow = records.removeFirst()
        self.headers = headerRow
        let normHeaders = headerRow.map { HeaderNorm.normalize($0) }
        self.normalizedHeaders = normHeaders

        var parsedRows: [[String: String]] = []
        parsedRows.reserveCapacity(records.count)
        for fields in records {
            // Skip completely blank lines.
            if fields.count == 1, fields[0].trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            var dict: [String: String] = [:]
            for (i, key) in normHeaders.enumerated() where !key.isEmpty {
                let value = i < fields.count ? fields[i] : ""
                // First non-empty header wins if duplicated (rare).
                if dict[key] == nil || dict[key]!.isEmpty {
                    dict[key] = value
                }
            }
            parsedRows.append(dict)
        }
        self.rows = parsedRows
    }

    /// Parse from raw `Data` (strips UTF-8 BOM, decodes UTF-8 with a latin-1
    /// fallback for the rare malformed export).
    init(data: Data) {
        let clean = BOM.stripUTF8(data)
        let text = String(data: clean, encoding: .utf8)
            ?? String(data: clean, encoding: .isoLatin1)
            ?? ""
        self.init(text: text)
    }

    // MARK: Delimiter detection

    /// Sniff the field delimiter from the FIRST (header) line of a CSV: whichever of `,`, `;` or tab
    /// appears most outside quotes. Defaults to `,` (so WHOOP / Fitbit exports are unaffected) when the
    /// header has none of them. Only the header line is scanned, so it's O(header length). (issue #862)
    static func detectDelimiter(_ text: String) -> Character {
        var commas = 0, semis = 0, tabs = 0
        var inQuotes = false
        for ch in text.unicodeScalars {
            if ch == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if ch == "\n" || ch == "\r" { break }   // header line only
            switch ch {
            case ",":  commas += 1
            case ";":  semis += 1
            case "\t": tabs += 1
            default:   break
            }
        }
        if semis > commas && semis >= tabs { return ";" }
        if tabs > commas && tabs > semis { return "\t" }
        return ","
    }

    // MARK: RFC-4180-ish record splitter

    /// Split CSV text into records of fields, honouring quotes and escaped
    /// quotes, and treating CRLF / CR / LF uniformly as row terminators.
    /// `delimiter` is the field separator (auto-detected per file; `,` by default).
    static func parseRecords(_ text: String, delimiter: Character = ",") -> [[String]] {
        let sep = delimiter.unicodeScalars.first ?? ","
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var sawAnyField = false

        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func nextScalar() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let scalar = nextScalar() {
            if inQuotes {
                if scalar == "\"" {
                    // Look ahead for an escaped quote ("").
                    if let look = iterator.next() {
                        if look == "\"" {
                            field.unicodeScalars.append("\"")
                        } else {
                            inQuotes = false
                            pending = look
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else {
                switch scalar {
                case "\"":
                    inQuotes = true
                    sawAnyField = true
                case sep:
                    record.append(field)
                    field = ""
                    sawAnyField = true
                case "\r":
                    // Consume an optional following \n (CRLF).
                    if let look = iterator.next(), look != "\n" {
                        pending = look
                    }
                    record.append(field)
                    records.append(record)
                    field = ""
                    record = []
                    sawAnyField = false
                case "\n":
                    record.append(field)
                    records.append(record)
                    field = ""
                    record = []
                    sawAnyField = false
                default:
                    field.unicodeScalars.append(scalar)
                    sawAnyField = true
                }
            }
        }
        // Flush the final field/record if the file didn't end with a newline.
        if sawAnyField || !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}

// MARK: - Cell accessors

extension Dictionary where Key == String, Value == String {
    /// First non-empty cell among the given normalized keys, trimmed; `nil` if
    /// absent or blank.
    func cell(_ keys: String...) -> String? {
        for k in keys {
            if let v = self[k] {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    /// Parse a cell as a `Double`, tolerating thousands separators and stray
    /// units accidentally left in the cell.
    func double(_ keys: String...) -> Double? {
        for k in keys {
            if let v = self[k] {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                if let d = Double(t) { return d }
                // Tolerate values like "1,234" or "62 ms".
                let cleaned = t
                    .replacingOccurrences(of: ",", with: "")
                    .components(separatedBy: CharacterSet(charactersIn: "0123456789.+-eE").inverted)
                    .joined()
                if let d = Double(cleaned) { return d }
            }
        }
        return nil
    }

    /// Parse a cell as a boolean (`true`/`yes`/`1`).
    func bool(_ keys: String...) -> Bool? {
        for k in keys {
            if let v = self[k] {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if t.isEmpty { continue }
                if ["true", "yes", "1", "y"].contains(t) { return true }
                if ["false", "no", "0", "n"].contains(t) { return false }
            }
        }
        return nil
    }
}

// MARK: - Whoop timestamp parsing

enum WhoopTime {
    /// Parse a `Cycle timezone` string like `UTC+01:00`, `UTC-05:00`, `+01:00`,
    /// or `Z` into an offset in **minutes**.
    static func tzOffsetMinutes(_ raw: String?) -> Int {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return 0 }
        let upper = s.uppercased()
        if upper == "UTC" || upper == "Z" || upper == "GMT" { return 0 }
        if upper.hasPrefix("UTC") { s = String(s.dropFirst(3)) }
        else if upper.hasPrefix("GMT") { s = String(s.dropFirst(3)) }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "Z" { return 0 }

        var sign = 1
        if s.hasPrefix("+") { s.removeFirst() }
        else if s.hasPrefix("-") { sign = -1; s.removeFirst() }

        // Accept HH:MM or HHMM.
        let comps = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var hours = 0, minutes = 0
        if comps.count == 2 {
            hours = Int(comps[0]) ?? 0
            minutes = Int(comps[1]) ?? 0
        } else {
            let digits = String(s.prefix(while: { $0.isNumber }))
            if digits.count >= 3 {
                hours = Int(digits.prefix(digits.count - 2)) ?? 0
                minutes = Int(digits.suffix(2)) ?? 0
            } else {
                hours = Int(digits) ?? 0
            }
        }
        return sign * (hours * 60 + minutes)
    }

    /// Parse a Whoop CSV timestamp `YYYY-MM-DD HH:MM:SS` interpreted in the
    /// timezone given by `offsetMinutes`, returning a UTC `Date`.
    ///
    /// Some exports already include an offset inside the timestamp itself
    /// (e.g. `2024-01-02 03:04:05+0000`); when present that wins.
    static func parse(_ raw: String?, offsetMinutes: Int) -> Date? {
        guard let s0 = raw?.trimmingCharacters(in: .whitespaces), !s0.isEmpty else { return nil }

        // 1) ISO-8601 with embedded offset (e.g. "...T...Z", "...+01:00").
        if let d = isoFormatter.date(from: s0) { return d }
        if let d = isoFormatterFractional.date(from: s0) { return d }

        // 2) Plain "YYYY-MM-DD HH:MM:SS" or with a 'T'.
        let normalized = s0.replacingOccurrences(of: "T", with: " ")
        // Reuse one formatter (allocating a DateFormatter per CSV row was a measurable cost on
        // imports with tens of thousands of rows). Imports run on a single thread, so the shared
        // mutable formatter is safe; only timeZone/dateFormat are set per parse.
        let fmt = plainFormatter
        fmt.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60) ?? TimeZone(identifier: "UTC")!
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            fmt.dateFormat = pattern
            if let d = fmt.date(from: normalized) { return d }
        }
        return nil
    }

    /// Parse only an ISO-8601 timestamp that carries an **embedded UTC offset** (e.g. `…Z`,
    /// `…+01:00`), returning the absolute `Date`. Returns nil for zoneless strings, so callers can
    /// distinguish a timestamp whose offset is authoritative from a zoneless wall-clock one that must
    /// be interpreted in a chosen timezone (used by the Hevy lifting importer, #649).
    static func parseISOWithOffset(_ raw: String?) -> Date? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoFormatterFractional.date(from: s) { return d }
        return nil
    }

    private static let plainFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
