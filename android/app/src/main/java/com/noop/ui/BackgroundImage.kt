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
    private const val FILE_NAME = "background.jpg"

    /** Longest edge (px) the stored image is downscaled to. Big enough to cover a large tablet/foldable
     *  screen crisply, capped so a 100MP pick can never fully decode into memory (it sub-samples first). */
    private const val MAX_DIMEN = 2560

    /** JPEG quality for the re-encoded background — a touch higher than the avatar since it fills the
     *  whole screen behind (semi-transparent) cards, still modest on disk. */
    private const val JPEG_QUALITY = 90

    private fun backgroundFile(ctx: Context): File =
        File(ctx.applicationContext.filesDir, FILE_NAME)

    /** The decoded background for composition; null = none stored. */
    var bitmap by mutableStateOf<ImageBitmap?>(null)
        private set

    /** Master enable toggle (mirrors NoopPrefs.backgroundImageEnabled), snapshot-backed for live redraw. */
    var enabled by mutableStateOf(false)
        private set

    /** How the image is scaled (mirrors NoopPrefs.backgroundFillMode), snapshot-backed for live redraw. */
    var fillMode by mutableStateOf(BackgroundFillMode.FILL)
        private set

    /** True when a photo is stored — drives the Remove affordance in Settings. */
    val hasImage: Boolean get() = bitmap != null

    /** The custom image is the ACTIVE backdrop (top of the precedence: enabled AND actually decoded). */
    val isActive: Boolean get() = enabled && bitmap != null

    /** Load the persisted toggles + image (if any). Safe to call before first composition. */
    fun load(ctx: Context) {
        val app = ctx.applicationContext
        enabled = NoopPrefs.backgroundImageEnabled(app)
        fillMode = NoopPrefs.backgroundFillMode(app)
        val file = backgroundFile(app)
        bitmap = if (NoopPrefs.backgroundImagePresent(app) && file.exists()) {
            runCatching { BitmapFactory.decodeFile(file.absolutePath)?.asImageBitmap() }.getOrNull()
        } else {
            null
        }
    }

    fun setEnabled(ctx: Context, on: Boolean) {
        enabled = on
        NoopPrefs.setBackgroundImageEnabled(ctx.applicationContext, on)
    }

    fun setFillMode(ctx: Context, mode: BackgroundFillMode) {
        fillMode = mode
        NoopPrefs.setBackgroundFillMode(ctx.applicationContext, mode)
    }

    /**
     * Read the picked image, downscale to [MAX_DIMEN] on the longest edge, re-encode as a JPEG into
     * `filesDir/background.jpg`, flip the present flag, and update the live [bitmap]. Returns true on
     * success. Call off the main thread for a large source (bitmap decode + file IO).
     */
    fun setImageFromUri(ctx: Context, uri: Uri): Boolean {
        val app = ctx.applicationContext
        val scaled = runCatching { decodeDownscaled(app, uri) }.getOrNull() ?: return false
        val file = backgroundFile(app)
        val wrote = runCatching {
            file.outputStream().use { out -> scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out) }
        }.isSuccess
        if (!wrote) {
            scaled.recycle()
            return false
        }
        NoopPrefs.setBackgroundImagePresent(app, true)
        bitmap = scaled.asImageBitmap()
        return true
    }

    /** Remove the photo: delete the file, clear the present flag, drop the live [bitmap] to null. */
    fun clearImage(ctx: Context) {
        val app = ctx.applicationContext
        runCatching { backgroundFile(app).delete() }
        NoopPrefs.setBackgroundImagePresent(app, false)
        bitmap = null
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
