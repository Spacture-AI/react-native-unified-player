package com.unifiedplayer.core.player

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import com.facebook.react.bridge.ReactContext
import com.facebook.react.modules.network.CookieJarContainer
import com.facebook.react.modules.network.ForwardingCookieHandler
import com.facebook.react.modules.network.OkHttpClientProvider
import com.margelo.nitro.unifiedplayer.HybridVideoPlayerSourceSpec
import okhttp3.Dispatcher
import okhttp3.JavaNetCookieJar
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

fun buildBaseDataSourceFactory(context: Context, source: HybridVideoPlayerSourceSpec): DefaultDataSource.Factory {
  return if (source.uri.startsWith("http")) {
    DefaultDataSource.Factory(context, buildHttpDataSourceFactory(context, source))
  } else {
    DefaultDataSource.Factory(context)
  }
}

/**
 * Dedicated OkHttp client used by the HLS / DASH / progressive data
 * source. Built once on first access and shared across player instances.
 *
 * Why a dedicated client (instead of reusing
 * `OkHttpClientProvider.getOkHttpClient()` directly):
 *   • RN's shared client uses OkHttp's default `Dispatcher`
 *     (`maxRequestsPerHost = 5`). HLS playback wants to parallel-fetch
 *     several segments after a seek — with the shared client those
 *     requests queue behind whatever API traffic the rest of the app is
 *     making, producing visible buffer stalls.
 *   • Disabling the response cache prevents double-buffering: ExoPlayer
 *     already maintains its own segment buffer; an OkHttp cache on top
 *     just adds memory pressure.
 *   • Mirrors the iOS-side fix in `AuthHeaderAssetResourceLoader.swift`
 *     (`httpMaximumConnectionsPerHost = 10`, `urlCache = nil`,
 *     `requestCachePolicy = reloadIgnoringLocalCacheData`) so behaviour
 *     stays consistent across platforms.
 */
private val playbackHttpClient: OkHttpClient by lazy {
  val sharedClient = OkHttpClientProvider.getOkHttpClient()

  val playbackDispatcher = Dispatcher().apply {
    maxRequests = 64
    maxRequestsPerHost = 10
  }

  sharedClient.newBuilder()
    .dispatcher(playbackDispatcher)
    .cache(null)
    .connectTimeout(30, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .writeTimeout(30, TimeUnit.SECONDS)
    .build()
}

@OptIn(UnstableApi::class)
fun buildHttpDataSourceFactory(context: Context, source: HybridVideoPlayerSourceSpec): OkHttpDataSource.Factory {
  // Forward RN's cookie handler onto the SHARED client's CookieJar so
  // any cookie-based session auth (e.g. set during regular API calls)
  // is visible to playback requests. The dedicated `playbackHttpClient`
  // inherits the same CookieJar via `newBuilder()`.
  if (context is ReactContext) {
    val sharedClient = OkHttpClientProvider.getOkHttpClient()
    val handler = ForwardingCookieHandler(context)
    (sharedClient.cookieJar as CookieJarContainer).setCookieJar(JavaNetCookieJar(handler))
  }

  val factory = OkHttpDataSource.Factory(playbackHttpClient)

  val headers: Map<String, String>? = source.config.headers

  if (headers != null) {
    factory.setDefaultRequestProperties(headers)
  }

  if (headers == null || !headers.containsKey("User-Agent")) {
    factory.setUserAgent(getUserAgent(context))
  }

  return factory
}

@OptIn(UnstableApi::class)
fun getUserAgent(context: Context): String {
  return Util.getUserAgent(context, context.packageName)
}
