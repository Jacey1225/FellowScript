/**
 *
 * [[ApplicationMetadata]] contains application metadata such as application name and version.
 * Amazon Chime SDK for JavaScript allows builders to provide application metadata in
 * the meeting session configuration. This field is optional. Amazon Chime uses application metadata to
 * analyze meeting health trends or identify common failures to improve your meeting experience.
 *
 * Do not pass any Personal Identifiable Information (PII).
 *
 * ```js
 * import { MeetingSessionConfiguration, ApplicationMetadata } from 'amazon-chime-sdk-js';
 *
 * const createMeetingResponse = // CreateMeeting API response.
 * const createAttendeeResponse = // CreateAttendee API response.
 * const meetingSessionConfiguration = new MeetingSessionConfiguration(
 *  createMeetingResponse,
 *  createAttendeeResponse
 * );
 *
 * meetingSessionConfiguration.applicationMetadata = ApplicationMetadata.create({
 *  appName: 'AppName',
 *  appVersion: '1.0.0'
 * });
 *
 * ```
 */
export default class ApplicationMetadata {
    readonly appName: string;
    readonly appVersion: string;
    private constructor();
    /**
     *
     * @param appName Builder's application name.
     * The app name must satisfy following regular expression:
     * `/^[a-zA-Z0-9]+[a-zA-Z0-9_-]*[a-zA-Z0-9]+$/g`
     *
     * @param appVersion Builder's application version.
     * The app version must follow the [Semantic Versioning](https://semver.org/) format.
     *
     * @returns [[ApplicationMetadata]]
     */
    static create(appName: string, appVersion: string): ApplicationMetadata;
}
