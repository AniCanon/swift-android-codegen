package dev.anicanon.swiftandroid.codegen.runtime

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext

/** Opens the observation when collection starts; [cancel] runs exactly once, also when the collector is cancelled. */
fun <O : Any, T : Any> observationFlow(
    open: () -> O,
    next: suspend (O) -> T?,
    cancel: suspend (O) -> Unit,
): Flow<T> = flow {
    val observation = open()
    try {
        while (true) {
            emit(next(observation) ?: break)
        }
    } finally {
        withContext(NonCancellable) { cancel(observation) }
    }
}
