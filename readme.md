# Testing SIGINT with gRPC Streaming

This demonstrates the issue where SIGINT cannot interrupt a gRPC streaming call that's waiting for data.

## The Problem

When a gRPC client is blocked waiting for the next message in a stream (via `.each` or `enum.next`), sending SIGINT will **not** interrupt it. The gRPC Ruby library explicitly catches and ignores interruptions in its completion queue, retrying the wait.

This is exactly what happens in the Spanner `execute_partition_update` hang:
1. Client iterates through streaming results (`results.rows.to_a`)
2. Server stops sending data mid-stream
3. Client blocks in `@enum.next` waiting for next partition result
4. SIGINT is sent but ignored

## Setup

### Using the Debug-Instrumented gRPC Gem

To see the detailed logging that proves the retry behavior, you need the debug-instrumented version of gRPC:

1. **Clone the debug branch**:
   ```bash
   git clone -b debug https://github.com/samuel-williams-shopify/grpc.git
   cd grpc
   git submodule update --init
   ```

2. **Build and install the gem**:
   ```bash
   bundle install
   gem build grpc.gemspec
   gem install grpc-1.77.0.dev.gem
   ```

The debug branch includes instrumentation in `src/ruby/ext/grpc/rb_completion_queue.c` that logs:
- When `unblock_func` is called (SIGINT received).
- Each iteration of the retry loop.
- When the loop decides to retry despite interruption.

## Running the Test

**Terminal 1 - Start the server:**
```bash
ruby server_slow_stream.rb
```

This server will:
- Send the first message immediately
- Then hang forever (simulating a stuck Spanner partition)

**Terminal 2 - Run the test client:**
```bash
ruby test_sigint.rb
```

## Expected Output

With the debug-instrumented gRPC gem, you'll see detailed logging that proves the retry behavior:

```
Starting gRPC streaming test...
[2025-10-01 21:53:23 +1300] Starting to iterate stream on #<Thread:0x000000011debafa0 run>...
[GRPC DEBUG] Loop iteration 1: Resetting interrupted to 0
[GRPC DEBUG] Loop iteration 1: Calling rb_thread_call_without_gvl (blocking...)
[GRPC DEBUG] Loop iteration 1: Returned from rb_thread_call_without_gvl, interrupted=0, event.type=2
[2025-10-01 21:53:23 +1300] Received: Message 1 for Test
[GRPC DEBUG] Loop iteration 1: Calling rb_thread_call_without_gvl (blocking...)

[2025-10-01 21:53:25 +1300] Sending SIGINT to main thread...
[2025-10-01 21:53:25 +1300] SIGINT sent!
[GRPC DEBUG] unblock_func called! Setting interrupted=1 (SIGINT received) ← ✓ Signal received
[2025-10-01 21:53:25 +1300] SIGINT handler called on #<Thread:0x000000011debafa0 run>! ← ✓ Ruby processes it

🔥 THE SMOKING GUN:
[GRPC DEBUG] Loop iteration 1: Returned from rb_thread_call_without_gvl, interrupted=1, event.type=1
[GRPC DEBUG] Loop iteration 1: interrupted=1, RETRYING LOOP (ignoring interruption!) ← ✗ gRPC ignores it!
[GRPC DEBUG] Loop iteration 2: Resetting interrupted to 0
[GRPC DEBUG] Loop iteration 2: Calling rb_thread_call_without_gvl (blocking...)

... 28 seconds pass until timeout ...

[2025-10-01 21:53:53 +1300] ❌ DeadlineExceeded: Stream timed out
[2025-10-01 21:53:53 +1300] SIGINT was received: true
[2025-10-01 21:53:53 +1300] But the stream continued until timeout!
```

## Key Observations

1. **SIGINT is delivered** - `unblock_func called! Setting interrupted=1`.
2. **Ruby signal handler executes** - The `Signal.trap` block runs successfully.
3. **gRPC sees the interruption** - `interrupted=1` is set.
4. **🔥 gRPC deliberately retries** - `interrupted=1, RETRYING LOOP (ignoring interruption!)`.
5. **Loop continues** - `Loop iteration 2: Resetting interrupted to 0`.
6. **Timeout is the only escape** - 30-second deadline finally ends it.

This proves that both Ruby and gRPC are working as designed - Ruby delivers the signal, but gRPC's completion queue explicitly ignores interruptions and retries.

## The Root Cause

