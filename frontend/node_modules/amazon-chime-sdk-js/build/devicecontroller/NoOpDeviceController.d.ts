import DeviceChangeObserver from '../devicechangeobserver/DeviceChangeObserver';
import EventController from '../eventcontroller/EventController';
import DeviceControllerBasedMediaStreamBroker from '../mediastreambroker/DeviceControllerBasedMediaStreamBroker';
import NoOpMediaStreamBroker from '../mediastreambroker/NoOpMediaStreamBroker';
import AudioInputDevice from './AudioInputDevice';
import RemovableAnalyserNode from './RemovableAnalyserNode';
import VideoInputDevice from './VideoInputDevice';
import VideoQualitySettings from './VideoQualitySettings';
export default class NoOpDeviceController extends NoOpMediaStreamBroker implements DeviceControllerBasedMediaStreamBroker {
    destroyed: boolean;
    constructor(_options?: {
        enableWebAudio?: boolean;
    });
    destroy(): Promise<void>;
    listAudioInputDevices(): Promise<MediaDeviceInfo[]>;
    listVideoInputDevices(): Promise<MediaDeviceInfo[]>;
    listAudioOutputDevices(): Promise<MediaDeviceInfo[]>;
    startAudioInput(_device: AudioInputDevice): Promise<MediaStream | undefined>;
    stopAudioInput(): Promise<void>;
    startVideoInput(_device: VideoInputDevice): Promise<MediaStream | undefined>;
    stopVideoInput(): Promise<void>;
    chooseAudioOutput(_deviceId: string | null): Promise<void>;
    addDeviceChangeObserver(_observer: DeviceChangeObserver): void;
    removeDeviceChangeObserver(_observer: DeviceChangeObserver): void;
    createAnalyserNodeForAudioInput(): RemovableAnalyserNode | null;
    startVideoPreviewForVideoInput(_element: HTMLVideoElement): void;
    stopVideoPreviewForVideoInput(_element: HTMLVideoElement): void;
    setDeviceLabelTrigger(_trigger: () => Promise<MediaStream>): void;
    mixIntoAudioInput(_stream: MediaStream): MediaStreamAudioSourceNode;
    chooseVideoInputQuality(_width: number, _height: number, _frameRate: number): void;
    getVideoInputQualitySettings(): VideoQualitySettings | null;
}
export declare class NoOpDeviceControllerWithEventController extends NoOpDeviceController {
    eventController: EventController | undefined;
    constructor(eventController?: EventController);
}
