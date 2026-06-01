import AudioNodeSubgraph from './AudioNodeSubgraph';
import Device from './Device';
/**
 * This class simplifies the process of defining a transform device that
 * does not modify its input device constraints, and provides only a single audio node
 * to apply transforms.
 *
 * Subclass `SingleNodeAudioTransformDevice`, implementing `createSingleAudioNode`.
 */
export default abstract class SingleNodeAudioTransformDevice<T extends AudioNode> {
    protected inner: Device;
    protected node: T | undefined;
    constructor(inner: Device);
    mute(_muted: boolean): Promise<void>;
    /**
     * `stop` should be called by the application to free any resources associated
     * with the device (e.g., workers).
     *
     * After this is called, the device should be discarded.
     */
    stop(): Promise<void>;
    /**
     * Return the inner {@link Device} that the device controller should select as part
     * of the application of this `AudioTransformDevice`.
     */
    intrinsicDevice(): Promise<Device>;
    /**
     * Optionally return a pair of `AudioNode`s that should be connected to the applied inner
     * device. The two nodes can be the same, indicating the smallest possible subgraph.
     *
     * @param context The `AudioContext` to use when instantiating the nodes.
     */
    createAudioNode(context: AudioContext): Promise<AudioNodeSubgraph | undefined>;
    abstract createSingleAudioNode(context: AudioContext): Promise<T>;
}
