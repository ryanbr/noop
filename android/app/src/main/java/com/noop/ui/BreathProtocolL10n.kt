package com.noop.ui

/*
 * BreathProtocolL10n.kt – maps breath catalog IDs to localized string resources.
 * Created: 2026-08-16
 * Last updated: 2026-08-16
 *
 * Analytics catalog keeps English source strings (Swift String Catalog keys).
 * Android UI resolves copy through R.string — never show catalog literals raw.
 */

import androidx.annotation.StringRes
import com.noop.R

data class BreathProtocolCopyIds(
    @StringRes val title: Int,
    @StringRes val subtitle: Int,
    @StringRes val edu: Int,
    @StringRes val sessionHint: Int? = null,
    @StringRes val caution: Int? = null,
)

fun breathProtocolCopyIds(id: String): BreathProtocolCopyIds? = when (id) {
        "relax_4_6" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_relax_4_6_title,
            subtitle = R.string.breath_proto_relax_4_6_subtitle,
            edu = R.string.breath_proto_relax_4_6_edu,
            sessionHint = R.string.breath_proto_relax_4_6_session_hint,
            caution = null,
        )
        "coherence_5_5" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_coherence_5_5_title,
            subtitle = R.string.breath_proto_coherence_5_5_subtitle,
            edu = R.string.breath_proto_coherence_5_5_edu,
            sessionHint = R.string.breath_proto_coherence_5_5_session_hint,
            caution = null,
        )
        "box_4_4_4_4" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_box_4_4_4_4_title,
            subtitle = R.string.breath_proto_box_4_4_4_4_subtitle,
            edu = R.string.breath_proto_box_4_4_4_4_edu,
            sessionHint = R.string.breath_proto_box_4_4_4_4_session_hint,
            caution = null,
        )
        "deep_4_2_6" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_deep_4_2_6_title,
            subtitle = R.string.breath_proto_deep_4_2_6_subtitle,
            edu = R.string.breath_proto_deep_4_2_6_edu,
            sessionHint = R.string.breath_proto_deep_4_2_6_session_hint,
            caution = null,
        )
        "diaphragmatic_4_2_6" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_diaphragmatic_4_2_6_title,
            subtitle = R.string.breath_proto_diaphragmatic_4_2_6_subtitle,
            edu = R.string.breath_proto_diaphragmatic_4_2_6_edu,
            sessionHint = R.string.breath_proto_diaphragmatic_4_2_6_session_hint,
            caution = null,
        )
        "nadi_shodhana" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_nadi_shodhana_title,
            subtitle = R.string.breath_proto_nadi_shodhana_subtitle,
            edu = R.string.breath_proto_nadi_shodhana_edu,
            sessionHint = R.string.breath_proto_nadi_shodhana_session_hint,
            caution = null,
        )
        "four_seven_eight" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_four_seven_eight_title,
            subtitle = R.string.breath_proto_four_seven_eight_subtitle,
            edu = R.string.breath_proto_four_seven_eight_edu,
            sessionHint = R.string.breath_proto_four_seven_eight_session_hint,
            caution = R.string.breath_proto_four_seven_eight_caution,
        )
        "buteyko" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_buteyko_title,
            subtitle = R.string.breath_proto_buteyko_subtitle,
            edu = R.string.breath_proto_buteyko_edu,
            sessionHint = R.string.breath_proto_buteyko_session_hint,
            caution = R.string.breath_proto_buteyko_caution,
        )
        "tummo" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_tummo_title,
            subtitle = R.string.breath_proto_tummo_subtitle,
            edu = R.string.breath_proto_tummo_edu,
            sessionHint = R.string.breath_proto_tummo_session_hint,
            caution = R.string.breath_proto_tummo_caution,
        )
        "ujjayi" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_ujjayi_title,
            subtitle = R.string.breath_proto_ujjayi_subtitle,
            edu = R.string.breath_proto_ujjayi_edu,
            sessionHint = R.string.breath_proto_ujjayi_session_hint,
            caution = null,
        )
        "bhastrika" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_bhastrika_title,
            subtitle = R.string.breath_proto_bhastrika_subtitle,
            edu = R.string.breath_proto_bhastrika_edu,
            sessionHint = R.string.breath_proto_bhastrika_session_hint,
            caution = R.string.breath_proto_bhastrika_caution,
        )
        "qigong" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_qigong_title,
            subtitle = R.string.breath_proto_qigong_subtitle,
            edu = R.string.breath_proto_qigong_edu,
            sessionHint = R.string.breath_proto_qigong_session_hint,
            caution = null,
        )
        "soma" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_soma_title,
            subtitle = R.string.breath_proto_soma_subtitle,
            edu = R.string.breath_proto_soma_edu,
            sessionHint = R.string.breath_proto_soma_session_hint,
            caution = null,
        )
        "buteyko_reduced" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_buteyko_reduced_title,
            subtitle = R.string.breath_proto_buteyko_reduced_subtitle,
            edu = R.string.breath_proto_buteyko_reduced_edu,
            sessionHint = R.string.breath_proto_buteyko_reduced_session_hint,
            caution = R.string.breath_proto_buteyko_reduced_caution,
        )
        "coherent_6_6" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_coherent_6_6_title,
            subtitle = R.string.breath_proto_coherent_6_6_subtitle,
            edu = R.string.breath_proto_coherent_6_6_edu,
            sessionHint = R.string.breath_proto_coherent_6_6_session_hint,
            caution = null,
        )
        "kapalabhati" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_kapalabhati_title,
            subtitle = R.string.breath_proto_kapalabhati_subtitle,
            edu = R.string.breath_proto_kapalabhati_edu,
            sessionHint = R.string.breath_proto_kapalabhati_session_hint,
            caution = R.string.breath_proto_kapalabhati_caution,
        )
        "holotropic" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_holotropic_title,
            subtitle = R.string.breath_proto_holotropic_subtitle,
            edu = R.string.breath_proto_holotropic_edu,
            sessionHint = R.string.breath_proto_holotropic_session_hint,
            caution = R.string.breath_proto_holotropic_caution,
        )
        "wim_hof" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_wim_hof_title,
            subtitle = R.string.breath_proto_wim_hof_subtitle,
            edu = R.string.breath_proto_wim_hof_edu,
            sessionHint = R.string.breath_proto_wim_hof_session_hint,
            caution = R.string.breath_proto_wim_hof_caution,
        )
        "shamanic" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_shamanic_title,
            subtitle = R.string.breath_proto_shamanic_subtitle,
            edu = R.string.breath_proto_shamanic_edu,
            sessionHint = R.string.breath_proto_shamanic_session_hint,
            caution = R.string.breath_proto_shamanic_caution,
        )
        "presence_regular" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_presence_regular_title,
            subtitle = R.string.breath_proto_presence_regular_subtitle,
            edu = R.string.breath_proto_presence_regular_edu,
            sessionHint = R.string.breath_proto_presence_regular_session_hint,
            caution = null,
        )
        "presence_mid" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_presence_mid_title,
            subtitle = R.string.breath_proto_presence_mid_subtitle,
            edu = R.string.breath_proto_presence_mid_edu,
            sessionHint = R.string.breath_proto_presence_mid_session_hint,
            caution = null,
        )
        "presence_punching" -> BreathProtocolCopyIds(
            title = R.string.breath_proto_presence_punching_title,
            subtitle = R.string.breath_proto_presence_punching_subtitle,
            edu = R.string.breath_proto_presence_punching_edu,
            sessionHint = R.string.breath_proto_presence_punching_session_hint,
            caution = R.string.breath_proto_presence_punching_caution,
        )
    else -> null
}

@StringRes
fun breathPresenceIntroTitleRes(): Int = R.string.breath_presence_intro_title

@StringRes
fun breathPresenceIntroBodyRes(): Int = R.string.breath_presence_intro_body

fun localizedBreathTitle(id: String): String =
    breathProtocolCopyIds(id)?.let { uiString(it.title) } ?: id

fun localizedBreathSubtitle(id: String): String =
    breathProtocolCopyIds(id)?.let { uiString(it.subtitle) }.orEmpty()

@StringRes
fun breathStageLabelRes(label: String): Int? = when (label) {
        "Belly in" -> R.string.breath_stage_belly_in
        "Belly out" -> R.string.breath_stage_belly_out
        "Exhale left" -> R.string.breath_stage_exhale_left
        "Exhale right" -> R.string.breath_stage_exhale_right
        "Force out" -> R.string.breath_stage_force_out
        "Hold empty" -> R.string.breath_stage_hold_empty
        "Hold full" -> R.string.breath_stage_hold_full
        "Inhale left" -> R.string.breath_stage_inhale_left
        "Inhale right" -> R.string.breath_stage_inhale_right
    else -> null
}

fun localizedBreathStageLabel(label: String): String =
    breathStageLabelRes(label)?.let { uiString(it) } ?: label
