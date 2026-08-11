package com.noop.ui

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.widget.Toast
import androidx.compose.ui.geometry.Rect
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Share the weekly-recap card as a PNG. The image sibling of [RouteExportShare] / [TrendsReportShare]; the
 * Swift twin is `TrendsReportRenderer.exportPNG`.
 *
 * Capture uses the app's established [com.noop.testcentre.DisplayScreenshot] technique — draw the Compose
 * host [View] into a software Bitmap (no Compose-1.7 `GraphicsLayer` API, which this Compose 1.6.8 build
 * lacks) — then crop to the card's on-screen bounds. The card sits on the screen's `surfaceBase`, so the
 * crop is already opaque.
 */
object RecapShare {

    /** Draw [view] (the Compose host) and crop to [bounds] (the card, in the view's coordinate space).
     *  Returns null on any failure. Runs on the main thread — cheap for a single tap. */
    fun captureCropped(view: View, bounds: Rect): Bitmap? = runCatching {
        if (view.width <= 0 || view.height <= 0) return null
        val full = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(full))
        // Crop the INTERSECTION of the card with the view — if the card is partially scrolled off, this
        // captures only its visible part instead of over-running past its edge into content below.
        val left = bounds.left.toInt().coerceIn(0, full.width)
        val top = bounds.top.toInt().coerceIn(0, full.height)
        val right = bounds.right.toInt().coerceIn(left, full.width)
        val bottom = bounds.bottom.toInt().coerceIn(top, full.height)
        val w = right - left
        val h = bottom - top
        if (w < 1 || h < 1) return null
        val cropped = Bitmap.createBitmap(full, left, top, w, h)
        if (cropped !== full) full.recycle()
        cropped
    }.getOrNull()

    suspend fun share(context: Context, bitmap: Bitmap, anchorDay: String) {
        runCatching {
            val filename = "noop-recap-$anchorDay.png"
            // Encode + write off the main thread — never block the UI on bitmap compression or file IO.
            val file = withContext(Dispatchers.IO) {
                val bytes = ByteArrayOutputStream().use { s ->
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, s)
                    s.toByteArray()
                }
                File(File(context.cacheDir, "recaps").apply { mkdirs() }, filename)
                    .apply { writeBytes(bytes) }
            }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "NOOP weekly recap")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Share recap"))
        }.onFailure {
            Toast.makeText(context, "Couldn't share the recap: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }
}
