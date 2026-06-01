import Scheduler from './Scheduler';
/**
 * [[IntervalScheduler]] calls the callback every intervalMs milliseconds.
 */
export default class IntervalScheduler implements Scheduler {
    private intervalMs;
    timer: undefined | ReturnType<typeof setInterval>;
    constructor(intervalMs: number);
    start(callback: () => void): void;
    stop(): void;
    running(): boolean;
}
