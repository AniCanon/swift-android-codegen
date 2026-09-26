package dev.anicanon.swiftandroid.codegen.runtime

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext

/** Emits until [next] returns null; [cancel] always runs once, also when the collector is cancelled. */
fun <T : Any> observationFlow(next: suspend () -> T?, cancel: suspend () -> Unit): Flow<T> = flow {
    try {
        while (true) {
            emit(next() ?: break)
        }
    } finally {
        withContext(NonCancellable) { cancel() }
    }
}
