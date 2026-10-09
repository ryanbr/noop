package com.noop.ingest

/*
 * Tolerant, header-name-driven CSV reader.
 *
 * Direct Kotlin port of the macOS source of truth:
 *   Packages/StrandImport/Sources/StrandImport/CSVParsing.swift
 *
 * It must behave identically to the Swift `CSVTable` / `HeaderNorm` / `WhoopTime`
 * so the same column aliases, date parsing and unit handling apply:
 *   - UTF-8 BOM is stripped (raw bytes and decoded string).
 *   - Headers are normalized: lowercase, `%`->`pct`, drop parens (keep inner
 *     content), collapse non-alphanumerics to `_`, trim `_`.
 *   - Quoted fields (RFC-4180 `""` escaping) with embedded commas / quotes /
 *     newlines are honoured; CRLF / CR / LF are all treated as row terminators.
 *   - Rows are exposed as normalizedHeader -> rawCellString; missing columns
 *     return null. Columns are matched by name, never position.
 */

// MARK: - UTF-8 BOM handling

internal object Bom {
    /** Strip a leading UTF-8 byte-order-mark (EF BB BF) from raw bytes. */
    fun stripUtf8(data: ByteArray): ByteArray {
        if (data.size >= 3 &&
            data[0] == 0xEF.toByte() &&
            data[1] == 0xBB.toByte() &&
            data[2] == 0xBF.toByte()
        ) {
            return data.copyOfRange(3, data.size)
        }
        return data
    }

    /** Strip a leading BOM (U+FEFF) that survived string decoding. */
    fun stripString(s: String): String =
        if (s.isNotEmpty() && s[0] == '﻿') s.substring(1) else s
}

// MARK: - Header normalization

