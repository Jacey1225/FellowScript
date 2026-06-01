import Backoff from './Backoff';
export default interface BackoffFactory {
    /**
     * Backoff factory method
     */
    create(): Backoff;
    /**
     * Limited factory method
     */
    createWithLimit(limit: number): Backoff;
}
