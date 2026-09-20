package dev.anicanon.swiftandroid.codegen.runtime

import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionException
import java.util.concurrent.ExecutionException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Awaits a [CompletableFuture] as a suspend function.
 *
 * Cancellation of the coroutine will attempt to cancel the future. A failure is rethrown as the
 * error the Swift call threw, not the [CompletionException] wrapping it.
 */
suspend fun <T : Any> CompletableFuture<T>.await(): T =
    suspendCancellableCoroutine { cont ->
        cont.invokeOnCancellation { cancel(false) }
        whenComplete { value, error ->
            if (error != null) cont.resumeWithException(error.unwrapped())
            else cont.resume(value)
        }
    }

private fun Throwable.unwrapped(): Throwable {
    var error = this
    while (error is CompletionException || error is ExecutionException) {
        error = error.cause ?: break
    }
    return error
}
