package com.noop.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.clearAndSetSemantics
import java.io.File

// MARK: - Custom background image (#custom-background)
//
// A user-picked photo drawn full-bleed behind EVERY screen, REPLACING the day-cycle sky when enabled
// (precedence: image > sky > flat canvas). Cloned from ProfileAvatarStore (ProfileAvatar.kt): the picked
// image is downscaled + re-encoded to a single app-private JPEG, and the decoded [ImageBitmap] is held in
// SNAPSHOT state so toggling/replacing it re-renders the backdrop live. Larger than the avatar (this fills
// the whole screen), so MAX_DIMEN is the screen scale, not 256.
//
// The three prefs (enabled / fillMode / present) live in NoopPrefs (byte-identical keys to the iOS
// BackgroundImagePrefs). The image file itself is device-local, like the avatar — deliberately NOT in the
// .noopbak whitelist. The iOS twin is Strand/System/BackgroundImageStore.swift.

/**
 * The on-device custom background image. Snapshot-backed ([bitmap]/[enabled]/[fillMode]) so every
 * screen's backdrop updates live when the photo, the enable toggle, or the fill mode changes in Settings.
 * The bytes persist to `filesDir/background.jpg`; the toggles persist via [NoopPrefs]. [load] runs once
 * from MainActivity before first composition.
 */
object BackgroundImageStore {
    /** Longest edge (px) the stored image is downscaled to. Big enough to cover a large tablet/foldable
     *  screen crisply, capped so a 100MP pick can never fully decode into memory (it sub-samples first). */
    private const val MAX_DIMEN = 2560

    /** Longest edge (px) for the small recent-image PREVIEW thumbnails in Settings. */
    private const val THUMB_DIMEN = 256

    /** JPEG quality for the re-encoded background — a touch higher than the avatar since it fills the
     *  whole screen behind (semi-transparent) cards, still modest on disk. */
    private const val JPEG_QUALITY = 90

    /** How many recent images the "presets" strip keeps (MRU). */
    const val MAX_RECENTS = 3

    /** One recent background: its app-private filename + the fill mode it was last shown with. */
    data class Recent(val id: String, val fillMode: BackgroundFillMode)

    /** The recent images, most-recent (== ACTIVE) first, up to [MAX_RECENTS]. Snapshot-backed. */
    var recents by mutableStateOf<List<Recent>>(emptyList())
        private set

    /** The active (recents[0]) decoded full-size for the backdrop; null = none stored. */
    var bitmap by mutableStateOf<ImageBitmap?>(null)
        private set

    /** Small preview thumbnails, index-aligned to [recents] (null for a decode miss). */
    var thumbnails by mutableStateOf<List<ImageBitmap?>>(emptyList())
        private set

    /** Master enable toggle (mirrors NoopPrefs.backgroundImageEnabled), snapshot-backed for live redraw. */
    var enabled by mutableStateOf(false)
        private set

    /** How the ACTIVE image is scaled — the fill mode of the most-recent entry. */
    val fillMode: BackgroundFillMode get() = recents.firstOrNull()?.fillMode ?: BackgroundFillMode.FILL

    /** True when a photo is stored — drives the Remove affordance in Settings. */
    val hasImage: Boolean get() = bitmap != null

    /** The custom image is the ACTIVE backdrop (top of the precedence: enabled AND actually decoded). */
    val isActive: Boolean get() = enabled && bitmap != null

    private fun file(app: Context, id: String): File = File(app.applicationContext.filesDir, id)

    /** Load the toggles + the recent list (migrating a pre-recents single `background.jpg`). */
    fun load(ctx: Context) {
        val app = ctx.applicationContext
        enabled = NoopPrefs.backgroundImageEnabled(app)
        var list = parseRecents(NoopPrefs.backgroundRecents(app)).filter { file(app, it.id).exists() }
        // Migration: pre-recents installs stored ONE `background.jpg`; adopt it as the sole recent so an
        // upgrading user keeps their background.
        if (list.isEmpty() && NoopPrefs.backgroundImagePresent(app) && file(app, "background.jpg").exists()) {
            list = listOf(Recent("background.jpg", NoopPrefs.backgroundFillMode(app)))
        }
        recents = list.take(MAX_RECENTS)
        // GC orphan background files (bg-*.jpg / legacy background.jpg) not referenced by the list — e.g.
        // one left by a crash between writing a pick and persisting the list. Only OUR files are matched.
        val kept = recents.map { it.id }.toSet()
        app.filesDir.listFiles { f -> f.isFile && (f.name.startsWith("bg-") || f.name == "background.jpg") }
            ?.forEach { if (it.name !in kept) runCatching { it.delete() } }
        refreshDecoded(app)
        persist(app)
    }

