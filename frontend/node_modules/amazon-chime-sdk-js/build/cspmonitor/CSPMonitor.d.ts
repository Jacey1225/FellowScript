import Logger from '../logger/Logger';
export default class CSPMonitor {
    private static loggers;
    private static shouldRegisterCSPMonitor;
    private static added;
    static register(): void;
    static unregister(): void;
    static disable(): void;
    static addLogger(logger: Logger): void;
    static removeLogger(logger: Logger): void;
    private static listener;
}
