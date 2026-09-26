package dev.anicanon.swiftandroid.codegen.runtime

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ObservationFlowTest {
    private class Source(private val items: List<Int>, private val failure: Throwable? = null) {
        private var index = 0
        var cancels = 0

        suspend fun next(): Int? {
            if (index < items.size) return items[index++]
            failure?.let { throw it }
            return null
        }

        suspend fun cancel() {
            cancels++
        }
    }

    @Test
    fun emitsUntilNullAndCancelsOnce() = runTest {
        val source = Source(listOf(1, 2))
        assertEquals(listOf(1, 2), observationFlow(source::next, source::cancel).toList())
        assertEquals(1, source.cancels)
    }

    @Test
    fun earlyTerminationCancelsOnce() = runTest {
        val source = Source(listOf(1, 2, 3))
        assertEquals(1, observationFlow(source::next, source::cancel).first())
        assertEquals(1, source.cancels)
    }

    @Test
    fun failureRethrowsAndCancelsOnce() = runTest {
        val source = Source(listOf(1), IllegalStateException("boom"))
        val error = assertFailsWith<IllegalStateException> {
            observationFlow(source::next, source::cancel).toList()
        }
        assertEquals("boom", error.message)
        assertEquals(1, source.cancels)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun collectorCancellationCancelsOnce() = runTest {
        var cancels = 0
        val flow = observationFlow<Int>(next = { awaitCancellation() }, cancel = { cancels++ })
        val job = launch { flow.collect {} }
        runCurrent()
        job.cancelAndJoin()
        assertEquals(1, cancels)
    }
}