    fun setEnabled(ctx: Context, on: Boolean) {
        enabled = on
        NoopPrefs.setBackgroundImageEnabled(ctx.applicationContext, on)
    }

    /** Change the ACTIVE image's fill mode (recents[0]). */
    fun setFillMode(ctx: Context, mode: BackgroundFillMode) {
        val app = ctx.applicationContext
        recents = if (recents.isEmpty()) recents
        else recents.mapIndexed { i, r -> if (i == 0) r.copy(fillMode = mode) else r }
        persist(app)
    }

    /**
     * Read the picked image, downscale, save a new app-private JPEG, and push it to the FRONT of the
     * recent list (dropping + deleting the oldest beyond [MAX_RECENTS]). Returns true on success. Call off
     * the main thread for a large source (bitmap decode + file IO).
     */
    fun setImageFromUri(ctx: Context, uri: Uri): Boolean {
        val app = ctx.applicationContext
        val scaled = runCatching { decodeDownscaled(app, uri) }.getOrNull() ?: return false
        val id = "bg-${System.currentTimeMillis()}.jpg"
        val wrote = runCatching {
            file(app, id).outputStream().use { out -> scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out) }
        }.isSuccess
        scaled.recycle()
        if (!wrote) {
            // A failed compress can leave a partial file behind — it's never added to `recents`, so delete
            // it here or it leaks forever (unlike iOS's atomic write, which leaves nothing on failure).
            runCatching { file(app, id).delete() }
            return false
        }
        // A fresh pick inherits the current fill mode. Prepend, cap at MAX_RECENTS, delete any dropped file.
        val next = (listOf(Recent(id, fillMode)) + recents).take(MAX_RECENTS)
        recents.filter { it !in next }.forEach { runCatching { file(app, it.id).delete() } }
        recents = next
        refreshDecoded(app)
        // Actively picking an image means the user wants to SEE it — turn the background on so it shows
        // immediately. They can still toggle it off afterwards (the image is kept) or Remove it.
        if (!enabled) setEnabled(app, true)
        persist(app)
        return true
    }

    /** Re-apply a recent preset: move it to the front (so it becomes the ACTIVE image + its fill mode). */
    fun applyRecent(ctx: Context, index: Int) {
        val app = ctx.applicationContext
        if (index !in recents.indices || index == 0) return
        val chosen = recents[index]
        recents = listOf(chosen) + recents.filterIndexed { i, _ -> i != index }
        refreshDecoded(app)
        if (!enabled) setEnabled(app, true)
        persist(app)
    }

    /** Remove the ACTIVE image (recents[0]); the next recent becomes active, or the background clears. */
    fun clearImage(ctx: Context) {
        val app = ctx.applicationContext
        val removed = recents.firstOrNull() ?: return
        runCatching { file(app, removed.id).delete() }
        recents = recents.drop(1)
        refreshDecoded(app)
        persist(app)
    }

    /** Decode the active image full-size + every recent as a small thumbnail. */
    private fun refreshDecoded(app: Context) {
        bitmap = recents.firstOrNull()?.let { r ->
            runCatching { BitmapFactory.decodeFile(file(app, r.id).absolutePath)?.asImageBitmap() }.getOrNull()
        }
        thumbnails = recents.map { r ->
            runCatching { decodeScaledFile(file(app, r.id), THUMB_DIMEN)?.asImageBitmap() }.getOrNull()
        }
    }

    /** Persist the recent list + mirror the active fill mode / present flag onto the shared pref keys. */
    private fun persist(app: Context) {
        NoopPrefs.setBackgroundRecents(app, serializeRecents(recents))
        NoopPrefs.setBackgroundFillMode(app, fillMode)
        NoopPrefs.setBackgroundImagePresent(app, recents.isNotEmpty())
    }

    /** `"<file>,<mode>;<file>,<mode>"` — see [KEY_BACKGROUND_RECENTS]. Filenames never contain `,`/`;`. */
    internal fun serializeRecents(list: List<Recent>): String =
        list.joinToString(";") { "${it.id},${it.fillMode.storageValue}" }

    internal fun parseRecents(s: String): List<Recent> =
        s.split(";").mapNotNull { entry ->
            if (entry.isBlank()) return@mapNotNull null
            val parts = entry.split(",")
            if (parts.size != 2 || parts[0].isBlank()) return@mapNotNull null
            Recent(parts[0], BackgroundFillMode.fromStorage(parts[1]))
        }.take(MAX_RECENTS)

    /** Decode [f] downscaled so its longest edge is ~[maxDimen] (two-pass inSampleSize). Null on failure. */
    private fun decodeScaledFile(f: File, maxDimen: Int): Bitmap? {
        if (!f.exists()) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(f.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= maxDimen && bounds.outHeight / (sample * 2) >= maxDimen) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeFile(f.absolutePath, opts)
    }

    /**
     * Decode [uri] into a Bitmap whose longest edge is at most [MAX_DIMEN]: a bounds-only pass to pick an
     * `inSampleSize`, then the real sub-sampled decode, an exact down-fit, and an EXIF-orientation
     * correction so a sideways photo lands upright. Mirrors ProfileAvatarStore.decodeDownscaled.
     */
    private fun decodeDownscaled(ctx: Context, uri: Uri): Bitmap? {
        val resolver = ctx.contentResolver

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        val srcW = bounds.outWidth
        val srcH = bounds.outHeight
        if (srcW <= 0 || srcH <= 0) return null

        val orientation = runCatching {
            resolver.openInputStream(uri)?.use {
                ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }
        }.getOrNull() ?: ExifInterface.ORIENTATION_NORMAL

        var sample = 1
        while (srcW / (sample * 2) >= MAX_DIMEN && srcH / (sample * 2) >= MAX_DIMEN) {
            sample *= 2
        }
        val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, decodeOpts)
        } ?: return null

        val longest = maxOf(decoded.width, decoded.height)
        val factor = if (longest > MAX_DIMEN) MAX_DIMEN.toFloat() / longest.toFloat() else 1f
        val matrix = Matrix().apply {
            if (factor != 1f) postScale(factor, factor)
            for (op in ProfileAvatarStore.exifOps(orientation)) when (op) {
                is ProfileAvatarStore.ExifOp.Rotate -> postRotate(op.degrees)
                is ProfileAvatarStore.ExifOp.Scale -> postScale(op.sx, op.sy)
            }
        }
        if (matrix.isIdentity) return decoded
        val out = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        if (out !== decoded) decoded.recycle()
        return out
    }
}

