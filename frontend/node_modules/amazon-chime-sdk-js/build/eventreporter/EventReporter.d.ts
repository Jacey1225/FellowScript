import MeetingHistoryState from '../eventcontroller/MeetingHistoryState';
/**
 * [[EventReporter]] is responsible to get an event, buffer and send events to the
 * ingestion service endpoint.
 */
export default interface EventReporter {
    /**
     * Reports an event with a name, timestamp and any optional attributes.
     */
    reportEvent(ts: number, name: MeetingHistoryState, attributes?: {
        [key: string]: string | number;
    }): Promise<void>;
    /**
     * Enables reporting events to the ingestion service, if disabled while creating the EventIngestionConfiguration.
     */
    start(): void;
    /**
     * Disables event reporting to the ingestion service.
     */
    stop(): void;
}
