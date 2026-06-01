import VideoFrameBuffer from './VideoFrameBuffer';
/**
 * [[CanvasVideoFrameBuffer]] implements [[VideoFrameBuffer]]. It internally holds an `HTMLCanvasElement`.
 */
export default class CanvasVideoFrameBuffer implements VideoFrameBuffer {
    private canvas;
    private destroyed;
    framerate: number;
    width: number;
    height: number;
    constructor(canvas: HTMLCanvasElement);
    destroy(): void;
    asCanvasImageSource(): Promise<CanvasImageSource>;
    asCanvasElement(): HTMLCanvasElement | null;
}