/**
 * The custom-background backdrop: draws [BackgroundImageStore.bitmap] full-bleed under the whole screen,
 * scaled per [BackgroundImageStore.fillMode]. Drop it into a scaffold's `topBackground` slot with
 * `fullBleedBackground = true`. Non-interactive + accessibility-hidden (pure decoration). Tile mode is a
 * single GPU-tiled shader draw — never N image views. Mirrors the iOS BackgroundImageBackdrop.
 */
@Composable
fun BackgroundImageBackdrop(modifier: Modifier = Modifier) {
    val bmp = BackgroundImageStore.bitmap ?: return
    val base = modifier
        .fillMaxSize()
        .clearAndSetSemantics {} // decorative — invisible to TalkBack
    when (BackgroundImageStore.fillMode) {
        BackgroundFillMode.TILE -> {
            // One tiled shader fill: the source bitmap repeats across the viewport in a single GPU draw.
            val brush = ShaderBrush(ImageShader(bmp, TileMode.Repeated, TileMode.Repeated))
            Canvas(modifier = base) { drawRect(brush = brush) }
        }
        else -> Image(
            bitmap = bmp,
            contentDescription = null,
            modifier = base,
            contentScale = when (BackgroundImageStore.fillMode) {
                BackgroundFillMode.FIT -> ContentScale.Fit
                BackgroundFillMode.STRETCH -> ContentScale.FillBounds
                else -> ContentScale.Crop // FILL (and, defensively, TILE — handled above)
            },
        )
    }
}
