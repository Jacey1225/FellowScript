import Destroyable from '../destroyable/Destroyable';
import DevicePixelRatioObserver from '../devicepixelratioobserver/DevicePixelRatioObserver';
import DevicePixelRatioSource from '../devicepixelratiosource/DevicePixelRatioSource';
import Logger from '../logger/Logger';
import DevicePixelRatioMonitor from './DevicePixelRatioMonitor';
export default class DefaultDevicePixelRatioMonitor implements DevicePixelRatioMonitor, Destroyable {
    private devicePixelRatioSource;
    private observerQueue;
    private mediaQueryList;
    constructor(devicePixelRatioSource: DevicePixelRatioSource, logger: Logger);
    destroy(): Promise<void>;
    mediaQueryListener: () => void;
    registerObserver(observer: DevicePixelRatioObserver): void;
    removeObserver(observer: DevicePixelRatioObserver): void;
}
