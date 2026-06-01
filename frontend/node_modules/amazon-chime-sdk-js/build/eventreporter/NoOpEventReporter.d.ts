import EventReporter from './EventReporter';
export default class NoOpEventReporter implements EventReporter {
    constructor();
    reportEvent(_ts: number, _name: string, _attributes?: {
        [key: string]: string | number;
    }): Promise<void>;
    start(): void;
    stop(): void;
}
