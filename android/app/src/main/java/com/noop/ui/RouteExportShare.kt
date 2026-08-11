package com.noop.ui

import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.core.content.FileProvider
import com.noop.analytics.RouteMath
import com.noop.data.WorkoutRow
import com.noop.ingest.RouteExport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Share a recorded workout route as a GPX/FIT file — the UI-layer wrapper around the pure
 * [com.noop.ingest.RouteExport] builder (which stays Android-free/JVM-testable). Mirrors
 * [LogExport.shareStrapLog]: write the bytes to a shared cache subdir, then hand a FileProvider URI to a
 * chooser. The Swift twin is `WorkoutDetailView.exportRoute`.
 */
object RouteExportShare {

    suspend fun share(
        context: Context,
        format: RouteExport.Format,
        track: List<RouteMath.LatLng>,
        row: WorkoutRow,
    ) {
        runCatching {
            val filename = "noop-route-${row.startTs}.${format.ext}"
            // Build the file AND write it off the main thread — a long route (10k+ points) is a non-trivial
            // string/byte build, and file IO must never block the UI. Only the chooser launch stays on Main.
            val file = withContext(Dispatchers.IO) {
                val points = track.map { RouteExport.Point(it.lat, it.lon) }
                val bytes = RouteExport.render(
                    format, points, row.startTs, row.endTs, row.sport,
                    distanceM = row.distanceM, energyKcal = row.energyKcal, avgHr = row.avgHr, maxHr = row.maxHr,
                )
                File(File(context.cacheDir, "exports").apply { mkdirs() }, filename)
                    .apply { writeBytes(bytes) }
            }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val mime = if (format == RouteExport.Format.GPX) "application/gpx+xml" else "application/octet-stream"
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "NOOP workout route")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Share route"))
        }.onFailure {
            Toast.makeText(context, "Couldn't export the route: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }
}
