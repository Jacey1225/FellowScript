/**
 * A simple promise queue to enforce the order of async APIs for example, start/stop video/audio input.
 */
export default class PromiseQueue {
    queue: Promise<void>;
    add<T>(func: () => Promise<T>): Promise<T>;
}
