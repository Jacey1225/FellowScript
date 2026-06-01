import Logger from '../logger/Logger';
import RealtimeController from '../realtimecontroller/RealtimeController';
import { SdkAudioMetadataFrame, SdkAudioStreamIdInfoFrame } from '../signalingprotocol/SignalingProtocol.js';
import VolumeIndicatorAdapter from './VolumeIndicatorAdapter';
export default class DefaultVolumeIndicatorAdapter implements VolumeIndicatorAdapter {
    private logger;
    private realtimeController;
    private minVolumeDecibels;
    private maxVolumeDecibels;
    private selfAttendeeId?;
    private streamIdToAttendeeId;
    private streamIdToExternalUserId;
    private warnedAboutMissingStreamIdMapping;
    private attendeeIdToStreamId;
    private sessionReconnected;
    static MAX_SIGNAL_STRENGTH_LEVELS: number;
    static IMPLICIT_VOLUME: number;
    static IMPLICIT_SIGNAL_STRENGTH: number;
    constructor(logger: Logger, realtimeController: RealtimeController, minVolumeDecibels: number, maxVolumeDecibels: number, selfAttendeeId?: string);
    onReconnect(): void;
    sendRealtimeUpdatesForAudioStreamIdInfo(info: SdkAudioStreamIdInfoFrame): void;
    private cleanUpState;
    sendRealtimeUpdatesForAudioMetadata(metadata: SdkAudioMetadataFrame): void;
    private normalizedVolume;
    private normalizedSignalStrength;
    private applyRealtimeUpdatesForAudioMetadata;
    private attendeeIdForStreamId;
}
