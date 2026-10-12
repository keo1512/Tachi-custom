package dev.tachibooks.engine;

import kotlin.coroutines.Continuation;
import kotlin.jvm.functions.Function2;
import kotlinx.coroutines.BuildersKt;
import kotlinx.coroutines.CoroutineScope;
import kotlinx.coroutines.Dispatchers;
import kotlinx.coroutines.TimeoutKt;

/** Calls the official suspend API, including its compatibility delegates for Rx extensions. */
final class SuspendBridge {
    private SuspendBridge() {}
    interface Operation<T> { Object run(Continuation<? super T> completion); }
    static <T> T await(final Operation<T> operation) throws InterruptedException {
        final Function2<CoroutineScope, Continuation<? super T>, Object> invoke =
            new Function2<CoroutineScope, Continuation<? super T>, Object>() {
                public Object invoke(CoroutineScope scope, Continuation<? super T> completion) {
                    return operation.run(completion);
                }
            };
        return BuildersKt.runBlocking(Dispatchers.getIO(),
            new Function2<CoroutineScope, Continuation<? super T>, Object>() {
                public Object invoke(CoroutineScope scope, Continuation<? super T> completion) {
                    return TimeoutKt.withTimeout(45000L, invoke, completion);
                }
            });
    }
}
