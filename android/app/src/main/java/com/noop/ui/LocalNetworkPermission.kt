package com.noop.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat

// Android 17 (API 37) gates local sockets behind ACCESS_LOCAL_NETWORK for apps targeting 37+.
// Older releases have no such permission, so the gate is a no-op there.
private const val LOCAL_NETWORK_API = 37

/**
 * Gates an opt-in local-network action on the API 37 permission. Callers stay silent on older
 * releases and when access is already granted; otherwise one system prompt is shown and the
 * chosen action runs only on grant. Denial is reported through [onDenied] so the screen can say
 * why nothing happened instead of looking broken.
 */
@Composable
fun rememberLocalNetworkPermissionRequester(): (() -> Unit, () -> Unit) -> Unit {
    val context = LocalContext.current
    val pending = remember { mutableStateOf<Pair<() -> Unit, () -> Unit>?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val actions = pending.value
        pending.value = null
        if (granted) actions?.first?.invoke() else actions?.second?.invoke()
    }
    return { onGranted, onDenied ->
        if (Build.VERSION.SDK_INT < LOCAL_NETWORK_API ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_LOCAL_NETWORK,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            onGranted()
        } else {
            pending.value = onGranted to onDenied
            launcher.launch(Manifest.permission.ACCESS_LOCAL_NETWORK)
        }
    }
}