internal object HeaderNorm {
    /**
     * Normalize a CSV header to a stable lookup key.
     *
     * lowercase, `%`->`pct`, any non-ASCII-alphanumeric run -> single `_`, trim `_`.
     *   "Heart rate variability (ms)" -> "heart_rate_variability_ms"
     *   "Recovery score %"            -> "recovery_score_pct"
     */
    fun normalize(header: String): String {
        // Fold diacritics first so localized headers normalize deterministically (ä->a, ö->o,
        // ü->u), regardless of NFC/NFD form. English headers are unaffected. (issue #3)
        var s = java.text.Normalizer.normalize(header.lowercase().trim(), java.text.Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
        s = s.replace("%", "pct")
        val out = StringBuilder(s.length)
        var lastWasUnderscore = false
        for (ch in s) {
            // ASCII letters / digits are kept; everything else collapses to `_`.
            val isAsciiAlnum = (ch in 'a'..'z') || (ch in '0'..'9')
            if (isAsciiAlnum) {
                out.append(ch)
                lastWasUnderscore = false
            } else {
                if (!lastWasUnderscore) {
                    out.append('_')
                    lastWasUnderscore = true
                }
            }
        }
        var result = out.toString()
        while (result.startsWith("_")) result = result.substring(1)
        while (result.endsWith("_")) result = result.substring(0, result.length - 1)
        // Map localized column headers onto the canonical English keys the parsers look up. (issue #3)
        return foreignAliases[result] ?: result
    }

    /**
     * Localized WHOOP export column headers -> canonical English normalized keys. Keys are the
     * diacritic-folded normalized form of the foreign header. German added from a real export
     * (issue #3); more languages can be appended here. Mirrors the Swift HeaderNorm.foreignAliases.
     */
    private val foreignAliases: Map<String, String> = mapOf(
        "startzeit_des_zyklus" to "cycle_start_time",
        "endzeit_des_zyklus" to "cycle_end_time",
        "zeitzone_des_zyklus" to "cycle_timezone",
        "erholungswert_pct" to "recovery_score_pct",
        "ruheherzfrequenz_schlage_pro_minute" to "resting_heart_rate_bpm",
        "herzfrequenzvariabilitat_ms" to "heart_rate_variability_ms",
        "hauttemperatur_celsius" to "skin_temp_celsius",
        "blutsauerstoff_pct" to "blood_oxygen_pct",
        "tagesbelastung" to "day_strain",
        "verbrannte_energie_cal" to "energy_burned_cal",
        "max_hf_schlage_pro_minute" to "max_hr_bpm",
        "durchschnittliche_hf_schlage_pro_minute" to "average_hr_bpm",
        "beginn_des_schlafs" to "sleep_onset",
        "beginn_des_aufwachens" to "wake_onset",
        "schlafleistung_pct" to "sleep_performance_pct",
        "atemfrequenz_atemzuge_min" to "respiratory_rate_rpm",
        "schlafdauer_min" to "asleep_duration_min",
        "dauer_im_bett_min" to "in_bed_duration_min",
        "dauer_des_leichtschlafs_min" to "light_sleep_duration_min",
        "dauer_des_tiefschlafs_min" to "deep_sws_duration_min",
        "dauer_des_rem_schlafs_min" to "rem_duration_min",
        "dauer_des_aufwachens_min" to "awake_duration_min",
        "schlafbedarf_min" to "sleep_need_min",
        "schlafdefizit_min" to "sleep_debt_min",
        "schlafeffizienz_pct" to "sleep_efficiency_pct",
        "schlafbestandigkeit_pct" to "sleep_consistency_pct",
        "nickerchen" to "nap",
        "startzeit_des_trainings" to "workout_start_time",
        "endzeit_des_trainings" to "workout_end_time",
        "name_der_aktivitat" to "activity_name",
        "aktivitatsbelastung" to "activity_strain",
        "hf_zone_1_pct" to "hr_zone_1_pct",
        "hf_zone_2_pct" to "hr_zone_2_pct",
        "hf_zone_3_pct" to "hr_zone_3_pct",
        "hf_zone_4_pct" to "hr_zone_4_pct",
        "hf_zone_5_pct" to "hr_zone_5_pct",
        "fragetext" to "question_text",
        "beantwortet_mit_ja" to "answered_yes_no",
        "anmerkungen" to "notes",
        // — Spanish (issue #76): physiological_cycles keeps its English filename but Spanish columns;
        //   sueño.csv / entrenamientos.csv. Headers supplied by a real export. —
        "hora_de_inicio_del_ciclo" to "cycle_start_time",
        "hora_de_finalizacion_del_ciclo" to "cycle_end_time",
        "zona_horaria_del_ciclo" to "cycle_timezone",
        "puntuacion_de_recuperacion_pct" to "recovery_score_pct",
        "frecuencia_cardiaca_en_reposo_lpm" to "resting_heart_rate_bpm",
        "variabilidad_de_la_frecuencia_cardiaca_ms" to "heart_rate_variability_ms",
        "temp_cutanea_grados_centigrados" to "skin_temp_celsius",
        "oxigeno_en_sangre_pct" to "blood_oxygen_pct",
        "esfuerzo_del_dia" to "day_strain",
        "energia_quemada_cal" to "energy_burned_cal",
        "fc_max_lpm" to "max_hr_bpm",
        "fc_promedio_lpm" to "average_hr_bpm",
        "inicio_del_sueno" to "sleep_onset",
        "inicio_de_la_vigilia" to "wake_onset",
        "calificacion_del_sueno_pct" to "sleep_performance_pct",
        "frecuencia_respiratoria_rpm" to "respiratory_rate_rpm",
        "duracion_del_sueno_min" to "asleep_duration_min",
        "tiempo_en_la_cama_min" to "in_bed_duration_min",
        "duracion_de_sueno_ligero_min" to "light_sleep_duration_min",
        "duracion_de_sueno_profundo_sws_min" to "deep_sws_duration_min",
        "duracion_de_sueno_rem_min" to "rem_duration_min",
        "tempo_despierto_a_min" to "awake_duration_min",       // es export reads "Tempo despierto/a"
        "sueno_necesario_min" to "sleep_need_min",
        "deuda_de_sueno_min" to "sleep_debt_min",
        "eficiencia_del_sueno_pct" to "sleep_efficiency_pct",
        "regularidad_del_sueno_pct" to "sleep_consistency_pct",
        "siesta" to "nap",
        // Workout columns inferred from WHOOP's consistent es naming; harmless if a name differs.
        "hora_de_inicio_del_entrenamiento" to "workout_start_time",
        "hora_de_finalizacion_del_entrenamiento" to "workout_end_time",
        "nombre_de_la_actividad" to "activity_name",
        "esfuerzo_de_la_actividad" to "activity_strain",
        // — French (issue #79): physiological_cycles keeps its English filename; sommeil.csv /
        //   entrainements.csv. Full header set incl. workouts, from a real export. Apostrophes and the
        //   non-breaking space before % both fold to "_" in normalize, so these keys are exact. —
        "heure_de_debut_du_cycle" to "cycle_start_time",
        "heure_de_fin_du_cycle" to "cycle_end_time",
        "fuseau_horaire_du_cycle" to "cycle_timezone",
        "score_de_recuperation_pct" to "recovery_score_pct",
        "frequence_cardiaque_au_repos_bpm" to "resting_heart_rate_bpm",
        "variabilite_de_la_frequence_cardiaque_ms" to "heart_rate_variability_ms",
        "temperature_cutanee_celsius" to "skin_temp_celsius",
        "niveau_d_oxygene_pct" to "blood_oxygen_pct",
        "effort_du_jour" to "day_strain",
        "depense_energetique_cal" to "energy_burned_cal",
        "fc_max_bpm" to "max_hr_bpm",
        "fc_moyenne_bpm" to "average_hr_bpm",
        "premiers_signes_de_sommeil" to "sleep_onset",
        "premiers_signes_de_reveil" to "wake_onset",
        "performance_sommeil_pct" to "sleep_performance_pct",
        "frequence_respiratoire_tr_min" to "respiratory_rate_rpm",
        "duree_du_sommeil_min" to "asleep_duration_min",
        "temps_passe_au_lit_min" to "in_bed_duration_min",
        "duree_du_sommeil_leger_min" to "light_sleep_duration_min",
        "duree_du_sommeil_profond_min" to "deep_sws_duration_min",
        "duree_du_sommeil_paradoxal_min" to "rem_duration_min",      // paradoxal = REM
        "temps_d_eveil_min" to "awake_duration_min",
        "besoins_en_sommeil_min" to "sleep_need_min",
        "dette_de_sommeil_min" to "sleep_debt_min",
        "efficacite_du_sommeil_pct" to "sleep_efficiency_pct",
        "regularite_du_sommeil_pct" to "sleep_consistency_pct",
        "sieste" to "nap",
        "heure_de_debut_de_l_entrainement" to "workout_start_time",
        "heure_de_fin_de_l_entrainement" to "workout_end_time",
        "nom_de_l_activite" to "activity_name",
        "effort_activite" to "activity_strain",
        "zone_fc_1_pct" to "hr_zone_1_pct",
        "zone_fc_2_pct" to "hr_zone_2_pct",
        "zone_fc_3_pct" to "hr_zone_3_pct",
        "zone_fc_4_pct" to "hr_zone_4_pct",
        "zone_fc_5_pct" to "hr_zone_5_pct",
        // — Brazilian Portuguese (ciclos_fisiológicos / sonos / treinos / entradas_diário), issue #692.
        //   Full header set across cycles, sleeps, workouts and journal, from a real pt-BR export. Note
        //   "FC máx." folds to the same key as the French "FC max." alias above; in a Kotlin mapOf a
        //   duplicate key would shadow rather than extend, so it is deliberately NOT repeated here. —
        "hora_de_inicio_do_ciclo" to "cycle_start_time",
        "hora_de_fim_do_ciclo" to "cycle_end_time",
        "fuso_horario_do_ciclo" to "cycle_timezone",
        "pontuacao_de_recuperacao_pct" to "recovery_score_pct",
        "frequencia_cardiaca_em_repouso_bpm" to "resting_heart_rate_bpm",
        "variabilidade_da_frequencia_cardiaca_ms" to "heart_rate_variability_ms",
        "temp_da_pele_celsius" to "skin_temp_celsius",
        "pct_de_oxigenio_no_sangue" to "blood_oxygen_pct",   // "% de oxigênio no sangue" → leading % becomes pct_…
        "esforco_diario" to "day_strain",
        "energia_queimada_cal" to "energy_burned_cal",
        "fc_media_bpm" to "average_hr_bpm",
        "inicio_do_sono" to "sleep_onset",
        "inicio_da_vigilia" to "wake_onset",
        "desempenho_do_sono_pct" to "sleep_performance_pct",
        "frequencia_respiratoria_rpm" to "respiratory_rate_rpm",
        "duracao_do_sono_min" to "asleep_duration_min",
        "duracao_na_cama_min" to "in_bed_duration_min",
        "duracao_do_sono_leve_min" to "light_sleep_duration_min",
        "duracao_profundo_sono_min" to "deep_sws_duration_min",   // "Duração profundo (Sono) (min)"
        "duracao_rem_min" to "rem_duration_min",
        "duracao_de_vigilia_min" to "awake_duration_min",
        "necessidade_de_sono_min" to "sleep_need_min",
        "debito_de_sono_min" to "sleep_debt_min",
        "eficacia_do_sono_pct" to "sleep_efficiency_pct",
        "consistencia_do_sono_pct" to "sleep_consistency_pct",
        "sesta" to "nap",
        "hora_de_inicio_do_treino" to "workout_start_time",
        "hora_de_fim_do_treino" to "workout_end_time",
        "nome_da_atividade" to "activity_name",
        "esforco_da_atividade" to "activity_strain",
        "zona_1_de_fc_pct" to "hr_zone_1_pct",
        "zona_2_de_fc_pct" to "hr_zone_2_pct",
        "zona_3_de_fc_pct" to "hr_zone_3_pct",
        "zona_4_de_fc_pct" to "hr_zone_4_pct",
        "zona_5_de_fc_pct" to "hr_zone_5_pct",
        "texto_de_pergunta" to "question_text",
        "respondeu_sim" to "answered_yes_no",
        "notas" to "notes",
        // — Italian (cicli_fisiologici / sonno / allenamenti / voci_diario). Every header the importers read
        //   across cycles, sleeps, workouts and journal, from a real Italian export ("Durata (min)" and
        //   "GPS abilitato" are not read in any language). "FC max." and "FC media" fold to the same
        //   keys as the French and pt-BR aliases above, so they are deliberately NOT repeated here. The
        //   journal "Note" column is NOT aliased either: a global "note" key would rename the lift-program
        //   template's own "Note" column, so the journal parser reads "note" as a fallback instead. —
        "ora_di_inizio_ciclo" to "cycle_start_time",
        "ora_di_fine_ciclo" to "cycle_end_time",
        "fuso_orario_ciclo" to "cycle_timezone",
        "punteggio_di_recupero_pct" to "recovery_score_pct",
        "frequenza_cardiaca_a_riposo_bpm" to "resting_heart_rate_bpm",
        "variabilita_della_frequenza_cardiaca_ms" to "heart_rate_variability_ms",
        "temp_cutanea_c" to "skin_temp_celsius",
        "ossigeno_nel_sangue_pct" to "blood_oxygen_pct",
        "sforzo_giornaliero" to "day_strain",
        "energia_bruciata_cal" to "energy_burned_cal",
        "inizio_del_sonno" to "sleep_onset",
        "inizio_del_risveglio" to "wake_onset",
        "andamento_del_sonno_pct" to "sleep_performance_pct",
        "frequenza_respiratoria_rpm" to "respiratory_rate_rpm",
        "durata_del_sonno_min" to "asleep_duration_min",
        "tempo_a_letto_min" to "in_bed_duration_min",
        "durata_del_sonno_leggero_min" to "light_sleep_duration_min",
        "durata_profondo_sws_min" to "deep_sws_duration_min",
        "durata_rem_min" to "rem_duration_min",
        "durata_del_risveglio_min" to "awake_duration_min",
        "sonno_richiesto_min" to "sleep_need_min",
        "sonno_arretrato_min" to "sleep_debt_min",
        "efficienza_del_sonno_pct" to "sleep_efficiency_pct",
        "regolarita_del_sonno_pct" to "sleep_consistency_pct",
        "riposo_breve" to "nap",
        "ora_di_inizio_allenamento" to "workout_start_time",
        "ora_di_fine_allenamento" to "workout_end_time",
        "nome_attivita" to "activity_name",
        "sforzo_richiesto_dall_attivita" to "activity_strain",
        "zona_fc_1_pct" to "hr_zone_1_pct",
        "zona_fc_2_pct" to "hr_zone_2_pct",
        "zona_fc_3_pct" to "hr_zone_3_pct",
        "zona_fc_4_pct" to "hr_zone_4_pct",
        "zona_fc_5_pct" to "hr_zone_5_pct",
        "testo_domanda" to "question_text",
        "risposta_affermativa" to "answered_yes_no",
    )
}

// MARK: - Tolerant CSV reader

/**
 * A parsed CSV table. Rows are normalized-key -> cell-value maps; callers match
 * columns by name. Mirrors Swift `CSVTable`.
 */
internal class CsvTable private constructor(
    val headers: List<String>,
    val normalizedHeaders: List<String>,
    val rows: List<Map<String, String>>,
) {
    companion object {
        /** Parse from raw bytes: strip UTF-8 BOM, decode UTF-8 then Latin-1 fallback. */
        fun fromData(data: ByteArray): CsvTable {
            val clean = Bom.stripUtf8(data)
            val text = decode(clean)
            return fromText(text)
        }

        private fun decode(bytes: ByteArray): String {
            // Try strict UTF-8; on malformed input fall back to Latin-1 (every byte maps).
            return try {
                val decoder = Charsets.UTF_8.newDecoder()
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            } catch (_: Exception) {
                String(bytes, Charsets.ISO_8859_1)
            }
        }

        /** Parse CSV text. */
        fun fromText(rawText: String): CsvTable {
            val text = Bom.stripString(rawText)
            // Detect the field delimiter from the header line. WHOOP exports are comma-separated, but a
            // real Oura account-export CSV uses `;` (and some locales' exports use `;`/tab). Sniffing per
            // file lets one parser read all of them; default stays `,` so the WHOOP path is unchanged.
            // (issue #862)
            val delimiter = detectDelimiter(text)
            val records = parseRecords(text, delimiter).toMutableList()
            if (records.isEmpty()) {
                return CsvTable(emptyList(), emptyList(), emptyList())
            }
            val headerRow = records.removeAt(0)
            val normHeaders = headerRow.map { HeaderNorm.normalize(it) }

            val parsedRows = ArrayList<Map<String, String>>(records.size)
            for (fields in records) {
                // Skip completely blank lines (single empty/whitespace field).
                if (fields.size == 1 && fields[0].trim().isEmpty()) continue
                val dict = HashMap<String, String>(normHeaders.size)
                for (i in normHeaders.indices) {
                    val key = normHeaders[i]
                    if (key.isEmpty()) continue
                    val value = if (i < fields.size) fields[i] else ""
                    // First non-empty header wins if duplicated (rare).
                    val existing = dict[key]
                    if (existing == null || existing.isEmpty()) {
                        dict[key] = value
                    }
                }
                parsedRows.add(dict)
            }
            return CsvTable(headerRow, normHeaders, parsedRows)
        }

        // MARK: Delimiter detection

        /**
         * Sniff the field delimiter from the FIRST (header) line: whichever of `,`, `;` or tab appears
         * most outside quotes. Defaults to `,` (WHOOP / Fitbit unaffected) when none is present. Only
         * the header line is scanned. Mirrors Swift `CSVTable.detectDelimiter`. (issue #862)
         */
        fun detectDelimiter(text: String): Char {
            var commas = 0; var semis = 0; var tabs = 0
            var inQuotes = false
            for (ch in text) {
                if (ch == '"') { inQuotes = !inQuotes; continue }
                if (inQuotes) continue
                if (ch == '\n' || ch == '\r') break   // header line only
                when (ch) {
                    ',' -> commas++
                    ';' -> semis++
                    '\t' -> tabs++
                }
            }
            if (semis > commas && semis >= tabs) return ';'
            if (tabs > commas && tabs > semis) return '\t'
            return ','
        }

        // MARK: RFC-4180-ish record splitter

        /**
         * Split CSV text into records of fields, honouring quotes and `""` escapes,
         * and treating CRLF / CR / LF uniformly as row terminators.
         * Faithful port of `CSVTable.parseRecords` (operates on Unicode code points).
         * [delimiter] is the field separator (auto-detected per file; `,` by default).
         */
        fun parseRecords(text: String, delimiter: Char = ','): List<List<String>> {
            val records = ArrayList<List<String>>()
            val field = StringBuilder()
            var record = ArrayList<String>()
            var inQuotes = false
            var sawAnyField = false

            // Iterate over Unicode code points (parity with Swift's unicodeScalars).
            val codePoints = ArrayList<Int>(text.length)
            var idx = 0
            while (idx < text.length) {
                val cp = text.codePointAt(idx)
                codePoints.add(cp)
                idx += Character.charCount(cp)
            }

            var pos = 0
            var pending: Int? = null

            fun nextScalar(): Int? {
                pending?.let { pending = null; return it }
                return if (pos < codePoints.size) codePoints[pos++] else null
            }
            fun peekConsume(): Int? = if (pos < codePoints.size) codePoints[pos++] else null

            val quote = '"'.code
            val comma = delimiter.code   // field separator (auto-detected per file)
            val cr = '\r'.code
            val lf = '\n'.code

            while (true) {
                val scalar = nextScalar() ?: break
                if (inQuotes) {
                    if (scalar == quote) {
                        // Look ahead for an escaped quote ("").
                        val look = peekConsume()
                        if (look != null) {
                            if (look == quote) {
                                field.appendCodePoint(quote)
                            } else {
                                inQuotes = false
                                pending = look
                            }
                        } else {
                            inQuotes = false
                        }
                    } else {
                        field.appendCodePoint(scalar)
                    }
                } else {
                    when (scalar) {
                        quote -> {
                            inQuotes = true
                            sawAnyField = true
                        }
                        comma -> {
                            record.add(field.toString())
                            field.setLength(0)
                            sawAnyField = true
                        }
                        cr -> {
                            // Consume an optional following \n (CRLF).
                            val look = peekConsume()
                            if (look != null && look != lf) {
                                pending = look
                            }
                            record.add(field.toString())
                            records.add(record)
                            field.setLength(0)
                            record = ArrayList()
                            sawAnyField = false
                        }
                        lf -> {
                            record.add(field.toString())
                            records.add(record)
                            field.setLength(0)
                            record = ArrayList()
                            sawAnyField = false
                        }
                        else -> {
                            field.appendCodePoint(scalar)
                            sawAnyField = true
                        }
                    }
                }
            }
            // Flush the final field/record if the file didn't end with a newline.
            if (sawAnyField || field.isNotEmpty() || record.isNotEmpty()) {
                record.add(field.toString())
                records.add(record)
            }
            return records
        }
    }
}

// MARK: - Cell accessors (mirror the Swift Dictionary extension)

/** First non-empty cell among the given normalized keys, trimmed; null if absent/blank. */
internal fun Map<String, String>.cell(vararg keys: String): String? {
    for (k in keys) {
        val v = this[k] ?: continue
        val t = v.trim()
        if (t.isNotEmpty()) return t
    }
    return null
}

/**
 * Parse a cell as a Double across the given keys, tolerating thousands separators
 * and stray units accidentally left in the cell (e.g. "1,234" or "62 ms").
 */
internal fun Map<String, String>.double(vararg keys: String): Double? {
    for (k in keys) {
        val v = this[k] ?: continue
        val t = v.trim()
        if (t.isEmpty()) continue
        t.toDoubleOrNull()?.let { return it }
        // Tolerate values like "1,234" or "62 ms": strip commas, keep only numeric chars.
        val allowed = "0123456789.+-eE"
        val cleaned = buildString {
            for (ch in t.replace(",", "")) {
                if (ch in allowed) append(ch)
            }
        }
        cleaned.toDoubleOrNull()?.let { return it }
    }
    return null
}

/** Parse a cell as a boolean (`true`/`yes`/`1`/`y` vs `false`/`no`/`0`/`n`); null otherwise. */
internal fun Map<String, String>.bool(vararg keys: String): Boolean? {
    for (k in keys) {
        val v = this[k] ?: continue
        val t = v.trim().lowercase()
        if (t.isEmpty()) continue
        if (t == "true" || t == "yes" || t == "1" || t == "y") return true
        if (t == "false" || t == "no" || t == "0" || t == "n") return false
    }
    return null
}

// MARK: - Whoop timestamp parsing (mirror Swift WhoopTime)

internal object WhoopTime {

