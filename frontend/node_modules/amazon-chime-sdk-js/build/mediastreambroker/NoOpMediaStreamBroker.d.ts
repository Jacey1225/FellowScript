import MediaStreamBrokerObserver from '../mediastreambrokerobserver/MediaStreamBrokerObserver';
import MediaStreamBroker from './MediaStreamBroker';
/**
 * [[NoOpDeviceBroker]] rejects requests to acquire a [[MediaStream]].
 */
export default class NoOpMediaStreamBroker implements MediaStreamBroker {
    acquireAudioInputStream(): Promise<MediaStream>;
    acquireVideoInputStream(): Promise<MediaStream>;
    acquireDisplayInputStream(_streamConstraints: MediaStreamConstraints): Promise<MediaStream>;
    muteLocalAudioInputStream(): void;
    unmuteLocalAudioInputStream(): void;
    addMediaStreamBrokerObserver(_observer: MediaStreamBrokerObserver): void;
    removeMediaStreamBrokerObserver(_observer: MediaStreamBrokerObserver): void;
}
