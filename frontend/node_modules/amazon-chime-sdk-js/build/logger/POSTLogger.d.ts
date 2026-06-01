import type { Destroyable } from '../destroyable/Destroyable';
import Logger from './Logger';
import LogLevel from './LogLevel';
import POSTLoggerOptions from './POSTLoggerOptions';
/**
 * `POSTLogger` publishes log messages in batches to a URL
 * supplied during its construction.
 *
 * Be sure to call {@link POSTLogger.destroy} when you're done
 * with the logger in order to avoid leaks.
 */
export default class POSTLogger implements Logger, Destroyable {
    private static readonly BATCH_SIZE;
    private static readonly INTERVAL_MS;
    private url;
    private batchSize;
    private eventListener;
    private headers;
    private intervalMs;
    private intervalScheduler;
    private logCapture;
    private logLevel;
    private lock;
    private sequenceNumber;
    metadata: Record<string, string>;
    constructor(options: POSTLoggerOptions);
    addEventListener(): void;
    removeEventListener(): void;
    debug(debugFunction: string | (() => string)): void;
    info(msg: string): void;
    warn(msg: string): void;
    error(msg: string): void;
    setLogLevel(logLevel: LogLevel): void;
    getLogLevel(): LogLevel;
    getLogCaptureSize(): number;
    private start;
    private stop;
    /**
     * Permanently clean up the logger. A new logger must be created to
     * resume logging.
     */
    destroy(): Promise<void>;
    private makeRequestBody;
    private log;
}