    /**
     * Parse a `Cycle timezone` string like `UTC+01:00`, `UTC-05:00`, `+01:00`, or
     * `Z` into an offset in **minutes**. Returns 0 for UTC / GMT / Z / blank.
     */
    fun tzOffsetMinutes(raw: String?): Int {
        var s = raw?.trim() ?: return 0
        if (s.isEmpty()) return 0
        val upper = s.uppercase()
        if (upper == "UTC" || upper == "Z" || upper == "GMT") return 0
        if (upper.startsWith("UTC")) s = s.substring(3)
        else if (upper.startsWith("GMT")) s = s.substring(3)
        s = s.trim()
        if (s.isEmpty() || s == "Z") return 0

        var sign = 1
        if (s.startsWith("+")) s = s.substring(1)
        else if (s.startsWith("-")) { sign = -1; s = s.substring(1) }

        // Accept HH:MM or HHMM.
        var hours: Int
        var minutes = 0
        val colonIdx = s.indexOf(':')
        if (colonIdx >= 0) {
            hours = s.substring(0, colonIdx).toIntOrNull() ?: 0
            minutes = s.substring(colonIdx + 1).toIntOrNull() ?: 0
        } else {
            val digits = s.takeWhile { it.isDigit() }
            if (digits.length >= 3) {
                hours = digits.substring(0, digits.length - 2).toIntOrNull() ?: 0
                minutes = digits.substring(digits.length - 2).toIntOrNull() ?: 0
            } else {
                hours = digits.toIntOrNull() ?: 0
            }
        }
        return sign * (hours * 60 + minutes)
    }

