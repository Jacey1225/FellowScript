import TimeoutScheduler from './TimeoutScheduler';
/**
 * [[AsyncScheduler]] enqueues the callback for the soonest available run of the
 * event loop.
 */
export default class AsyncScheduler extends TimeoutScheduler {
    constructor();
    /**
     * Execute the provided callback on the next tick of the event loop.
     * This is semantically equivalent to
     *
     * ```typescript
     * new AsyncScheduler(callback).start();
     * ```
     *
     * but with less overhead.
     *
     * @param callback the code to run.
     */
    static nextTick(callback: () => void): void;
}
