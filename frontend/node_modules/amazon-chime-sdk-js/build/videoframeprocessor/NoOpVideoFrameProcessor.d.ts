import VideoFrameBuffer from './VideoFrameBuffer';
import VideoFrameProcessor from './VideoFrameProcessor';
/**
 * [[NoOpVideoFrameProcessor]] implements [[VideoFrameProcessor]].
 * It's a no-op processor and input is passed to output directly.
 */
export default class NoOpVideoFrameProcessor implements VideoFrameProcessor {
    process(buffers: VideoFrameBuffer[]): Promise<VideoFrameBuffer[]>;
    destroy(): Promise<void>;
}
