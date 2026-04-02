package dev.anicanon.swiftandroid.codegen.runtime

import java.util.concurrent.CompletableFuture
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Awaits a [CompletableFuture] as a suspend function.
 *
 * Cancellation of the coroutine will attempt to cancel the future.
 */
suspend fun <T : Any> CompletableFuture<T>.await(): T =
    suspendCancellableCoroutine { cont ->
        cont.invokeOnCancellation { cancel(false) }
        whenComplete { value, error ->
            if (error != null) cont.resumeWithException(error)
            else cont.resume(value)
        }
    }
