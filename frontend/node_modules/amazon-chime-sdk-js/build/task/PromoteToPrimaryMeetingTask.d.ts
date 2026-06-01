import { MeetingSessionCredentials, MeetingSessionStatus } from '..';
import AudioVideoControllerState from '../audiovideocontroller/AudioVideoControllerState';
import BaseTask from './BaseTask';
/**
 * [[PromoteToPrimaryMeetingTask]] sends a `SdkSignalFrame.PrimaryMeetingJoin` and waits for
 * a `SdkSignalFrame.PrimaryMeetingJoinAck`  frame.
 */
export default class PromoteToPrimaryMeetingTask extends BaseTask {
    private context;
    private credentials;
    private completionCallback;
    protected taskName: string;
    private taskCanceler;
    constructor(context: AudioVideoControllerState, credentials: MeetingSessionCredentials, completionCallback: (status: MeetingSessionStatus) => void);
    cancel(): void;
    run(): Promise<void>;
    private receivePrimaryMeetingJoinAck;
}