    /**
     * Parse a Whoop CSV timestamp interpreted in the timezone given by
     * [offsetMinutes], returning **UTC unix epoch SECONDS** (Long), or null.
     *
     * Mirrors Swift `WhoopTime.parse`:
     *   1. ISO-8601 with embedded offset (e.g. "...T...Z", "...+01:00", fractional secs) wins.
     *   2. Otherwise plain "YYYY-MM-DD HH:MM:SS" / " HH:MM" / "YYYY-MM-DD",
     *      interpreted at the supplied offset.
     */
    fun parseEpochSeconds(raw: String?, offsetMinutes: Int): Long? {
        val s0 = raw?.trim() ?: return null
        if (s0.isEmpty()) return null

        // 1) ISO-8601 with an embedded offset / Z (own offset wins).
        parseIso(s0)?.let { return it }

        // 2) Plain timestamp at the supplied offset. Normalize 'T' to space.
        val normalized = s0.replace("T", " ")
        val zoneOffset = try {
            java.time.ZoneOffset.ofTotalSeconds(offsetMinutes * 60)
        } catch (_: Exception) {
            java.time.ZoneOffset.UTC
        }
        // "yyyy-MM-dd HH:mm:ss"
        runCatching {
            val ldt = java.time.LocalDateTime.parse(
                normalized, FULL_DATETIME
            )
            return ldt.toEpochSecond(zoneOffset)
        }
        // "yyyy-MM-dd HH:mm"
        runCatching {
            val ldt = java.time.LocalDateTime.parse(
                normalized, MINUTE_DATETIME
            )
            return ldt.toEpochSecond(zoneOffset)
        }
        // "yyyy-MM-dd"
        runCatching {
            val ld = java.time.LocalDate.parse(normalized, DATE_ONLY)
            return ld.atStartOfDay(zoneOffset).toEpochSecond()
        }
        return null
    }

    /** Parse an ISO-8601 string carrying its own offset/zone into epoch seconds. */
    private fun parseIso(s: String): Long? {
        // OffsetDateTime handles "Z" and "+01:00" plus optional fractional seconds.
        runCatching {
            return java.time.OffsetDateTime.parse(s).toEpochSecond()
        }
        // Some exports use "+0000" (no colon). Try Instant for a trailing 'Z'.
        runCatching {
            return java.time.Instant.parse(s).epochSecond
        }
        return null
    }

    /**
     * Parse only an ISO-8601 timestamp that carries an **embedded UTC offset** (e.g. "…Z",
     * "…+01:00"), returning epoch seconds; null for a zoneless string. Mirror of Swift
     * `WhoopTime.parseISOWithOffset` — lets callers tell an authoritative-offset timestamp apart from
     * a zoneless wall-clock one that must be interpreted in a chosen zone (Hevy lifting importer, #649).
     */
    fun parseIsoWithOffsetEpochSeconds(raw: String?): Long? {
        val s = raw?.trim() ?: return null
        if (s.isEmpty()) return null
        return parseIso(s)
    }

    private val FULL_DATETIME: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
    private val MINUTE_DATETIME: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
    private val DATE_ONLY: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd")
}
