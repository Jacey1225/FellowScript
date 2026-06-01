import Destroyable from '../destroyable/Destroyable';
import MeetingHistoryState from '../eventcontroller/MeetingHistoryState';
import EventIngestionConfiguration from '../eventingestionconfiguration/EventIngestionConfiguration';
import Logger from '../logger/Logger';
import EventReporter from './EventReporter';
export default class DefaultMeetingEventReporter implements EventReporter, Destroyable {
    private eventBuffer;
    private logger;
    private reportingEvents;
    private eventsToIgnore;
    private importantEvents;
    destroyed: boolean;
    constructor(eventIngestionConfiguration: EventIngestionConfiguration, logger: Logger);
    start(): void;
    stop(): void;
    reportEvent(ts: number, name: MeetingHistoryState, attributes?: {
        [key: string]: string | number;
    }): Promise<void>;
    destroy(): Promise<void>;
}
