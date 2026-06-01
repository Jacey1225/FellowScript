import AudioMixObserver from '../audiomixobserver/AudioMixObserver';
import Logger from '../logger/Logger';
import MediaStreamBrokerObserver from '../mediastreambrokerobserver/MediaStreamBrokerObserver';
import AudioMixController from './AudioMixController';
export default class DefaultAudioMixController implements AudioMixController, MediaStreamBrokerObserver {
    private logger?;
    private audioDevice;
    private audioElement;
    private audioStream;
    private browserBehavior;
    private observers;
    constructor(logger?: Logger);
    bindAudioElement(element: HTMLAudioElement): Promise<void>;
    unbindAudioElement(): void;
    bindAudioStream(stream: MediaStream): Promise<void>;
    bindAudioDevice(device: MediaDeviceInfo | null): Promise<void>;
    private forEachObserver;
    private bindAudioMix;
    getCurrentMeetingAudioStream(): Promise<MediaStream | null>;
    addAudioMixObserver(observer: AudioMixObserver): Promise<void>;
    removeAudioMixObserver(observer: AudioMixObserver): Promise<void>;
    audioOutputDidChange(device: MediaDeviceInfo | null): Promise<void>;
}
