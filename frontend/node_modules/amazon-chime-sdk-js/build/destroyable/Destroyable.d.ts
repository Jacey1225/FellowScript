/**
 * An interface for objects that require manual cleanup.
 */
export interface Destroyable {
    /**
     * Dispose of this instance. The instance cannot be used after this method has been called.
     */
    destroy(): Promise<void>;
}
/**
 * Type guard for `Destroyable`.
 *
 * @param x A value that might implement the `Destroyable` interface.
 * @returns Whether the value implements `Destroyable`.
 */
export declare function isDestroyable(x: any): x is Destroyable;
export default Destroyable;
