import Logger from '../logger/Logger';
import MediaStreamBroker from '../mediastreambroker/MediaStreamBroker';
import MediaStreamBrokerObserver from '../mediastreambrokerobserver/MediaStreamBrokerObserver';
export default class ContentShareMediaStreamBroker implements MediaStreamBroker {
    private logger;
    private static defaultFrameRate;
    private _mediaStream;
    constructor(logger: Logger);
    get mediaStream(): MediaStream;
    set mediaStream(mediaStream: MediaStream);
    acquireAudioInputStream(): Promise<MediaStream>;
    acquireVideoInputStream(): Promise<MediaStream>;
    acquireDisplayInputStream(streamConstraints: MediaStreamConstraints): Promise<MediaStream>;
    acquireScreenCaptureDisplayInputStream(sourceId?: string, frameRate?: number): Promise<MediaStream>;
    private screenCaptureDisplayMediaConstraints;
    toggleMediaStream(enable: boolean): boolean;
    cleanup(): void;
    muteLocalAudioInputStream(): void;
    unmuteLocalAudioInputStream(): void;
    addMediaStreamBrokerObserver(_observer: MediaStreamBrokerObserver): void;
    removeMediaStreamBrokerObserver(_observer: MediaStreamBrokerObserver): void;
}
