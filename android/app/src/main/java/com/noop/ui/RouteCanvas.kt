package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import com.noop.analytics.RouteMath

/** Draws a GPS route as a polyline on a blank canvas — no map tiles, fully offline. */
@Composable
fun RouteCanvas(polyline: String, modifier: Modifier = Modifier) {
    val points = RouteMath.decode(polyline)
    Canvas(modifier = modifier.fillMaxWidth().height(180.dp)) {
        val screen = RouteMath.normalizeToBox(points, size.width, size.height)
        if (screen.size < 2) return@Canvas
        val path = Path().apply {
            moveTo(screen.first().first, screen.first().second)
            screen.drop(1).forEach { (x, y) -> lineTo(x, y) }
        }
        drawPath(path, color = Palette.accent, style = Stroke(width = 6f))
        drawCircle(Palette.accent, radius = 9f, center = Offset(screen.first().first, screen.first().second))
        drawCircle(Palette.statusCritical, radius = 9f, center = Offset(screen.last().first, screen.last().second))
    }
}