From [`src/ruby/ext/grpc/rb_completion_queue.c`](https://github.com/samuel-williams-shopify/grpc/blob/debug/src/ruby/ext/grpc/rb_completion_queue.c):

```c
static void unblock_func(void* param) {
  next_call_stack* const next_call = (next_call_stack*)param;
  next_call->interrupted = 1;  // ← SIGINT sets this flag
  fprintf(stderr, "[GRPC DEBUG] unblock_func called! Setting interrupted=1\n");
}

grpc_event rb_completion_queue_pluck(grpc_completion_queue* queue, void* tag,
                                     gpr_timespec deadline,
                                     const char* reason) {
  // ...
  do {
    next_call.interrupted = 0;  // ← Reset flag
    fprintf(stderr, "[GRPC DEBUG] Loop iteration %d: Calling rb_thread_call_without_gvl\n", loop_count);
    
    rb_thread_call_without_gvl(grpc_rb_completion_queue_pluck_no_gil,
                               (void*)&next_call, unblock_func,
                               (void*)&next_call);
    
    fprintf(stderr, "[GRPC DEBUG] Returned, interrupted=%d\n", next_call.interrupted);
    
    if (next_call.event.type != GRPC_QUEUE_TIMEOUT) break;
    
    if (next_call.interrupted) {
      fprintf(stderr, "[GRPC DEBUG] interrupted=1, RETRYING LOOP!\n");  // ← The problem!
    }
  } while (next_call.interrupted);  // ← If interrupted, LOOP AGAIN!
  
  return next_call.event;
}
```

The loop explicitly retries after interruption, making SIGINT/SIGTERM ineffective.

### Why This Exists

This retry loop was **introduced** in [grpc/grpc#39409](https://github.com/grpc/grpc/pull/39409) ([commit 69f229e](https://github.com/grpc/grpc/commit/69f229edd1d79ab7a7dfda98e3aef6fd807adcad), merged June 3, 2025) to fix [grpc/grpc#38210](https://github.com/grpc/grpc/issues/38210) - "Kernel.system calls cause server to stop working".

**The Problem it Solved**: Before this fix, spurious signals (like those from `Kernel.system` calls) could inadvertently cancel gRPC operations because the previous implementation used `cancel_call_unblock_func` which would actively cancel the call on any interruption.

**The Trade-off**: The retry loop prevents spurious signals from breaking operations (✓), but it also means legitimate interrupt signals (like SIGINT/SIGTERM) are now ignored (✗), making it impossible to cancel hung operations.

This is working **as designed** - the behavior we're demonstrating is the intentional fix for #38210.

## Solution

For the Spanner issue, the fix is:
1. **Don't use Partitioned DML** for single-row updates.
2. Use `execute_update` in a transaction instead.
3. This avoids the multi-partition streaming problem entirely.

## References

- **Debug-instrumented gRPC**: https://github.com/samuel-williams-shopify/grpc/tree/debug
- **Original issue**: [grpc/grpc#38210](https://github.com/grpc/grpc/issues/38210) - "Kernel.system calls cause server to stop working"
- **PR that introduced the retry loop**: [grpc/grpc#39409](https://github.com/grpc/grpc/pull/39409) - Added retry loop to fix spurious signals (merged June 3, 2025)
- **The commit**: [69f229e](https://github.com/grpc/grpc/commit/69f229edd1d79ab7a7dfda98e3aef6fd807adcad) - Shows the actual code changes
- **gRPC completion queue code**: [`src/ruby/ext/grpc/rb_completion_queue.c`](https://github.com/samuel-williams-shopify/grpc/blob/debug/src/ruby/ext/grpc/rb_completion_queue.c)

## Timeline

This test was created to diagnose why a Google Cloud Spanner `execute_partition_update` call hung and couldn't be interrupted with SIGINT. The investigation revealed:

1. **The hang**: Partitioned DML was used for a single-row update (primary key lookup)
2. **The symptom**: SIGINT didn't interrupt the hanging operation
3. **The root cause**: gRPC's completion queue deliberately ignores interruptions (by design since June 2025)
4. **The proof**: This test with debug logging shows the retry behavior
5. **The fix**: Switch from Partitioned DML to regular transactional DML for single-row operations

### Current Status (as of June 2025)

The retry loop behavior demonstrated in this test is the **current behavior** of gRPC Ruby, introduced in [commit 69f229e](https://github.com/grpc/grpc/commit/69f229edd1d79ab7a7dfda98e3aef6fd807adcad) (June 3, 2025) as an intentional fix for [#38210](https://github.com/grpc/grpc/issues/38210).

**Before June 2025**: SIGINT would cancel calls, but spurious signals could break operations  
**After June 2025** (current): SIGINT is ignored, preventing spurious signal issues but making hung operations uninterruptible

This is a **design trade-off**: robustness against spurious signals vs. ability to interrupt hung operations. If you're experiencing hangs:
- Ensure proper deadlines/timeouts are set on all gRPC operations
- Avoid situations that cause hangs (like using Partitioned DML for single-row operations)
- Be aware that SIGINT/SIGTERM won't help you escape hung gRPC calls

### Potential Fix

A better solution would be to use `rb_thread_check_ints()` to distinguish between spurious and legitimate interruptions:

```c
if (next_call.interrupted) {
  // Check if there's actually a signal pending (SIGINT/SIGTERM)
  // If rb_thread_check_ints() raises an exception, it means there's a real signal
  // If it returns normally, the interruption was spurious and we should retry
  rb_thread_check_ints();
  // If we get here, interruption was spurious - retry
}
```

This would:
- ✓ Still handle spurious interruptions correctly (check finds nothing, retry)
- ✓ Allow legitimate signals to actually interrupt (check raises exception, operation terminates)
- ✓ Provide the best of both worlds

This fix has been applied to the debug branch for testing.

