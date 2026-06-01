import AudioProfile from '../audioprofile/AudioProfile';
import MeetingSessionConfiguration from '../meetingsession/MeetingSessionConfiguration';
import MeetingSessionCredentials from '../meetingsession/MeetingSessionCredentials';
import MeetingSessionStatus from '../meetingsession/MeetingSessionStatus';
import DefaultAudioVideoController from './DefaultAudioVideoController';
export default class NoOpAudioVideoController extends DefaultAudioVideoController {
    constructor(configuration?: MeetingSessionConfiguration);
    setAudioProfile(_audioProfile: AudioProfile): void;
    start(): void;
    stop(): void;
    promoteToPrimaryMeeting(_: MeetingSessionCredentials): Promise<MeetingSessionStatus>;
    demoteFromPrimaryMeeting(): void;
}
