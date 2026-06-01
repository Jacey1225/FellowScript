import Logger from '../logger/Logger';
import Task from './Task';
/**
 * A task that wraps another task and ensures it is run only once,
 * regardless of how many times `run` is called.
 *
 * This allows you to implement a kind of barrier synchronization.
 */
export default class OnceTask implements Task {
    private logger;
    private task;
    private dependencies?;
    private ongoing;
    private promise;
    private cancelPromise;
    private canceled;
    constructor(logger: Logger, task: Task, dependencies?: (Task | undefined)[]);
    name(): string;
    cancel(): void;
    logDependencies(): void;
    run(): Promise<void>;
    setParent(parentTask: Task): void;
}
