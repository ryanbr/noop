package com.noop.analytics

import com.noop.data.DailyMetric

/**
 * Readiness plus descriptive long-horizon training-load state.
 *
 * CTL/ATL/TSB stay OUTSIDE the Readiness synthesis: this wrapper does not change the existing level,
 * signals, confidence, ACWR, or monotony. Twin of Swift `ReadinessEngine.evaluateWithTrainingLoad`.
 */
data class ReadinessTrainingLoadAnalysis(
    val readiness: ReadinessEngine.Readiness,
    val trainingLoad: TrainingLoadEngine.Result,
)

fun ReadinessEngine.evaluateWithTrainingLoad(
    days: List<DailyMetric>,
    today: String? = null,
    trainingLoadConfiguration: TrainingLoadEngine.Configuration = TrainingLoadEngine.standard,
): ReadinessTrainingLoadAnalysis {
    val readiness = evaluate(days, today)
    val trainingDays = days.map { TrainingLoadEngine.DailyLoad(it.day, it.strain) }
    val trainingLoad = TrainingLoadEngine.evaluate(
        trainingDays,
        through = today,
        configuration = trainingLoadConfiguration,
    )
    return ReadinessTrainingLoadAnalysis(readiness, trainingLoad)
}
