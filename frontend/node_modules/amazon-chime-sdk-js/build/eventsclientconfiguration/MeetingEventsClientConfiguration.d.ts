import EventsClientConfiguration from './EventsClientConfiguration';
import MeetingEventsClientConfigurationAttributes from './MeetingEventsClientConfigurationAttributes';
/**
 * [[MeetingEventsClientConfiguration]] contains necessary information to
 * report meeting events metadata to each event while sending events to the ingestion service.
 */
export default class MeetingEventsClientConfiguration implements EventsClientConfiguration {
    readonly type = "Meet";
    readonly v = 1;
    private readonly authenticationToken;
    private readonly meetingId;
    private readonly attendeeId;
    readonly eventsToIgnore: string[];
    constructor(meetingId: string, attendeeId: string, authenticationToken: string, eventsToIgnore?: string[]);
    getAuthenticationToken(): string;
    toJSON(): MeetingEventsClientConfigurationAttributes;
}
